---@type string, Addon
local addonName, addon = ...
local fontUtil = addon.Utils.FontUtil
local wowEx = addon.Utils.WoWEx
local cachedDb = nil
local frameIdCounter = 0
local liveDisplays = {}
local editModePreviewActive = false
local providerSwitchListener = nil

-- 12.1 AuraContainer-backed icon display. One instance wraps a CreateFrame("AuraContainer")
-- with a single aura group and styles the container-created AuraButtons to match the legacy
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
		local mini = addon.Core.Framework
		if mini and mini.GetSavedVars then
			cachedDb = mini:GetSavedVars()
		end
	end

	return cachedDb
end

local function NextFrameName(frameType)
	frameIdCounter = frameIdCounter + 1
	return "MiniCC_AC_" .. frameType .. "_" .. frameIdCounter
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
-- and the real frame shows only when the preview isn't running.

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

---Starts listening for the Edit Mode data provider switch. Called from New rather than at load,
---because the event only exists on clients that have the AuraContainer system.
local function EnsureProviderSwitchListener()
	if providerSwitchListener then
		return
	end

	providerSwitchListener = CreateFrame("Frame")
	providerSwitchListener:RegisterEvent("AURA_DATA_PROVIDER_SWITCH")
	providerSwitchListener:SetScript("OnEvent", function(_, _, useRealDataProvider)
		OnAuraDataProviderSwitch(useRealDataProvider)
	end)
end

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

---Resolves the configured glow type to one this display can actually render.
---@return string
local function GetGlowStyleName()
	local db = GetDb()
	local name = db and db.GlowType

	return (name and GLOW_STYLES[name]) and name or DEFAULT_GLOW_STYLE
end

-- Stand-in for a nil style, so SetStyle never has to allocate one. Read-only.
local EMPTY_STYLE = {}

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

	if stored.ReverseCooldown == style.ReverseCooldown
		and stored.ShowMilliseconds == style.ShowMilliseconds
		and stored.ColorByDispelType == style.ColorByDispelType
		and stored.Glow == style.Glow
		and stored.FontScale == style.FontScale
		and stored.ShowTooltips == style.ShowTooltips
		and stored.DisableSwipe == disableSwipe
		and stored.MillisecondsThreshold == millisecondsThreshold
		and stored.GlowStyleName == glowStyleName
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

	-- Dispel-type registrations: the engine tints registered textures by dispel type and
	-- drives their per-aura visibility (PreserveAsset style keeps our asset and only colours
	-- it). The border participates when ColorByDispelType is on; the glow's flipbook texture
	-- ALSO registers when the glow is enabled, which is how the glow inherits the border
	-- colour - the legacy paths tinted the glow with the aura's dispel colour, which is
	-- unreadable here, so the engine applies it instead. showWithoutDispelType keeps the glow
	-- visible for physical CC, tinted with the "None" palette colour like legacy.
	local wantBorder = style.ColorByDispelType == true
	local wantGlowTint = wantBorder and style.Glow == true and widgets.Glow ~= nil
	local dispelSignature = (wantBorder and "b" or "") .. (wantGlowTint and "g" or "")
	if dispelSignature ~= widgets.DispelSignature then
		widgets.DispelSignature = dispelSignature
		button:ClearDispelTypeTextures()

		if wantBorder then
			button:AddDispelTypeTexture(widgets.Border, {
				style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
				showWhenHarmful = true,
				showWhenHelpful = true,
			})
		else
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
			-- Unregistered again: restore the plain white glow and make sure the engine's
			-- last hidden state doesn't linger on the texture.
			widgets.Glow.Texture:SetVertexColor(1, 1, 1, 1)
			widgets.Glow.Texture:Show()
		end
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
local function InitializeButton(instance, button)
	-- Composite each button's icon/cooldown/border/glow in a single render pass. Must happen
	-- here: initializeFrame is the only place AuraButtons are guaranteed not forbidden.
	button:SetFlattensRenderLayers(true)

	-- Icon on the lowest layer, swipe + border above, matching CreateLayer in IconSlotContainer.
	local icon = button:CreateTexture(nil, "BACKGROUND", nil, 1)
	icon:SetAllPoints(button)
	button:SetIcon(icon)

	local cd = CreateFrame("Cooldown", NextFrameName("Cooldown"), button, "CooldownFrameTemplate")
	cd:SetAllPoints(button)
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	cd:SetSwipeColor(0, 0, 0, 0.8)
	button:SetDurationCooldown(cd)

	-- Border sized 1px past the icon, same asset/coords as the legacy border.
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
	border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
	border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
	-- Hidden until registered via AddDispelTypeTexture, which takes over its visibility;
	-- otherwise it would render (uncoloured) over every aura icon.
	border:Hide()

	button:SetTooltipAnchorPoint("ANCHOR_RIGHT")

	-- Glow overlay, created up-front as a direct child (creation is allowed on AuraButtons;
	-- re-parenting is not). The asset is left unset: StyleButton applies whichever style from
	-- GLOW_STYLES is configured, and the flipbook animation is built here either way so a later
	-- switch to "Rotation Assist" doesn't have to touch the button.
	local glow = CreateFrame("Frame", NextFrameName("Glow"), button)
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

	instance.ButtonWidgets[button] = {
		Cooldown = cd,
		Border = border,
		DispelSignature = nil,
		Glow = glow,
		GlowStyle = nil,
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

-- Maps a module Grow option to flow layout settings. The first icon always sits nearest the
-- container's anchored edge, matching the legacy layouts.
local GROW_LAYOUTS = {
	LEFT = { axis = "Horizontal", anchorPoint = "RIGHT", h = "Left", v = "Down" },
	RIGHT = { axis = "Horizontal", anchorPoint = "LEFT", h = "Right", v = "Down" },
	CENTER = { axis = "Horizontal", anchorPoint = "LEFT", h = "Right", v = "Down" },
	DOWN = { axis = "Vertical", anchorPoint = "TOP", h = "Right", v = "Down" },
	UP = { axis = "Vertical", anchorPoint = "BOTTOM", h = "Right", v = "Up" },
}

---@param instance AuraContainerDisplay
local function ApplyFlowLayout(instance)
	local layout = GROW_LAYOUTS[instance.Grow] or GROW_LAYOUTS.CENTER
	local frame = instance.Frame
	frame:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis[layout.axis])
	frame:SetFlowLayoutAnchorPoint(layout.anchorPoint)
	frame:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection[layout.h], AnchorUtil.FlowDirection[layout.v])
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
---sequentially in the order given (an aura matching several groups' filters may appear once
---per group - pick filters that don't overlap where that matters).
---@param parent table Frame to parent the container to.
---@param unit string Unit token to track.
---@param groups AuraDisplayGroupSpec[] Group specs, e.g. { { Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 } }.
---@param size number Icon size in pixels.
---@param spacing number Spacing between icons.
---@param moduleName string? MiniCCModule label set on the frame (matches IconSlotContainer).
---@return AuraContainerDisplay
function M:New(parent, unit, groups, size, spacing, moduleName)
	local instance = setmetatable({}, M)

	instance.Size = size or 20
	instance.Spacing = spacing or 2
	instance.Groups = groups
	instance.Grow = "CENTER"
	-- Owned by the instance and mutated in place by StoreStyle; callers never hand us a table
	-- we keep, so they are free to pass a reused scratch.
	instance.Style = {}
	instance.Layout = {}
	instance.Buttons = {}
	-- button -> { Cooldown, Border, DispelSignature, Glow, GlowStyle } for restyling.
	instance.ButtonWidgets = {}
	-- Visibility the owning module last asked for; frames are created shown.
	instance.DesiredShown = true

	-- Seed the db-derived style fields so buttons created before the first SetStyle (which
	-- restyles everything anyway) still pick up the global swipe/countdown/glow settings.
	StoreStyle(instance, EMPTY_STYLE)

	local frame = CreateFrame("AuraContainer", NextFrameName("Container"), parent, "CustomAuraContainerTemplate")
	frame:SetIgnoreParentScale(true)
	frame.MiniCCModule = moduleName or nil
	instance.Frame = frame

	EnsureProviderSwitchListener()
	liveDisplays[#liveDisplays + 1] = instance
	ApplyShownState(instance)

	frame:SetUnit(unit)
	ApplyFlowLayout(instance)

	for _, group in ipairs(groups) do
		frame:AddAuraGroup(group.Key, group.FilterString, {
			maxFrameCount = group.MaxIcons or 3,
			candidateFilters = group.CandidateFilters,
			sortMethod = AuraContainerSortMethod.AuraInstanceIDOnly,
			sortDirection = AuraContainerSortDirection.Normal,
			initializeFrame = function(button)
				InitializeButton(instance, button)
			end,
			layout = BuildGroupLayout(instance),
		})
	end

	return instance
end

---Creates a pool of display objects (a display or a bundle of displays per item, as built by
---createFn; resetFn parks an item - disable, hide, unanchor). Pre-creation is staggered on a
---timer so login doesn't hitch, and containers are never created mid-combat in practice;
---Acquire falls back to on-demand creation only if demand outruns the pool (which the 12.1 API
---permits, at the cost of a combat frame spike).
---
---Pre-creation does NOT start on its own: modules Init unconditionally, so a pool that filled
---itself would build a screen's worth of containers for a module the user has switched off.
---Call Prewarm() from the module's enable path instead (it is idempotent and cheap to repeat).
---@param createFn fun(): table
---@param resetFn fun(item: table)
---@param preallocateCount number
---@return table pool Pool with Acquire/Release/Prewarm methods.
function M:NewPool(createFn, resetFn, preallocateCount)
	local pool = { Free = {} }

	-- Closures over `pool` (dot-defined but callable with `:` too - the implicit self is unused).
	function pool.Acquire()
		local item = table.remove(pool.Free)
		if not item then
			item = createFn()
		end
		return item
	end

	function pool.Release(_, item)
		resetFn(item)
		pool.Free[#pool.Free + 1] = item
	end

	local created = 0
	local target = preallocateCount
	local ticker

	---Starts (or resumes) staggered pre-creation. Safe to call on every enable: it no-ops once
	---the pool is full or while a fill is already running. Pass targetCount to raise the target
	---when demand grows (e.g. the user enables a second bar, doubling displays per nameplate);
	---it never lowers it, since the extra items are already built.
	---@param targetCount number?
	function pool.Prewarm(_, targetCount)
		if targetCount and targetCount > target then
			target = targetCount
		end

		if ticker or created >= target then
			return
		end

		ticker = C_Timer.NewTicker(0.1, function()
			if created >= target then
				ticker:Cancel()
				ticker = nil
				return
			end
			for _ = 1, 2 do
				if created < target then
					created = created + 1
					local item = createFn()
					resetFn(item)
					pool.Free[#pool.Free + 1] = item
				end
			end
		end)
	end

	return pool
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
---the Edit Mode placeholder auras stay suppressed (see EnsureProviderSwitchListener).
---@param shown boolean
function M:SetShown(shown)
	self.DesiredShown = shown == true
	ApplyShownState(self)
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
	ApplyGroupLayout(self)
	self:RestyleButtons()
end

---@param newSpacing number
function M:SetSpacing(newSpacing)
	newSpacing = tonumber(newSpacing)
	if not newSpacing or newSpacing < 0 or self.Spacing == newSpacing then
		return
	end

	self.Spacing = newSpacing
	ApplyGroupLayout(self)
end

---Sets a group's icon budget. A value of 0 hides the group entirely (used for per-category
---toggles like ShowCC/ShowDefensives).
---@param groupKey string
---@param maxIcons number
function M:SetMaxIcons(groupKey, maxIcons)
	maxIcons = tonumber(maxIcons)
	if not maxIcons or maxIcons < 0 then
		return
	end

	for _, group in ipairs(self.Groups) do
		if group.Key == groupKey then
			if group.MaxIcons ~= maxIcons then
				group.MaxIcons = maxIcons
				self.Frame:SetAuraGroupMaxFrameCount(groupKey, maxIcons)
			end
			return
		end
	end
end

---@param grow string "LEFT"|"RIGHT"|"CENTER"|"UP"|"DOWN"
function M:SetGrow(grow)
	if self.Grow == grow then
		return
	end

	self.Grow = grow
	ApplyFlowLayout(self)
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

---Stops every button's glow animation. Used when parking a pooled display: a parked display's
---looping animations would otherwise keep costing CPU while hidden. Skipped while aura styling
---is restricted - the glow frames are CHILDREN of forbidden AuraButtons, and in combat even
---Hide() on them errors (the child-frame protections announced for 12.1 are live). The pending
---flag makes the next unrestricted restyle settle the right state, and pooled displays are
---restyled on every re-acquisition, so a skipped stop only leaves animations running until the
---display is reused or restrictions lift.
function M:StopGlowAnimations()
	self.RestylePending = true

	if wowEx:IsAuraStylingRestricted() then
		return
	end

	for _, widgets in pairs(self.ButtonWidgets) do
		local glow = widgets.Glow
		if glow then
			glow:Hide()
			glow.Anim:Stop()
		end
	end
end

---Re-applies the stored style to all created buttons. Buttons are forbidden while auras are
---secret (in combat, but also out-of-combat inside M+/encounters/PvP matches), so this is
---deferred then: the pending flag makes the next SetStyle/RestyleButtons retry even when the
---style itself is unchanged.
function M:RestyleButtons()
	if wowEx:IsAuraStylingRestricted() then
		self.RestylePending = true
		return
	end
	self.RestylePending = false

	for _, button in ipairs(self.Buttons) do
		StyleButton(self, button)
	end
end

-- Chain edges for anchoring a display after a kick icon frame, per grow direction (the kick
-- occupied the first slot in the legacy layouts, so the aura row continues after it).
local KICK_CHAIN_POINTS = {
	LEFT = { point = "RIGHT", relativeTo = "LEFT", xMul = -1, yMul = 0 },
	RIGHT = { point = "LEFT", relativeTo = "RIGHT", xMul = 1, yMul = 0 },
	CENTER = { point = "LEFT", relativeTo = "RIGHT", xMul = 1, yMul = 0 },
	DOWN = { point = "TOP", relativeTo = "BOTTOM", xMul = 0, yMul = -1 },
	UP = { point = "BOTTOM", relativeTo = "TOP", xMul = 0, yMul = 1 },
}

-- Grow direction -> anchor points for positioning a display against its anchor frame.
local GROW_ANCHOR_POINTS = {
	LEFT = { point = "RIGHT", relativeTo = "LEFT" },
	RIGHT = { point = "LEFT", relativeTo = "RIGHT" },
	DOWN = { point = "TOP", relativeTo = "BOTTOM" },
	UP = { point = "BOTTOM", relativeTo = "TOP" },
	CENTER = { point = "CENTER", relativeTo = "CENTER" },
}

---Positions this display relative to its anchor, chaining after the kick container while a
---kick icon is showing.
---@param kickFrame table The kick IconSlotContainer's frame.
---@param anchor table The frame the display is positioned against when no kick is active.
---@param grow string "LEFT"|"RIGHT"|"CENTER"|"UP"|"DOWN"
---@param spacing number Gap between the kick icon and the aura row.
---@param offsetX number
---@param offsetY number
---@param kickActive boolean
function M:AnchorAfterKick(kickFrame, anchor, grow, spacing, offsetX, offsetY, kickActive)
	self:SetGrow(grow or "CENTER")

	local frame = self.Frame
	frame:ClearAllPoints()

	if kickActive then
		local chain = KICK_CHAIN_POINTS[grow] or KICK_CHAIN_POINTS.CENTER
		frame:SetPoint(chain.point, kickFrame, chain.relativeTo, chain.xMul * spacing, chain.yMul * spacing)
	else
		local point = GROW_ANCHOR_POINTS[grow] or GROW_ANCHOR_POINTS.CENTER
		frame:SetPoint(point.point, anchor, point.relativeTo, offsetX, offsetY)
	end
end

---Renders a kick lockout into slot 1 of a legacy IconSlotContainer (kicks aren't auras, so
---they can't render through a container) and schedules onExpired shortly after the lockout
---ends - no aura event fires to clear it. Cancels previousTimer; returns the new timer (nil
---when there is nothing to wait for). Pass kickEntry nil to clear the slot.
---@param container IconSlotContainer
---@param kickEntry table?
---@param slotOptions table? SetSlot options for the kick icon (required when kickEntry is set).
---@param previousTimer table?
---@param onExpired fun()
---@return table? timer
function M:RenderKickSlot(container, kickEntry, slotOptions, previousTimer, onExpired)
	if previousTimer then
		previousTimer:Cancel()
	end

	if not kickEntry then
		container:SetSlotUnused(1)
		return nil
	end

	container:SetSlot(1, slotOptions)

	local remaining = (kickEntry.StartTime or 0) + (kickEntry.Duration or 0) - GetTime()
	if remaining > 0 then
		return C_Timer.NewTimer(remaining + 0.05, onExpired)
	end
	return nil
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
---@field Populated boolean?

---@class AuraDisplayGroupSpec
---@field Key string Group key (arbitrary, unique within the display).
---@field FilterString string Aura filter string (e.g. "HARMFUL|CROWD_CONTROL").
---@field MaxIcons number? Icon budget for this group (default 3).
---@field CandidateFilters table? Extra 12.1 candidate filters (e.g. { maxDuration = 4.1 }).

---@class AuraContainerDisplay
---@field Frame table The AuraContainer frame (anchor/show/hide through this).
---@field Size number
---@field Spacing number
---@field Groups AuraDisplayGroupSpec[]
---@field Grow string
---@field Style AuraDisplayStyle
---@field Layout table
---@field Buttons table[]
---@field ButtonWidgets table<table, table>
---@field DesiredShown boolean
