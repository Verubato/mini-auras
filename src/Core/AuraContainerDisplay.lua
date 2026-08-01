---@type string, Addon
local addonName, addon = ...
local fontUtil = addon.Utils.FontUtil
local wowEx = addon.Utils.WoWEx
local growAnchors = addon.Core.GrowAnchors

-- Glow styles available here. LibCustomGlow can't attach to AuraButtons (it re-parents pooled
-- frames onto the target, and 12.1 disallows SetParent onto AuraButtons), so only the two
-- texture-based styles from IconSlotContainer are offered; anything else falls back to the
-- flipbook. PaddingFactor is a multiple of the icon size, matching ApplyStaticGlowPadding.
local GLOW_STYLES = {
	["Rotation Assist"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\FlipbookWhite.tga",
		BlendMode = "ADD",
		Desaturated = false,
		PaddingFactor = 1 / 3,
		Animated = true,
	},
	["Slot Glow"] = {
		-- The atlas carries a lot of transparent margin, so it has to extend well past the
		-- icon edges for the halo to read correctly.
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\newplayertutorial-drag-slotgreen.tga",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 1.19,
		Animated = false,
	},
}

local DEFAULT_GLOW_STYLE = "Rotation Assist"

-- How often the deferred restyle retry runs while any display is stale (see RestyleButtons).
local RESTYLE_RETRY_INTERVAL = 1

-- Stand-ins for nil arguments, so the setters never have to allocate. Read-only.
local EMPTY_STYLE = {}
local EMPTY_OPTIONS = {}

-- Shared scratch handed out by GetStyleScratch. Every field is cleared on hand-out, so a caller
-- can only ever set the fields it cares about and can never inherit a value from whoever used it
-- last (which is exactly the bug a per-module scratch table invites).
local styleScratch = {}

local cachedDb = nil
local frameIdCounter = 0
local liveDisplays = {}
local editModePreviewActive = false
local displayEventsFrame = nil
local pendingRestyleCount = 0
local restyleTicker = nil

-- 12.1 AuraContainer-backed icon display. One instance wraps a CreateFrame("AuraContainer")
-- with one or more aura groups and styles the container-created AuraButtons to match the legacy
-- IconSlotContainer look (icon, cooldown swipe + countdown, dispel-type border, glow).
--
-- Constraints inherited from the AuraContainer system:
-- - AuraButtons are forbidden while auras are secret (combat/arena): all button styling must
--   happen in the initializeFrame callback or out of combat. Style setters store the desired
--   state and apply it to buttons lazily out of combat.
-- - Aura groups can't be removed, only reconfigured, so instances are pooled per anchor and
--   reconfigured on refresh (mirrors how modules already reuse IconSlotContainers).
-- - Nothing may be anchored to the container frame itself (no OnSizeChanged), and the
--   container's size can be secret; callers must not do math with it.
--
-- This file is only used when addon.Utils.WoWEx:UseAuraContainers() is true; on 12.0 clients
-- nothing here runs (CreateFrame("AuraContainer") does not exist there).

---@class AuraContainerDisplay
local M = {}
M.__index = M

addon.Core.AuraContainerDisplay = M

local function GetDb()
	if not cachedDb then
		cachedDb = addon.Framework:GetSavedVars()
	end

	return cachedDb
end

local function Warn(message, ...)
	addon.Framework:Notify(message, ...)
end

local function NextFrameName(frameType)
	frameIdCounter = frameIdCounter + 1
	return "MiniCC_AC_" .. frameType .. "_" .. frameIdCounter
end

-- Deferred restyling
--
-- Button styling is impossible while auras are secret, which covers combat but also whole
-- encounters / M+ runs / PvP matches out of combat. RestyleButtons therefore records that the
-- buttons are stale and returns. Something has to come back for that later: pooled displays are
-- restyled on re-acquisition, but the displays that live on a unit frame or a portrait for the
-- whole session are not, so without this an icon size change made in an arena would leave the
-- buttons at their old size for the rest of the match (the container-level layout DOES take the
-- new size, so the row ends up spaced for icons that aren't that size).
--
-- PLAYER_REGEN_ENABLED covers the common case immediately; the ticker covers the rest
-- (C_Secrets.ShouldAurasBeSecret has no event) and only runs while something is actually
-- pending, so an idle UI pays nothing.

local function StopRestyleTicker()
	if restyleTicker then
		restyleTicker:Cancel()
		restyleTicker = nil
	end
end

local function FlushPendingRestyles()
	if pendingRestyleCount == 0 or wowEx:IsAuraStylingRestricted() then
		return
	end

	for _, instance in ipairs(liveDisplays) do
		-- Parked displays are hidden and left stale: nothing they show is on screen, and
		-- they are restyled on the way back in.
		if instance.RestylePending and instance.DesiredShown then
			instance:RestyleButtons()
		end
	end
end

local function OnRestyleTick()
	FlushPendingRestyles()

	if pendingRestyleCount == 0 then
		StopRestyleTicker()
	end
end

---Flags/clears a display's stale-style state, keeping the global pending count (and therefore
---the retry ticker's lifetime) in sync. Always go through this rather than assigning the field.
---@param instance AuraContainerDisplay
---@param pending boolean
local function SetRestylePending(instance, pending)
	if instance.RestylePending == pending then
		return
	end

	instance.RestylePending = pending
	pendingRestyleCount = pendingRestyleCount + (pending and 1 or -1)

	if pending then
		if not restyleTicker then
			restyleTicker = C_Timer.NewTicker(RESTYLE_RETRY_INTERVAL, OnRestyleTick)
		end
	elseif pendingRestyleCount == 0 then
		StopRestyleTicker()
	end
end

-- Edit Mode preview suppression.
--
-- Blizzard force-feeds every AuraContainer a fake data provider while Edit Mode is open, so
-- our containers fill up with placeholder auras ("Poison 1", "Buff 1", ... with random spellbook
-- icons) that have nothing to do with the tracked unit. There is no opt-out: the container
-- registers AURA_DATA_PROVIDER_SWITCH as a *static* event in OnLoad_Intrinsic (so SetEnabled and
-- visibility don't gate it), and the switch flips ManagedAuraContainerPrivateMixin's aura source
-- list to AuraContainerAuraSourceLists.EditMode. SetUseEditModeSource lives on the private mixin
-- only, so addons can't call it.
--
-- Hiding the container does work, and is the intended escape hatch: dirty processing runs under
-- Enum.OnUpdateMode.RunWhenVisibleOnce, so a hidden container never parses the fake auras at all,
-- and OnShow_Intrinsic issues a full refresh from live data on the way back out.
--
-- Modules re-parent and re-anchor these frames constantly, so suppression can't live on an
-- intermediate holder frame. Instead every display remembers the visibility its module asked for
-- and the real frame shows only when the preview isn't running. This is also why every container
-- MUST be created through this wrapper: one built directly with CreateFrame("AuraContainer")
-- isn't in liveDisplays and will happily show Blizzard's placeholder auras.

---@param instance AuraContainerDisplay
local function ApplyShownState(instance)
	instance.Frame:SetShown(instance.DesiredShown and not editModePreviewActive)
end

local function OnAuraDataProviderSwitch(useRealDataProvider)
	local previewActive = useRealDataProvider ~= true
	if editModePreviewActive == previewActive then
		return
	end

	editModePreviewActive = previewActive

	for _, instance in ipairs(liveDisplays) do
		ApplyShownState(instance)
	end
end

---Starts listening for the Edit Mode data provider switch and for combat ending (which is the
---most common moment the button restriction lifts). Called from New rather than at load,
---because AURA_DATA_PROVIDER_SWITCH only exists on clients that have the AuraContainer system.
local function EnsureDisplayEvents()
	if displayEventsFrame then
		return
	end

	displayEventsFrame = CreateFrame("Frame")
	displayEventsFrame:RegisterEvent("AURA_DATA_PROVIDER_SWITCH")
	displayEventsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	displayEventsFrame:SetScript("OnEvent", function(_, event, useRealDataProvider)
		if event == "AURA_DATA_PROVIDER_SWITCH" then
			OnAuraDataProviderSwitch(useRealDataProvider)
		else
			FlushPendingRestyles()
		end
	end)
end

---Resolves the configured glow type to one this display can actually render.
---@return string
local function GetGlowStyleName()
	local db = GetDb()
	local name = db and db.GlowType

	return (name and GLOW_STYLES[name]) and name or DEFAULT_GLOW_STYLE
end

---Copies a style into the instance's own persistent style table, resolving the global db values
---StyleButton needs along the way, and reports whether any of it actually changed. Callers can
---therefore hand in a reused scratch table - nothing here retains the argument.
---@param instance AuraContainerDisplay
---@param style AuraDisplayStyle
---@return boolean changed
local function StoreStyle(instance, style)
	local db = GetDb()
	local stored = instance.Style
	local disableSwipe = (db and db.DisableSwipe) or false
	local millisecondsThreshold = db and db.MillisecondsThreshold
	local glowStyleName = GetGlowStyleName()
	local color = style.GlowColor
	local colorR, colorG, colorB = color and color[1], color and color[2], color and color[3]

	if stored.ReverseCooldown == style.ReverseCooldown
		and stored.ShowMilliseconds == style.ShowMilliseconds
		and stored.ColorByDispelType == style.ColorByDispelType
		and stored.Glow == style.Glow
		and stored.FontScale == style.FontScale
		and stored.ShowTooltips == style.ShowTooltips
		and stored.DisableSwipe == disableSwipe
		and stored.MillisecondsThreshold == millisecondsThreshold
		and stored.GlowStyleName == glowStyleName
		and stored.GlowColorR == colorR
		and stored.GlowColorG == colorG
		and stored.GlowColorB == colorB
		and stored.Populated
	then
		return false
	end

	stored.ReverseCooldown = style.ReverseCooldown
	stored.ShowMilliseconds = style.ShowMilliseconds
	stored.ColorByDispelType = style.ColorByDispelType
	stored.Glow = style.Glow
	stored.FontScale = style.FontScale
	stored.ShowTooltips = style.ShowTooltips
	stored.DisableSwipe = disableSwipe
	stored.MillisecondsThreshold = millisecondsThreshold
	stored.GlowStyleName = glowStyleName
	stored.GlowColorR = colorR
	stored.GlowColorG = colorG
	stored.GlowColorB = colorB
	stored.Populated = true

	return true
end

---Applies a glow style's asset and geometry to a button's glow frame. Only touches the texture
---when the style actually changed - this runs per button on every restyle.
---@param widgets table
---@param button table
---@param styleName string
---@param size number
local function ApplyGlowStyle(widgets, button, styleName, size)
	local glow = widgets.Glow
	local spec = GLOW_STYLES[styleName]

	if widgets.GlowStyle ~= styleName then
		widgets.GlowStyle = styleName

		-- Stop before re-skinning: the flipbook drives tex coords, so a running animation
		-- would fight the reset below (and Stop may restore its own pre-animation coords).
		glow.Anim:Stop()

		glow.Texture:SetTexture(spec.Texture)
		glow.Texture:SetBlendMode(spec.BlendMode)
		glow.Texture:SetDesaturated(spec.Desaturated)
		-- The flipbook leaves the coords on its last cell; reset them so a static asset
		-- isn't rendered as a 1/30th crop of itself.
		if not spec.Animated then
			glow.Texture:SetTexCoord(0, 1, 0, 1)
		end
	end

	local padding = size * spec.PaddingFactor
	glow:SetPoint("TOPLEFT", button, "TOPLEFT", -padding, padding)
	glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", padding, -padding)

	-- A REPEAT animation costs CPU every frame even on hidden frames, and with thousands of
	-- pre-created buttons that showed up as constant background load; only run it when the
	-- chosen style is actually animated.
	if spec.Animated then
		if not glow.Anim:IsPlaying() then
			glow.Anim:Play()
		end
	else
		glow.Anim:Stop()
	end
end

---Registers (or unregisters) the button's dispel-type textures. The engine tints registered
---textures by dispel type and drives their per-aura visibility (PreserveAsset style keeps our
---asset and only colours it). The border participates when ColorByDispelType is on; the glow's
---texture ALSO registers when the glow is enabled, which is how the glow inherits the border
---colour - the legacy paths tinted the glow with the aura's dispel colour, which is unreadable
---here, so the engine applies it instead. showWithoutDispelType keeps the glow visible for
---physical CC, tinted with the "None" palette colour like legacy.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
local function ApplyDispelTextures(instance, button, widgets)
	local style = instance.Style
	local wantBorder = style.ColorByDispelType == true and widgets.Border ~= nil
	local wantGlowTint = wantBorder and style.Glow == true and widgets.Glow ~= nil
	-- The group's own tint wins over the display-wide one: alerts colour by category, while a
	-- single-category display just takes the user's picked colour.
	local colorR = widgets.GlowColor and widgets.GlowColor[1] or style.GlowColorR
	local colorG = widgets.GlowColor and widgets.GlowColor[2] or style.GlowColorG
	local colorB = widgets.GlowColor and widgets.GlowColor[3] or style.GlowColorB
	-- The colour rides in the signature so a colour-only change still repaints; without it the
	-- early return below would swallow it.
	local dispelSignature = (wantBorder and "b" or "") .. (wantGlowTint and "g" or "")
		.. (colorR and (":" .. colorR .. "," .. colorG .. "," .. colorB) or "")

	if dispelSignature == widgets.DispelSignature then
		return
	end

	widgets.DispelSignature = dispelSignature
	button:ClearDispelTypeTextures()

	if wantBorder then
		button:AddDispelTypeTexture(widgets.Border, {
			style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
			showWhenHarmful = true,
			showWhenHelpful = true,
		})
	elseif widgets.Border then
		-- Unregistered again: visibility is ours, keep it hidden.
		widgets.Border:Hide()
	end

	if wantGlowTint then
		button:AddDispelTypeTexture(widgets.Glow.Texture, {
			style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
			showWhenHarmful = true,
			showWhenHelpful = true,
			showWithoutDispelType = true,
		})
	elseif widgets.Glow then
		-- Unregistered again: restore the glow's own colour and make sure the engine's
		-- last hidden state doesn't linger on the texture. GlowColor is the group's category
		-- tint (e.g. red importants, green defensives) and is nil unless the caller asked for
		-- one, in which case this is the plain white glow. Dispel colouring wins when both are
		-- on, since that branch hands the texture to the engine.
		widgets.Glow.Texture:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)
		widgets.Glow.Texture:Show()
	end
end

-- Applies the stored per-button style (size, cooldown settings, border, glow, mouse) to one
-- button. Safe only while buttons are not forbidden (initializeFrame or out of combat).
---@param instance AuraContainerDisplay
---@param button table
local function StyleButton(instance, button)
	local style = instance.Style
	local widgets = instance.ButtonWidgets[button]

	if not widgets then
		return
	end

	button:SetSize(instance.Size, instance.Size)

	-- DisableSwipe/MillisecondsThreshold/GlowStyleName are the global db values StoreStyle
	-- resolved when the style was set, so this hot loop never re-reads the db per button.
	local cd = widgets.Cooldown
	cd:SetReverse(style.ReverseCooldown or false)
	cd:SetDrawSwipe(not style.DisableSwipe)
	if cd.SetCountdownMillisecondsThreshold then
		cd:SetCountdownMillisecondsThreshold(style.ShowMilliseconds and (style.MillisecondsThreshold or 5) or 0)
	end
	cd.FontScale = style.FontScale or 1.0
	fontUtil:UpdateCooldownFontSize(cd, instance.Size, nil, cd.FontScale)

	if widgets.Border or widgets.Glow then
		ApplyDispelTextures(instance, button, widgets)
	end

	-- Glow: the frame is created as a button child at init (LibCustomGlow can't be used here -
	-- it re-parents pooled frames onto the target, and 12.1 disallows SetParent onto AuraButtons
	-- because the child would inherit their forbidden aspects). It shows and hides with the
	-- button (button visibility is secret, but child rendering follows the parent without any
	-- addon-readable state). ApplyGlowStyle picks the asset and only runs the looping animation
	-- for the styles that need one.
	local glow = widgets.Glow
	if glow then
		if style.Glow then
			ApplyGlowStyle(widgets, button, style.GlowStyleName or DEFAULT_GLOW_STYLE, instance.Size)
			glow:Show()
		else
			glow:Hide()
			glow.Anim:Stop()
		end
	end

	-- Tooltips (and click-to-cancel, which we never register) require mouse input.
	button:EnableMouse(style.ShowTooltips ~= false)
end

---@param instance AuraContainerDisplay
---@param button table
local function InitializeButton(instance, button, glowColor)
	-- Composite each button's icon/cooldown/border/glow in a single render pass. Must happen
	-- here: initializeFrame is the only place AuraButtons are guaranteed not forbidden.
	button:SetFlattensRenderLayers(true)

	-- Icon on the lowest layer, swipe + border above, matching CreateLayer in IconSlotContainer.
	local icon = button:CreateTexture(nil, "BACKGROUND", nil, 1)
	icon:SetAllPoints(button)
	local texCoord = instance.IconTexCoord
	if texCoord then
		icon:SetTexCoord(texCoord[1], texCoord[2], texCoord[3], texCoord[4])
	end
	if instance.IconMask then
		icon:AddMaskTexture(instance.IconMask)
	end
	button:SetIcon(icon)

	local cd = CreateFrame("Cooldown", NextFrameName("Cooldown"), button, "CooldownFrameTemplate")
	cd:SetAllPoints(button)
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	cd:SetSwipeColor(0, 0, 0, 0.8)
	if instance.IconMask then
		-- Keep the swipe inside the masked (round) icon.
		cd:SetSwipeTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	end
	button:SetDurationCooldown(cd)

	local border, glow

	if not instance.Minimal then
		-- Border sized 1px past the icon, same asset/coords as the legacy border.
		border = button:CreateTexture(nil, "OVERLAY")
		border:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
		border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
		border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		-- Hidden until registered via AddDispelTypeTexture, which takes over its visibility;
		-- otherwise it would render (uncoloured) over every aura icon.
		border:Hide()

		-- Glow overlay, created up-front as a direct child (creation is allowed on AuraButtons;
		-- re-parenting is not). The asset is left unset: StyleButton applies whichever style from
		-- GLOW_STYLES is configured, and the flipbook animation is built here either way so a
		-- later switch to "Rotation Assist" doesn't have to touch the button.
		glow = CreateFrame("Frame", NextFrameName("Glow"), button)
		glow:SetFrameLevel(button:GetFrameLevel() + 5)
		glow.Texture = glow:CreateTexture(nil, "OVERLAY")
		glow.Texture:SetAllPoints()
		glow.Anim = glow:CreateAnimationGroup()
		glow.Anim:SetLooping("REPEAT")
		local flip = glow.Anim:CreateAnimation("FlipBook")
		flip:SetChildKey("Texture")
		flip:SetFlipBookRows(6)
		flip:SetFlipBookColumns(5)
		flip:SetFlipBookFrames(30)
		flip:SetDuration(1.0)
		-- Deliberately NOT played here: StyleButton starts/stops it with the glow style.
		glow:Hide()
	end

	button:SetTooltipAnchorPoint("ANCHOR_RIGHT")

	instance.ButtonWidgets[button] = {
		Cooldown = cd,
		Border = border,
		DispelSignature = nil,
		Glow = glow,
		GlowStyle = nil,
		GlowColor = glowColor,
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

---@param instance AuraContainerDisplay
local function ApplyFlowLayout(instance)
	local layout = growAnchors:GetFlow(instance.Grow)
	local frame = instance.Frame
	frame:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis[layout.Axis])
	frame:SetFlowLayoutAnchorPoint(layout.AnchorPoint)
	frame:SetFlowLayoutGrowthDirection(
		AnchorUtil.FlowDirection[layout.Horizontal],
		AnchorUtil.FlowDirection[layout.Vertical]
	)
end

---Fills the instance's own layout table. Spacing keys are passed under BOTH the older and newer
---PTR spellings (elementSpacing/lineSpacing was renamed to elementSpacingX/elementSpacingY in a
---later 12.1 build); validators ignore unknown keys, so this works on either build.
---The table is per-instance and reused rather than rebuilt per call: every group on a display
---always gets the same layout, so sharing one table across them is safe even if the engine
---retains the reference.
---@param instance AuraContainerDisplay
---@return table
local function BuildGroupLayout(instance)
	local layout = instance.Layout
	layout.elementSpacing = instance.Spacing
	layout.lineSpacing = instance.Spacing
	layout.elementSpacingX = instance.Spacing
	layout.elementSpacingY = instance.Spacing
	layout.elementWidth = instance.Size
	layout.elementHeight = instance.Size

	return layout
end

---@param instance AuraContainerDisplay
local function ApplyGroupLayout(instance)
	for _, group in ipairs(instance.Groups) do
		instance.Frame:SetAuraGroupLayout(group.Key, BuildGroupLayout(instance))
	end
end

---Creates a new AuraContainer-backed display with one aura group per spec. Groups anchor
---sequentially in the order given; use Core/AuraFilters so overlapping categories are
---partitioned by filter negation rather than showing an aura once per group.
---@param parent table Frame to parent the container to.
---@param unit string Unit token to track.
---@param groups AuraDisplayGroupSpec[] Group specs, e.g. { { Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 } }.
---@param size number Icon size in pixels.
---@param spacing number Spacing between icons.
---@param moduleName string? MiniCCModule label set on the frame (matches IconSlotContainer).
---@param options AuraDisplayOptions? Per-button rendering options (icon crop/mask, minimal chrome).
---@return AuraContainerDisplay
function M:New(parent, unit, groups, size, spacing, moduleName, options)
	local instance = setmetatable({}, M)

	options = options or EMPTY_OPTIONS

	instance.Size = size or 20
	instance.Spacing = spacing or 2
	instance.Groups = groups
	-- Key -> spec, so the per-category budget setter is a lookup rather than a scan (and can
	-- tell a caller that its group key is wrong instead of silently doing nothing).
	instance.GroupsByKey = {}
	instance.Grow = growAnchors.Default
	-- Owned by the instance and mutated in place by StoreStyle; callers never hand us a table
	-- we keep, so they are free to pass a reused scratch.
	instance.Style = {}
	instance.Layout = {}
	instance.Buttons = {}
	-- button -> { Cooldown, Border, DispelSignature, Glow, GlowStyle } for restyling.
	instance.ButtonWidgets = {}
	-- Visibility the owning module last asked for; frames are created shown.
	instance.DesiredShown = true
	instance.RestylePending = false
	instance.IconTexCoord = options.IconTexCoord
	instance.IconMask = options.IconMask
	instance.Minimal = options.Minimal == true

	-- Seed the style BEFORE any button exists, so initializeFrame styles them correctly first
	-- time. Everything StyleButton applies - size, swipe, countdown, glow, dispel textures - is
	-- baked into a button when it is created and can only be changed by a restyle, which is
	-- blocked for as long as C_Secrets.ShouldAurasBeSecret is true (a whole arena). A display
	-- created without its real style therefore keeps the wrong one for the entire match, so
	-- callers pass options.Style rather than relying on a later SetStyle.
	StoreStyle(instance, options.Style or EMPTY_STYLE)

	local frame = CreateFrame("AuraContainer", NextFrameName("Container"), parent, "CustomAuraContainerTemplate")
	-- Icon sizes are configured in absolute pixels, so a scaled parent (a nameplate, a unit frame
	-- addon's scaled header) would silently change them. Displays that SHOULD scale with their host
	-- (the portrait icons) turn this back off after New.
	frame:SetIgnoreParentScale(true)
	frame.MiniCCModule = moduleName or nil
	instance.Frame = frame

	EnsureDisplayEvents()
	liveDisplays[#liveDisplays + 1] = instance
	ApplyShownState(instance)

	frame:SetUnit(unit)
	ApplyFlowLayout(instance)

	for _, group in ipairs(groups) do
		instance.GroupsByKey[group.Key] = group
		-- Captured per group: initializeFrame is the only place a button can be styled, so a
		-- group's category glow tint has to be closed over here rather than looked up later.
		local glowColor = group.GlowColor
		frame:AddAuraGroup(group.Key, group.FilterString, {
			maxFrameCount = group.MaxIcons or 3,
			candidateFilters = group.CandidateFilters,
			-- Aura instance IDs increase monotonically as auras are applied, so sorting on them
			-- alone is "oldest first" - the same order the legacy watcher produced (it kept the
			-- game's order and broke ties by instance id). The alternatives all sort by data the
			-- addon can't see, which makes them impossible to reason about or match in test mode.
			sortMethod = AuraContainerSortMethod.AuraInstanceIDOnly,
			sortDirection = group.SortDirection or AuraContainerSortDirection.Normal,
			initializeFrame = function(button)
				InitializeButton(instance, button, glowColor)
			end,
			layout = BuildGroupLayout(instance),
		})
	end

	return instance
end

---@param unit string
function M:SetUnit(unit)
	self.Frame:SetUnit(unit)
end

---@return string
function M:GetUnit()
	return self.Frame:GetUnit()
end

---Enables or disables aura tracking (disabled containers unregister their events).
---@param enabled boolean
function M:SetEnabled(enabled)
	self.Frame:SetEnabled(enabled)
end

---Shows or hides the display. Always use this instead of touching Frame:SetShown directly, so
---the Edit Mode placeholder auras stay suppressed (see EnsureDisplayEvents).
---@param shown boolean
function M:SetShown(shown)
	self.DesiredShown = shown == true
	ApplyShownState(self)

	-- Coming back into view is a chance to settle a restyle that was skipped while restricted
	-- (a pooled display re-acquired mid-combat retries here as soon as combat drops).
	if self.DesiredShown and self.RestylePending then
		self:RestyleButtons()
	end
end

function M:Show()
	self:SetShown(true)
end

function M:Hide()
	self:SetShown(false)
end

---The visibility the owning module asked for, which is not the frame's actual state while the
---Edit Mode preview is suppressing it.
---@return boolean
function M:IsShown()
	return self.DesiredShown
end

---@param newSize number
function M:SetIconSize(newSize)
	newSize = tonumber(newSize)
	if not newSize or newSize <= 0 or self.Size == newSize then
		return
	end

	self.Size = newSize
	-- Applies the layout too, gated so it can't run ahead of the button resize.
	self:RestyleButtons()
end

---@param newSpacing number
function M:SetSpacing(newSpacing)
	newSpacing = tonumber(newSpacing)
	if not newSpacing or newSpacing < 0 or self.Spacing == newSpacing then
		return
	end

	self.Spacing = newSpacing
	-- Routed through the restyle gate as well: BuildGroupLayout reads Size, so applying the
	-- layout for a spacing change would also publish a Size the buttons haven't taken yet.
	self:RestyleButtons()
end

---Applies size, spacing and style together, restyling the buttons once. Callers changing more
---than one of them must use this rather than the individual setters, which restyle every button
---on each call - three passes over every button per config change is what made dragging an icon
---size slider stutter. Nothing is applied to the buttons while aura styling is restricted; the
---values are stored and the pending-restyle retry settles them when it lifts.
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@return boolean changed
function M:ApplyConfig(size, spacing, style)
	size = tonumber(size)
	spacing = tonumber(spacing)

	local changed = false

	if size and size > 0 and self.Size ~= size then
		self.Size = size
		changed = true
	end

	if spacing and spacing >= 0 and self.Spacing ~= spacing then
		self.Spacing = spacing
		changed = true
	end

	if StoreStyle(self, style or EMPTY_STYLE) then
		changed = true
	end

	if not changed and not self.RestylePending then
		return false
	end

	self:RestyleButtons()

	return true
end

---Sets a group's icon budget. A value of 0 hides the group entirely (used for per-category
---toggles like ShowCC/ShowDefensives), so a mistyped key would silently switch a whole category
---off - hence the warning rather than a quiet return.
---@param groupKey string
---@param maxIcons number
function M:SetMaxIcons(groupKey, maxIcons)
	maxIcons = tonumber(maxIcons)
	if not maxIcons or maxIcons < 0 then
		return
	end

	local group = self.GroupsByKey[groupKey]

	if not group then
		Warn("SetMaxIcons: no aura group '%s' on this display.", tostring(groupKey))
		return
	end

	if group.MaxIcons == maxIcons then
		return
	end

	group.MaxIcons = maxIcons
	self.Frame:SetAuraGroupMaxFrameCount(groupKey, maxIcons)
end

---@param grow string "LEFT"|"RIGHT"|"CENTER"|"UP"|"DOWN"
function M:SetGrow(grow)
	if self.Grow == grow then
		return
	end

	self.Grow = grow
	ApplyFlowLayout(self)
end

---Returns the shared style scratch with every field cleared, ready to fill and hand to
---SetStyle. Using this instead of a table literal keeps the per-refresh style updates
---allocation-free, and clearing on hand-out means a caller can never inherit a field it forgot
---to set from whoever styled a display last.
---@return AuraDisplayStyle
function M:GetStyleScratch()
	styleScratch.ReverseCooldown = nil
	styleScratch.ShowMilliseconds = nil
	styleScratch.ColorByDispelType = nil
	styleScratch.Glow = nil
	styleScratch.FontScale = nil
	styleScratch.ShowTooltips = nil
	styleScratch.GlowColor = nil

	return styleScratch
end

---Everything StyleButton bakes into a button, as a comparable string. Callers cache displays by
---this: a button can only be styled when it is created, so a display whose signature no longer
---matches has to be rebuilt rather than restyled. Deliberately includes the global db values
---StoreStyle resolves (glow style, swipe, countdown threshold) - those are invisible to the
---caller's own options table, and leaving them out meant changing the glow type in the options
---never reached the already-built displays.
---@param style AuraDisplayStyle
---@param size number
---@param spacing number
---@return string
function M:GetStyleSignature(style, size, spacing)
	local db = GetDb()

	return table.concat({
		tostring(size),
		tostring(spacing),
		tostring(style.ReverseCooldown),
		tostring(style.ShowMilliseconds),
		tostring(style.ColorByDispelType),
		tostring(style.Glow),
		tostring(style.FontScale),
		tostring(style.ShowTooltips),
		tostring(style.GlowColor and table.concat(style.GlowColor, ",")),
		tostring(db and db.DisableSwipe),
		tostring(db and db.MillisecondsThreshold),
		GetGlowStyleName(),
	}, ":")
end

---Stores the per-button style and applies it to existing buttons when possible. Skipped
---entirely when nothing changed - this runs on hot paths (every nameplate add), and restyling
---means ~10 API calls across every pre-created button.
---The style is copied field-by-field into the instance's own table, so this allocates nothing
---and callers may pass a reused scratch table.
---@param style AuraDisplayStyle
function M:SetStyle(style)
	local changed = StoreStyle(self, style or EMPTY_STYLE)

	if not changed and not self.RestylePending then
		return
	end

	self:RestyleButtons()
end

-- There is deliberately no StopGlowAnimations counterpart to parking a display. Hiding a parked
-- display's glow frames to save the looping flipbook's CPU cannot work: the glows are CHILDREN of
-- AuraButtons, so re-showing them needs a restyle, and a restyle is blocked for as long as
-- C_Secrets.ShouldAurasBeSecret is true. A display parked in the world and reused inside an arena
-- therefore came back with its glows hidden for the whole match, which is why the glow appeared
-- on some units and not others. It saved nothing either way: stopping set the restyle-pending
-- flag, and the retry ticker started the animations again a second later.

---Re-applies the stored style to all created buttons. Buttons are forbidden while auras are
---secret (in combat, but also out-of-combat inside M+/encounters/PvP matches), so this is
---deferred then: the pending flag makes the next SetStyle/RestyleButtons retry even when the
---style itself is unchanged, and the retry ticker comes back for displays that would otherwise
---never be touched again.
function M:RestyleButtons()
	if wowEx:IsAuraStylingRestricted() then
		SetRestylePending(self, true)
		return
	end

	SetRestylePending(self, false)

	-- The group layout spaces icons by elementWidth, but the engine only ever positions a
	-- button - CustomAuraContainerFlowLayoutMixin:ApplyElementLayout discards the width and
	-- height it is handed. The button's real size comes from StyleButton below. Both therefore
	-- have to be applied together: pushing the layout through while the restyle is deferred
	-- spaces the row for the new size with buttons still at the old one, which shows up as gaps
	-- when sizing up and overlap when sizing down.
	ApplyGroupLayout(self)

	for _, button in ipairs(self.Buttons) do
		StyleButton(self, button)
	end
end

---Positions this display relative to its anchor, chaining after the kick container while a
---kick icon is showing (the kick occupied the first slot in the legacy layouts).
---@param kickFrame table The kick IconSlotContainer's frame.
---@param anchor table The frame the display is positioned against when no kick is active.
---@param grow string "LEFT"|"RIGHT"|"CENTER"|"UP"|"DOWN"
---@param spacing number Gap between the kick icon and the aura row.
---@param offsetX number
---@param offsetY number
---@param kickActive boolean
function M:AnchorAfterKick(kickFrame, anchor, grow, spacing, offsetX, offsetY, kickActive)
	grow = grow or growAnchors.Default
	self:SetGrow(grow)

	local frame = self.Frame
	frame:ClearAllPoints()

	if kickActive then
		local point, relativePoint, x, y = growAnchors:GetChain(grow, spacing)
		frame:SetPoint(point, kickFrame, relativePoint, x, y)
	else
		local point, relativePoint = growAnchors:GetAnchor(grow)
		frame:SetPoint(point, anchor, relativePoint, offsetX, offsetY)
	end
end

---@class AuraDisplayStyle
---@field ReverseCooldown boolean?
---@field ShowMilliseconds boolean?
---@field ColorByDispelType boolean?
---@field Glow boolean?
---@field FontScale number?
---@field ShowTooltips boolean?
---Resolved from the global db by StoreStyle; callers never set these.
---@field DisableSwipe boolean?
---@field MillisecondsThreshold number?
---@field GlowStyleName string?
---@field GlowColor number[]? {r, g, b} tint for every glow on the display. A group's own
---GlowColor overrides it; unset leaves the glow plain white.
---@field Populated boolean?

---@class AuraDisplayGroupSpec
---@field Key string Group key (arbitrary, unique within the display).
---@field FilterString string Aura filter string (e.g. "HARMFUL|CROWD_CONTROL").
---@field MaxIcons number? Icon budget for this group (default 3).
---@field CandidateFilters table? 12.1 candidate filters (e.g. { includeSpellIDs = ..., maxDuration = 4.1 }). Every standard category passes an includeSpellIDs map here - see Core/AuraFilters for why it is needed on top of the filter string.
---@field SortDirection number? AuraContainerSortDirection value (default Normal; Reverse = newest first).
---@field GlowColor number[]? {r, g, b} tint for this group's glow, so one container can colour
---its categories differently. Dispel-type colouring takes over when it is also enabled.

---@class AuraDisplayOptions
---@field IconTexCoord number[]? {left, right, top, bottom} crop applied to every icon.
---@field IconMask table? MaskTexture applied to every icon, and to the cooldown swipe.
---@field Minimal boolean? Skip the dispel border and the glow frame (portrait icons want neither).
---@field Style AuraDisplayStyle? Style to build the buttons with. Pass it whenever the display
---may be created while auras are secret - a later SetStyle cannot reach the buttons there.

---@class AuraContainerDisplay
---@field Frame table The AuraContainer frame (anchor/show/hide through this).
---@field Size number
---@field Spacing number
---@field Groups AuraDisplayGroupSpec[]
---@field GroupsByKey table<string, AuraDisplayGroupSpec>
---@field Grow string
---@field Style AuraDisplayStyle
---@field Layout table
---@field Buttons table[]
---@field ButtonWidgets table<table, table>
---@field DesiredShown boolean
---@field RestylePending boolean
---@field IconTexCoord number[]?
---@field IconMask table?
---@field Minimal boolean
