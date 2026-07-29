---@type string, Addon
local addonName, addon = ...
local fontUtil = addon.Utils.FontUtil
local wowEx = addon.Utils.WoWEx
local cachedDb = nil
local frameIdCounter = 0

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

	local db = GetDb()
	local cd = widgets.Cooldown
	cd:SetReverse(style.ReverseCooldown or false)
	cd:SetDrawSwipe(not (db and db.DisableSwipe))
	if cd.SetCountdownMillisecondsThreshold then
		cd:SetCountdownMillisecondsThreshold(style.ShowMilliseconds and (db and db.MillisecondsThreshold or 5) or 0)
	end
	cd.FontScale = style.FontScale or 1.0
	fontUtil:UpdateCooldownFontSize(cd, instance.Size, nil, cd.FontScale)

	-- The dispel border is registered once and shown/hidden per aura by the button itself; the
	-- ColorByDispelType option only controls whether the border texture participates at all.
	if not widgets.BorderRegistered then
		-- Not yet handed to the button, so its visibility is still ours to control.
		widgets.Border:Hide()
	end
	if style.ColorByDispelType and not widgets.BorderRegistered then
		widgets.BorderRegistered = true
		button:AddDispelTypeTexture(widgets.Border, {
			style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
			showWhenHarmful = true,
			showWhenHelpful = true,
		})
	elseif not style.ColorByDispelType and widgets.BorderRegistered then
		widgets.BorderRegistered = false
		button:ClearDispelTypeTextures()
	end

	-- Glow: the frame is created as a button child at init (LibCustomGlow can't be used here -
	-- it re-parents pooled frames onto the target, and 12.1 disallows SetParent onto AuraButtons
	-- because the child would inherit their forbidden aspects). It shows and hides with the
	-- button (button visibility is secret, but child rendering follows the parent without any
	-- addon-readable state). The looping animation only runs while the glow style is enabled:
	-- a REPEAT animation costs CPU every frame even on hidden frames, and with thousands of
	-- pre-created buttons that showed up as constant background load.
	local glow = widgets.Glow
	if glow then
		if style.Glow then
			local padding = instance.Size / 3
			glow:SetPoint("TOPLEFT", button, "TOPLEFT", -padding, padding)
			glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", padding, -padding)
			glow:Show()
			if not glow.Anim:IsPlaying() then
				glow.Anim:Play()
			end
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
	-- re-parenting is not). Same flipbook visual as IconSlotContainer's "Rotation Assist" glow.
	local glow = CreateFrame("Frame", NextFrameName("Glow"), button)
	glow:SetFrameLevel(button:GetFrameLevel() + 5)
	glow.Texture = glow:CreateTexture(nil, "OVERLAY")
	glow.Texture:SetAllPoints()
	glow.Texture:SetTexture("Interface\\AddOns\\" .. addonName .. "\\Textures\\FlipbookWhite.tga")
	glow.Texture:SetBlendMode("ADD")
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
		BorderRegistered = false,
		Glow = glow,
	}
	instance.Buttons[#instance.Buttons + 1] = button

	StyleButton(instance, button)
end

-- Maps a module Grow option to flow layout settings. The first icon always sits nearest the
-- container's anchored edge, matching the legacy layouts.
local growLayouts = {
	LEFT = { axis = "Horizontal", anchorPoint = "RIGHT", h = "Left", v = "Down" },
	RIGHT = { axis = "Horizontal", anchorPoint = "LEFT", h = "Right", v = "Down" },
	CENTER = { axis = "Horizontal", anchorPoint = "LEFT", h = "Right", v = "Down" },
	DOWN = { axis = "Vertical", anchorPoint = "TOP", h = "Right", v = "Down" },
	UP = { axis = "Vertical", anchorPoint = "BOTTOM", h = "Right", v = "Up" },
}

---@param instance AuraContainerDisplay
local function ApplyFlowLayout(instance)
	local layout = growLayouts[instance.Grow] or growLayouts.CENTER
	local frame = instance.Frame
	frame:SetFlowLayoutAxis(AnchorUtil.FlowLayoutAxis[layout.axis])
	frame:SetFlowLayoutAnchorPoint(layout.anchorPoint)
	frame:SetFlowLayoutGrowthDirection(AnchorUtil.FlowDirection[layout.h], AnchorUtil.FlowDirection[layout.v])
end

---Builds a group layout table. Spacing keys are passed under BOTH the older and newer PTR
---spellings (elementSpacing/lineSpacing was renamed to elementSpacingX/elementSpacingY in a
---later 12.1 build); validators ignore unknown keys, so this works on either build.
---@param instance AuraContainerDisplay
---@return table
local function BuildGroupLayout(instance)
	return {
		elementSpacing = instance.Spacing,
		lineSpacing = instance.Spacing,
		elementSpacingX = instance.Spacing,
		elementSpacingY = instance.Spacing,
		elementWidth = instance.Size,
		elementHeight = instance.Size,
	}
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
	instance.Style = {}
	instance.Buttons = {}
	-- button -> { Cooldown, Border, BorderRegistered, Glow } for restyling.
	instance.ButtonWidgets = {}

	local frame = CreateFrame("AuraContainer", NextFrameName("Container"), parent, "CustomAuraContainerTemplate")
	frame:SetIgnoreParentScale(true)
	frame.MiniCCModule = moduleName or nil
	instance.Frame = frame

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

---Creates a pre-creating pool of display objects (a display or a bundle of displays per item,
---as built by createFn; resetFn parks an item - disable, hide, unanchor). Pre-creation is
---staggered on a timer so login doesn't hitch, and containers are never created mid-combat in
---practice; Acquire falls back to on-demand creation only if demand outruns the pool (which
---the 12.1 API permits, at the cost of a combat frame spike).
---@param createFn fun(): table
---@param resetFn fun(item: table)
---@param preallocateCount number
---@return table pool Pool with Acquire/Release methods.
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
	local ticker
	ticker = C_Timer.NewTicker(0.1, function()
		if created >= preallocateCount then
			ticker:Cancel()
			return
		end
		for _ = 1, 2 do
			if created < preallocateCount then
				created = created + 1
				local item = createFn()
				resetFn(item)
				pool.Free[#pool.Free + 1] = item
			end
		end
	end)

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

---Builds a change-detection signature for a style, including the global db values StyleButton
---reads (so config changes to those still trigger a restyle).
---@param style AuraDisplayStyle
---@return string
local function StyleSignature(style)
	local db = GetDb()
	return table.concat({
		tostring(style.ReverseCooldown),
		tostring(style.ShowMilliseconds),
		tostring(style.ColorByDispelType),
		tostring(style.Glow),
		tostring(style.FontScale),
		tostring(style.ShowTooltips),
		tostring(db and db.DisableSwipe),
		tostring(db and db.MillisecondsThreshold),
	}, "|")
end

---Stores the per-button style and applies it to existing buttons when possible. Skipped
---entirely when nothing changed - this runs on hot paths (every nameplate add), and restyling
---means ~10 API calls across every pre-created button.
---@param style AuraDisplayStyle
function M:SetStyle(style)
	self.Style = style or {}

	local signature = StyleSignature(self.Style)
	if signature == self.StyleSignature and not self.RestylePending then
		return
	end
	self.StyleSignature = signature

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
local kickChainPoints = {
	LEFT = { point = "RIGHT", relativeTo = "LEFT", xMul = -1, yMul = 0 },
	RIGHT = { point = "LEFT", relativeTo = "RIGHT", xMul = 1, yMul = 0 },
	CENTER = { point = "LEFT", relativeTo = "RIGHT", xMul = 1, yMul = 0 },
	DOWN = { point = "TOP", relativeTo = "BOTTOM", xMul = 0, yMul = -1 },
	UP = { point = "BOTTOM", relativeTo = "TOP", xMul = 0, yMul = 1 },
}

-- Grow direction -> anchor points for positioning a display against its anchor frame.
local growAnchorPoints = {
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
		local chain = kickChainPoints[grow] or kickChainPoints.CENTER
		frame:SetPoint(chain.point, kickFrame, chain.relativeTo, chain.xMul * spacing, chain.yMul * spacing)
	else
		local point = growAnchorPoints[grow] or growAnchorPoints.CENTER
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
---@field Buttons table[]
---@field ButtonWidgets table<table, table>
