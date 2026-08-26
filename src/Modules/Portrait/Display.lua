---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local kickTracker = addon.Core.KickTracker
local kickSlot = addon.Core.KickSlot
local testSpellData = addon.Core.TestSpells
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local spellSearch = addon.Core.SpellSearch
local units = addon.Utils.UnitUtil
local sweep = addon.Core.Sweep

addon.Modules.Portrait = addon.Modules.Portrait or {}

---@class PortraitDisplay
local M = {}
addon.Modules.Portrait.Display = M

-- A portrait shows one icon and aura presence is secret, so the engine has to pick the winner.
-- Each category gets its own single-icon container and they stack on top of each other.

-- Priority stack for the portrait icon, lowest first. A higher-priority display covers the ones
-- below it, and an empty one hides its button secretly. The filters are the shared partitioned
-- ones, so an aura that fits several categories only ever lands in the highest of them.
local PORTRAIT_CATEGORIES = { "Important", "ExternalDefensive", "BigDefensive", "Disarm", "CrowdControl" }
-- Background walker declaring the aura groups of the displays as they are built. It is urgent
-- because a portrait is on screen already.
local buildSweep = sweep:New(true)

-- The user's own spell list. The engine honours a helpful spell-id map only on a unit you can
-- assist, and a harmful one only where you cannot, so a debuff list would be dropped and the
-- layer would match every debuff on you. Only the player token is always assistable.
local CUSTOM_UNIT = "player"
local CUSTOM_GROUP_KEY = "portraitcustom"
local CUSTOM_FILTER = "HELPFUL"

-- One strata down from whatever the portrait's own parent sits in. A portrait moved into a frame
-- at this strata keeps everything drawn over it under the unit frame's border art, whatever frame
-- levels the icons end up with, because strata beats level.
local STRATA_BELOW = {
	BACKGROUND = "BACKGROUND",
	LOW = "BACKGROUND",
	MEDIUM = "LOW",
	HIGH = "MEDIUM",
	DIALOG = "HIGH",
	FULLSCREEN = "DIALOG",
	FULLSCREEN_DIALOG = "FULLSCREEN",
	TOOLTIP = "FULLSCREEN_DIALOG",
}

---@type Db
local db
local testModeActive = false
-- True whenever the module is off or paused, and the live render paths bail on it. It starts true
-- because the module is not enabled until its first Refresh.
local suspended = true
---@type IconSlotContainer[]
local containers = {}
---@type TestSpell?
local testSpell
-- Kick slot options, rebuilt on every kick event and expiry timer. SetSlot reads
-- it synchronously and keeps nothing.
local kickSlotScratch = {}

local function AddMask(tex, mask)
	tex:AddMaskTexture(mask)
end

---The button style every portrait display takes: cooldown direction from the options, and never
---a border, glow or mouse input. Returned in the wrapper's shared scratch, so use it and hand it
---straight to SetStyle.
---@return AuraDisplayStyle
local function BuildPortraitStyle()
	-- The cooldown direction lives on the module options root, so there is no Icons table to pass.
	local style = auraContainerDisplay:BuildStandardStyle(nil)
	style.ReverseCooldown = db.Modules.Portrait.ReverseCooldown or false
	style.ShowTooltips = false

	return style
end

---The disarm layer's only real filter is its spell-ID map, which the engine skips for debuffs on
---assistable units, leaving the layer showing whatever debuff is newest. Budgeted away while the
---occupant is assistable, and re-checked whenever the token's occupant changes.
---@param auraDisplay { DisarmDisplay: AuraContainerDisplay }
---@param unit string
local function ApplyDisarmBudget(auraDisplay, unit)
	auraDisplay.DisarmDisplay:SetMaxIcons(auraFilters.GroupKey.Disarm, units:CanAssist(unit) and 0 or 1)
end

---One display's next group, from the walker. A portrait's displays are created with none of them
---because a unit frame turning up builds the whole stack in one pass, and each group costs a
---batch of buttons the engine allocates on the spot.
---@param display AuraContainerDisplay
---@return SweepVerdict?
local function DeclareNextGroup(display)
	if display:AddNextGroup() then
		return sweep.Verdict.Unfinished
	end
end

---Every id the custom list covers, each expanded to the ids sharing its name, because the aura
---the game applies is often not the one in the spellbook. A fresh table each call, since the
---engine keeps the reference it is handed.
---@return table? candidateFilters nil while the list is empty.
local function BuildCustomFilters()
	local spells = db.Modules.Portrait.CustomSpells

	-- The ticked spells are a hash, whose length is always zero.
	if not spells or next(spells) == nil then
		return nil
	end

	local ids = {}

	for spellId in pairs(spells) do
		for _, variant in ipairs(spellSearch:GetVariants(spellId)) do
			ids[variant] = true
		end
	end

	return { includeSpellIDs = ids }
end

---Pushes the current spell list at the custom layer. An empty list budgets it away rather than
---leaving it on a bare HELPFUL filter, which would match every buff the player has.
---@param auraDisplay { CustomDisplay: AuraContainerDisplay? }
local function ApplyCustomSpells(auraDisplay)
	local display = auraDisplay.CustomDisplay

	if not display then
		return
	end

	local filters = BuildCustomFilters()

	display:SetCandidateFilters(CUSTOM_GROUP_KEY, filters)
	display:SetMaxIcons(CUSTOM_GROUP_KEY, filters and 1 or 0)
end

---Builds the layered single-icon display stack over a portrait. Each display is parented to the
---kick container's frame so it follows the per-addon frame level adjustments the attach functions
---apply afterwards.
---@param kickFrame table The kick IconSlotContainer's frame, already anchored over the portrait.
---@param unit string
---@param texCoord table? {left, right, top, bottom} icon crop, per unit-frame addon.
---@param mask table? MaskTexture for round portraits (Blizzard frames).
---@param iconSize number
---@return { Displays: AuraContainerDisplay[], DisarmDisplay: AuraContainerDisplay, CustomDisplay: AuraContainerDisplay? }
local function CreatePortraitAuraDisplay(kickFrame, unit, texCoord, mask, iconSize)
	-- One single-icon aura group container per category. AuraSlots would be the natural fit, but
	-- they silently failed to render on the 12.1 PTR even though AddAuraSlot returned buttons and
	-- groups worked on the same client, and no known addon exercises them. Slots are documented as
	-- groups with maxFrameCount 1, so single-icon groups are the same thing on an API that works.
	--
	-- Levels stack up from the kick frame, two above it. The buttons render at the display's own
	-- level, so the lowest display has to clear whatever the portrait itself draws at, where on
	-- the PTR TargetFrame at 500 hid displays at 494-497. Distinct levels are the only reliable
	-- priority, since same-level siblings draw in an arbitrary order, verified live on 2026-08-07.
	--
	-- These go through AuraContainerDisplay because it owns the Edit Mode placeholder-aura
	-- suppression and the deferred restyling that re-applies option changes made while aura
	-- styling was restricted.
	local baseLevel = (kickFrame:GetFrameLevel() or 0) + 2
	local displays = {}
	local disarmDisplay
	local customDisplay

	local options = {
		IconTexCoord = texCoord,
		IconMask = mask,
		-- Portrait icons carry no dispel border and no glow.
		Minimal = true,
		-- The engine allocates a batch of buttons the moment a group is declared, so the walker
		-- declares them one per turn.
		DeferGroups = true,
		-- A portrait display is built the moment its unit frame turns up, and a restyle is
		-- refused for as long as auras are secret, so one created mid-arena would keep the
		-- unstyled look, mouse input and all.
		Style = BuildPortraitStyle(),
	}

	-- Bottom of the stack, so every flagged category covers it. The client allocates a group's
	-- buttons from the count it was born with and raising that later conjures none, so this is
	-- created with a budget of one whatever the list holds.
	if unit == CUSTOM_UNIT then
		customDisplay = auraContainerDisplay:New(kickFrame, unit, {
			{
				Key = CUSTOM_GROUP_KEY,
				FilterString = CUSTOM_FILTER,
				CandidateFilters = BuildCustomFilters(),
				MaxIcons = 1,
				SortDirection = AuraContainerSortDirection.Reverse,
			},
		}, iconSize, 0, "Portraits", options)

		displays[#displays + 1] = customDisplay
		buildSweep:Append(customDisplay, DeclareNextGroup)
	end

	for _, category in ipairs(PORTRAIT_CATEGORIES) do
		local display = auraContainerDisplay:New(kickFrame, unit, {
			-- A portrait shows your own unit or one you picked, so the out-of-range filter bug
			-- the spell-ID maps work around has almost nowhere to bite, and the group covers
			-- every flagged aura instead of the curated subset.
			auraFilters:GroupSpec(category, 1, {
				-- Reverse instance-id order = newest aura first.
				SortDirection = AuraContainerSortDirection.Reverse,
			}, true),
		}, iconSize, 0, "Portraits", options)

		displays[#displays + 1] = display
		buildSweep:Append(display, DeclareNextGroup)

		if category == "Disarm" then
			disarmDisplay = display
		end
	end

	for index, display in ipairs(displays) do
		local frame = display.Frame
		frame:SetAllPoints(kickFrame)
		frame:SetIgnoreParentAlpha(true)
		-- Scale with the portrait, unlike the free-standing displays elsewhere.
		frame:SetIgnoreParentScale(false)
		frame:SetFrameLevel(baseLevel + index - 1)
	end

	local auraDisplay = { Displays = displays, DisarmDisplay = disarmDisplay, CustomDisplay = customDisplay }
	ApplyDisarmBudget(auraDisplay, unit)
	ApplyCustomSpells(auraDisplay)

	return auraDisplay
end

function M:GetPortraitMask(unitFrame)
	-- player
	if unitFrame.PlayerFrameContainer and unitFrame.PlayerFrameContainer.PlayerPortraitMask then
		return unitFrame.PlayerFrameContainer.PlayerPortraitMask
	end

	-- target/focus
	if unitFrame.TargetFrameContainer and unitFrame.TargetFrameContainer.PortraitMask then
		return unitFrame.TargetFrameContainer.PortraitMask
	end

	-- target of target and pet frame
	if unitFrame.PortraitMask then
		return unitFrame.PortraitMask
	end

	return nil
end

function M:CreatePortraitMask(portrait)
	local parent = portrait:GetParent()
	if not parent then
		return nil
	end

	local mask = parent:CreateMaskTexture()
	mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(portrait)
	return mask
end

function M:ApplyMaskToLayer(layer, mask)
	if not layer then
		return
	end

	-- A portrait is round already, so its icon must not also pick up the rounded-square corners a
	-- glow asks for.
	layer.CustomShape = true

	if layer.Icon then
		if mask then
			AddMask(layer.Icon, mask)
		end
		-- Crop the icon like Blizzard does
		layer.Icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
	end

	if layer.Cooldown then
		-- Keep cooldown within the portrait icon
		layer.Cooldown:SetSwipeTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	end
end

---Moves a portrait into a frame one strata below the rest of its unit frame, so anything drawn
---over the portrait stays under the frame's border art however its levels come out. The portrait
---has to come along, since left where it was it would cover the icons from the strata above.
---@param portrait table
---@return table? layer nil when the portrait's anchoring cannot be reproduced
function M:CreatePortraitLayer(portrait)
	local parent = portrait:GetParent()
	if not parent then
		return nil
	end

	-- The portrait is re-anchored by hand after the move, so anything but a single point would
	-- come out a different size. Those portraits keep the old layering instead.
	if portrait:GetNumPoints() ~= 1 then
		return nil
	end

	-- The same guard CreateContainer bails on. Without it a tainted portrait would be demoted a
	-- strata and then get no container, leaving it under the frame art for nothing.
	if issecretvalue(portrait:GetWidth()) or issecretvalue(portrait:GetHeight()) then
		return nil
	end

	local point, relativeTo, relativePoint, x, y = portrait:GetPoint(1)
	if not point then
		return nil
	end

	local layer = CreateFrame("Frame", nil, parent)
	layer:SetAllPoints(parent)
	layer:SetFrameStrata(STRATA_BELOW[parent:GetFrameStrata()] or "BACKGROUND")
	-- Level 0 of this strata is reserved for portrait effects that have to stay behind the
	-- portrait, such as the insanity bar's Voidform glow.
	layer:SetFrameLevel(1)

	portrait:SetParent(layer)
	portrait:ClearAllPoints()
	portrait:SetPoint(point, relativeTo or layer, relativePoint or point, x or 0, y or 0)

	return layer
end

---Builds the kick container over a portrait, with the aura display stack underneath it.
---Returns nil when the portrait's dimensions are secret, which is the tainted-frame case.
---@param portraitLayer table? demoted layer from CreatePortraitLayer. The container goes inside
---it and matches the portrait rect exactly, since the border art now covers the icon's edges.
---@return IconSlotContainer?
function M:CreateContainer(unitFrame, portrait, unit, texCoord, mask, portraitLayer)
	-- One slot with multiple layers, and no border for portrait icons.
	local container = iconSlotContainer:New(portraitLayer or unitFrame, 1, 0, 0, nil, true, "Portraits")

	-- Portrait icons are masked, and the mask texture lives on the unit frame's subtree. A
	-- flattened slot composites only its own subtree, which renders the masked icon invisible.
	local slot = container.Slots[1]
	if slot and slot.Frame then
		slot.Frame:SetFlattensRenderLayers(false)
	end

	if portraitLayer then
		-- Levels only have to clear the portrait now, and matching its rect exactly lines the
		-- icon up with the portrait's own mask.
		container.Frame:SetAllPoints(portrait)
		container.Frame:SetFrameLevel(portraitLayer:GetFrameLevel() + 1)
	else
		container.Frame:SetPoint("TOPLEFT", portrait, "TOPLEFT", 2, -2)
		container.Frame:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -2, 2)
		container.Frame:SetFrameLevel(math.max(0, (unitFrame:GetFrameLevel() or 0) - 1))
	end

	-- Addons like ClassicFrames move the portrait parent from LOW to MEDIUM, so following its
	-- strata is what keeps the icons visible.
	container.Frame:SetFrameStrata(portrait:GetParent():GetFrameStrata())

	-- Inherit scale from the portrait so the icons scale with it.
	container.Frame:SetIgnoreParentScale(false)

	-- Portrait icons stay fully opaque when the parent unit frame fades out of range.
	container.Frame:SetIgnoreParentAlpha(true)

	-- A tainted frame reports secret dimensions, which turns up with ElvUI when its own portraits
	-- are switched off.
	local w = portrait:GetWidth()
	local h = portrait:GetHeight()
	if issecretvalue(w) or issecretvalue(h) then return nil end

	-- The 2px inset exists only to keep an un-layered icon off the border art. A layered icon is
	-- covered by that art already and wants the full portrait rect.
	local inset = portraitLayer and 0 or 4
	local size = math.min(w - inset, h - inset)
	if size <= 0 then size = 32 end

	container:SetIconSize(size)

	if unit then
		-- Lift the kick slot above the whole aura display stack, which runs kick+2 to +7 on the
		-- player's portrait and +2 to +6 elsewhere, so an active kick lockout covers any aura
		-- icon. +8 leaves one level of margin in case a future build moves the buttons one above
		-- their container. The icon layer renders at slot+1.
		if slot and slot.Frame then
			slot.Frame:SetFrameLevel(container.Frame:GetFrameLevel() + 8)
		end

		container.AuraDisplay = CreatePortraitAuraDisplay(container.Frame, unit, texCoord, mask, size)
		container.AuraUnit = unit
	end

	return container
end

---Adds a finished container to the render set. Kept separate from CreateContainer so the attach
---functions can apply their per-addon frame level and slot adjustments first.
---@param container IconSlotContainer
function M:AddContainer(container)
	containers[#containers + 1] = container
end

---@return IconSlotContainer[]
function M:GetContainers()
	local result = {}
	for _, container in pairs(containers) do
		result[#result + 1] = container
	end
	return result
end

---Renders the kick icon into the kick container. Schedules a follow-up when the kick expires,
---since no aura event will fire to clear it.
---@param unit string
---@param container IconSlotContainer
function M:UpdateKickIcon(unit, container)
	if suspended then
		return
	end

	local kickEntry = kickTracker:GetKick(unit)
	local slotOptions

	if kickEntry then
		slotOptions = kickSlotScratch
		slotOptions.Texture = kickEntry.Texture
		slotOptions.DurationObject = kickEntry.DurationObject
		slotOptions.Alpha = true
		slotOptions.ReverseCooldown = db.Modules.Portrait.ReverseCooldown
		slotOptions.FontScale = db.FontScale
		slotOptions.Color = kickEntry.Color
	end

	container.KickTimer = kickSlot:Render(container, kickEntry, slotOptions, container.KickTimer, function()
		container.KickTimer = nil
		M:UpdateKickIcon(unit, container)
	end)
end

---Re-reads every aura on the containers tracking a unit, for when the token's occupant changes
---rather than its auras.
---@param unit string
function M:RefreshUnitAuras(unit)
	for _, container in pairs(containers) do
		if container.AuraUnit == unit and container.AuraDisplay then
			-- The token's occupant just changed, so its reaction may have flipped too.
			ApplyDisarmBudget(container.AuraDisplay, unit)
			for _, display in ipairs(container.AuraDisplay.Displays) do
				display:RequestRefresh()
			end
		end
	end
end

function M:RefreshTestIcons()
	local spellId = testSpell.SpellId
	local tex = C_Spell.GetSpellTexture(spellId)
	local now = GetTime()

	for _, container in pairs(containers) do
		moduleUtil:SetTestLabel(container.Frame, L["Portraits_Short"] or L["Portraits"])
		container:SetSlot(1, {
			Texture = tex,
			DurationObject = wowEx:CreateDuration(now, 15),
			Alpha = true,
			Glow = false,
			ReverseCooldown = db.Modules.Portrait.ReverseCooldown,
			FontScale = db.FontScale,
		})
	end
end

function M:ResetAllSlots()
	for _, container in pairs(containers) do
		container:ResetAllSlots()
	end
end

---@param value boolean
function M:SetSuspended(value)
	suspended = value
end

---@param active boolean
function M:SetTestMode(active)
	testModeActive = active
end

function M:Teardown()
	for _, container in pairs(containers) do
		container:ResetAllSlots()
		if container.AuraDisplay then
			for _, display in ipairs(container.AuraDisplay.Displays) do
				display:SetEnabled(false)
				display:Hide()
			end
		end
	end
end

function M:EnsureFrames()
	for _, container in pairs(containers) do
		if container.AuraDisplay then
			for _, display in ipairs(container.AuraDisplay.Displays) do
				display:SetEnabled(true)
				display:Show()
			end
		end
	end
end

function M:ApplyOptions()
	-- The wrapper defers a restyle while aura styling is restricted and retries once it lifts.
	-- Live displays are hidden in test mode so real and fake icons do not mix.
	local style = BuildPortraitStyle()

	for _, container in pairs(containers) do
		local auraDisplay = container.AuraDisplay
		if auraDisplay then
			-- A token's occupant can turn friendly while the module is disabled and its events
			-- are unregistered, which would leave the disarm layer budgeted for an enemy and
			-- showing every debuff on an ally. Re-checked here so any Refresh closes that gap.
			ApplyDisarmBudget(auraDisplay, container.AuraUnit)
			ApplyCustomSpells(auraDisplay)

			for _, display in ipairs(auraDisplay.Displays) do
				display:SetStyle(style)
				display:SetShown(not testModeActive)
			end
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()

	-- One icon, so only the first preview spell is ever shown.
	testSpell = testSpellData.CrowdControl[1]
end
