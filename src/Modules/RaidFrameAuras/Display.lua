---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local auraCategoryIds = addon.Core.AuraCategoryIds
local UnitAuraWatcher = addon.Core.UnitAuraWatcher
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local slotDistribution = addon.Utils.SlotDistribution
local wowEx = addon.Utils.WoWEx
local kickTracker = addon.Core.KickTracker
local anchoredIcons = addon.Core.AnchoredIcons
local testSpellData = addon.Core.TestSpells

addon.Modules.RaidFrameAuras = addon.Modules.RaidFrameAuras or {}

---@class RaidFrameAurasDisplay
local M = {}
addon.Modules.RaidFrameAuras.Display = M

-- 12.1 path: CC + defensive auras render through an AuraContainer per anchor (one group per
-- category); the IconSlotContainer is kept for the kick icon and test mode. Unlike the legacy
-- path there is no dynamic slot split between categories (aura counts are unreadable), so each
-- enabled category gets the full MaxIcons budget. TEMPORARY dual path: remove the watcher
-- branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local paused = false
local testModeActive = false
-- Anchor frame -> the container, display and watcher drawn on it. Owned here: the module asks
-- for whole-set operations rather than reaching into it.
---@type table<table, RaidFrameAurasWatchEntry>
local watchers = {}
---@type TestSpell[]
local testDefensiveSpells = {}
---@type TestSpell[]
local testCcSpells = {}
---@type Db
local db
-- Reused per-group icon budget map handed to ApplyEntryOptions.
local budgetScratch = {}

-- Helpful auras are filtered by spell id alone rather than by Blizzard's category flags. That is
-- only possible here because the gate on spell-id filters is UnitCanAssist, and this module
-- tracks assistable units - the same swap on an enemy-facing display would silently show every
-- buff. It buys the ability to track spells the game never flags, at the cost of showing nothing
-- that is not explicitly listed.
--
-- One group, not the usual big/external/important split: with the category tokens gone there is
-- nothing left to partition them by, and three groups sharing one id list would each accept the
-- same aura and draw it three times.
-- Read-only stand-in so the lookups below never have to nil-check.
local EMPTY_TABLE = {}
local HELPFUL_GROUP_KEY = "helpful"
local HELPFUL_FILTER = "HELPFUL"

-- Rebuilt whenever the tracked set changes; handed straight to the engine, which keeps the
-- reference, so it is replaced rather than mutated in place.
local helpfulFilters = { includeSpellIDs = {} }

---The spell ids currently tracked: the curated defensive and important lists, minus the ones the
---user switched off, plus anything they added by hand.
---@return table filters
local function GetHelpfulFilters()
	local overrides = db.Modules.RaidFrameAurasModule.Spells
	local disabled = (overrides and overrides.Disabled) or EMPTY_TABLE
	local ids = {}

	local sources = {
		auraCategoryIds.Defensive,
		auraCategoryIds.Important,
		-- Not flagged by the game at all; only reachable because this group filters by id.
		auraCategoryIds.Unflagged,
	}

	local curated = {}
	local enabled = (overrides and overrides.Enabled) or EMPTY_TABLE

	for _, source in ipairs(sources) do
		for spellId in pairs(source) do
			curated[spellId] = true
			-- Off-by-default spells need an explicit opt-in; the rest are on unless switched off.
			local tracked = not disabled[spellId]
				and (not auraCategoryIds.DefaultOff[spellId] or enabled[spellId])

			if tracked then
				ids[spellId] = true
			end
		end
	end

	local custom = (overrides and overrides.Custom) or EMPTY_TABLE

	for spellId in pairs(custom) do
		-- A spell the user added by hand can later ship in the curated lists. Drop their copy
		-- when that happens: leaving it would list the spell twice in the options - once under
		-- its class and once under Custom - with two checkboxes driving the same tracked state.
		if curated[spellId] then
			custom[spellId] = nil
		elseif not disabled[spellId] then
			ids[spellId] = true
		end
	end

	helpfulFilters = { includeSpellIDs = ids }

	return helpfulFilters
end

---@param maxIcons number
---@return table[]
local function BuildGroups(maxIcons)
	return {
		auraFilters:GroupSpec("CrowdControl", maxIcons),
		-- Not a standard category: the helpful side filters by the user-curated spell id list
		-- rather than Blizzard's category tokens (see the header comment above).
		{
			Key = HELPFUL_GROUP_KEY,
			FilterString = HELPFUL_FILTER,
			CandidateFilters = GetHelpfulFilters(),
			MaxIcons = maxIcons,
		},
	}
end

local function GetOptions()
	local m = db.Modules.RaidFrameAurasModule
	if not m then
		return nil
	end
	return instanceOptions:IsRaid() and m.Raid or m.Default
end

---The look a display is built with and restyled to.
---@param entryOptions table
---@return AuraDisplayStyle
local function BuildStyle(entryOptions)
	local style = auraContainerDisplay:BuildStandardStyle(entryOptions.Icons)

	style.ShowTooltips = entryOptions.ShowTooltips ~= false

	return style
end

-- TEMPORARY: legacy 12.0 renderer; dies with the watcher path.
local function UpdateWatcherAuras(entry)
	if not entry or not entry.Watcher or not entry.Container then
		return
	end

	if paused then
		return
	end

	if not entry.Unit then
		return
	end

	if not UnitExists(entry.Unit) then
		for i = 1, entry.Container.Count do
			entry.Container:SetSlotUnused(i)
		end
		return
	end

	local options = GetOptions()
	if not options or not moduleUtil:IsModuleEnabled(moduleName.RaidFrameAuras) then
		return
	end

	-- Cache config options for performance
	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local maxIcons = options.Icons.MaxIcons or 1
	local container = entry.Container
	local colorByDispelType = options.Icons.ColorByDispelType
	local showTooltips = options.ShowTooltips ~= false

	-- Get aura states
	local ccState = entry.Watcher:GetCcState()
	local defensiveState = entry.Watcher:GetDefensiveState()
	local kickEntry = options.ShowKicks ~= false and kickTracker:GetKick(entry.Unit) or nil

	local ccCount = options.ShowCC and #ccState or 0
	local defensiveCount = options.ShowDefensives and #defensiveState or 0

	local slotIndex = 1

	-- Kick is highest priority: always occupies slot 1 when active
	if kickEntry then
		container:SetSlot(slotIndex, {
			Texture = kickEntry.Texture,
			DurationObject = kickEntry.DurationObject,
			Color = colorByDispelType and kickEntry.Color,
			Alpha = true,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			FontScale = db.FontScale,
		})
		slotIndex = slotIndex + 1
	end

	-- Distribute remaining slots: CC first, then Defensive
	local remainingSlots = maxIcons - (slotIndex - 1)
	local ccSlots, defensiveSlots =
		slotDistribution.Calculate(remainingSlots, ccCount, defensiveCount, 0)

	for i = 1, ccSlots do
		if slotIndex > container.Count then
			break
		end
		local aura = ccState[i]
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			DurationObject = aura.DurationObject,
			Alpha = aura.IsCC,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			Color = colorByDispelType and aura.DispelColor,
			FontScale = db.FontScale,
			SpellId = showTooltips and aura.SpellId or nil,
		})
		slotIndex = slotIndex + 1
	end

	for i = 1, defensiveSlots do
		if slotIndex > container.Count then
			break
		end
		local aura = defensiveState[i]
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			DurationObject = aura.DurationObject,
			Alpha = aura.IsDefensive,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			Color = colorByDispelType and aura.DispelColor,
			FontScale = db.FontScale,
			SpellId = showTooltips and aura.SpellId or nil,
		})
		slotIndex = slotIndex + 1
	end

	-- Clear any unused slots beyond the aura count
	for i = slotIndex, container.Count do
		container:SetSlotUnused(i)
	end
end

---Whether a kick icon currently occupies the entry's container. With kicks switched off the
---display has no kick icon to chain past.
---@param entry RaidFrameAurasWatchEntry
---@param options RaidFrameAurasInstanceOptions
---@return boolean
local function IsKickActive(entry, options)
	return options.ShowKicks ~= false and kickTracker:GetKick(entry.Unit) ~= nil
end

---12.1 path: positions the aura display on its anchor, chaining after the kick container while
---a kick icon is showing (the kick occupied slot 1 in the legacy layout).
---@param entry RaidFrameAurasWatchEntry
---@param anchor table
---@param options RaidFrameAurasInstanceOptions
local function AnchorAuraDisplay(entry, anchor, options)
	anchoredIcons:AnchorAuraDisplay(entry, anchor, options, IsKickActive(entry, options))
end

---12.1 path: renders the kick icon into the entry's IconSlotContainer (slot 1) and re-anchors
---the aura display around it.
---@param entry RaidFrameAurasWatchEntry
local function UpdateKickIcon(entry)
	if not entry or not entry.Container or paused or testModeActive then
		return
	end

	local options = GetOptions()
	if not options or not moduleUtil:IsModuleEnabled(moduleName.RaidFrameAuras) then
		return
	end

	local kickEntry = options.ShowKicks ~= false and kickTracker:GetKick(entry.Unit) or nil

	anchoredIcons:RenderKickIcon(entry, options, kickEntry, function()
		entry.KickTimer = nil
		UpdateKickIcon(entry)
	end)
end

-- Which renderer a live aura update goes through. Bound once at load rather than branching on
-- USE_AURA_CONTAINERS at each of the call sites below: on 12.1 the aura icons are entirely
-- container-driven and only the kick slot needs pushing, on 12.0 the watcher redraws everything.
-- TEMPORARY: when the legacy path goes, this alias goes with it and the callers just call
-- UpdateKickIcon.
---@type fun(entry: RaidFrameAurasWatchEntry)
local RenderEntry = USE_AURA_CONTAINERS and UpdateKickIcon or UpdateWatcherAuras -- luaconv: aliases the two renderers above

---@param anchor table
---@param unit string?
local function EnsureWatcher(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	if units:IsCompoundUnit(unit) then
		return nil
	end

	if units:IsPetOrMinion(unit) then
		return nil
	end

	local options = GetOptions()

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		local size = moduleUtil:GetIconSize(options.Icons, anchor, 32, 75)
		local spacing = options.IconSpacing or 2
		-- "Friendly Indicators" is the module's old name, kept because it is the Masque group name
		-- (and the public MiniCCModule frame tag). Renaming it would orphan every skin users have
		-- already assigned to this group.
		local container = iconSlotContainer:New(UIParent, maxIcons, size, spacing, "Friendly Indicators", nil, "Friendly Indicators")

		entry = {
			Container = container,
			Anchor = anchor,
			Unit = unit,
			KickKey = 0,
		}
		watchers[anchor] = entry

		if USE_AURA_CONTAINERS then
			-- The four standard categories, partitioned by filter negation so an aura only ever
			-- lands in one group (see Core/AuraFilters). The important group is a 12.1 addition
			-- with no legacy equivalent (the legacy path can't identify important buffs without
			-- the secret-alpha stacking trick).
			entry.Display = auraContainerDisplay:New(
				UIParent,
				unit,
				BuildGroups(maxIcons),
				size,
				spacing,
				"Friendly Indicators",
				-- Seeded rather than left to the restyle below: a unit's display is built the
				-- moment it turns up, and one built mid-arena can never be restyled.
				{ Style = BuildStyle(options) }
			)
		else
			entry.Watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, CC = true })
			entry.Watcher:RegisterCallback(function()
				UpdateWatcherAuras(entry)
			end)
		end

		kickTracker:Watch(unit)
		entry.KickKey = kickTracker:Subscribe(unit, function()
			RenderEntry(entry)
		end)
	else
		-- Check if unit has changed
		if entry.Unit ~= unit then
			if USE_AURA_CONTAINERS then
				-- The container tracks the new unit itself; only the unit token changes.
				entry.Display:SetUnit(unit)
			else
				-- Unit changed, recreate the watcher
				entry.Watcher:Dispose()
				entry.Watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, CC = true })
				entry.Watcher:RegisterCallback(function()
					UpdateWatcherAuras(entry)
				end)
			end

			kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				RenderEntry(entry)
			end)

			entry.Unit = unit

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()

			-- Force immediate refresh for the new unit
			RenderEntry(entry)
		end
	end

	RenderEntry(entry)
	anchoredIcons:AnchorContainer(entry.Container, anchor, options)

	if entry.Display then
		AnchorAuraDisplay(entry, anchor, options)
		frames:ShowHideDisplay(entry.Display, anchor, options.ExcludePlayer)
	end

	frames:ShowHideFrame(entry.Container.Frame, anchor, testModeActive, options.ExcludePlayer)

	if testModeActive then
		moduleUtil:SetTestLabel(entry.Container.Frame, L["Raid Frame Auras_Short"] or L["Raid Frame Auras"])
	end

	return entry
end

local function EnsureWatchers()
	local anchors = frames:GetAll(true, testModeActive)

	for _, anchor in ipairs(anchors) do
		EnsureWatcher(anchor)
	end
end

local function OnCufUpdateVisible(frame)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	local entry = watchers[frame]

	if not entry then
		return
	end

	local options = GetOptions()

	if not options then
		return
	end

	-- 12.1: the aura icons live in entry.Display, not the kick/test container - it must
	-- follow the unit frame's visibility too.
	if entry.Display then
		frames:ShowHideDisplay(entry.Display, frame, options.ExcludePlayer)
	end

	frames:ShowHideFrame(entry.Container.Frame, frame, false, options.ExcludePlayer)
end

local function OnCufSetUnit(frame, unit)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	if not unit then
		return
	end

	EnsureWatcher(frame, unit)
end

local function RefreshTestIcons()
	local options = GetOptions()

	if not options then
		return
	end

	-- ensure predictable ordering for showing the test spell icon on visible entries
	local orderedEntries = {}
	for _, entry in pairs(watchers) do
		if entry.Anchor and entry.Anchor:IsShown() then
			table.insert(orderedEntries, entry)
		end
	end

	local ccCount = options.ShowCC and #testCcSpells or 0
	local defensiveCount = options.ShowDefensives and #testDefensiveSpells or 0
	local showKicks = options.ShowKicks ~= false

	for _, entry in ipairs(orderedEntries) do
		local container = entry.Container
		local now = GetTime()
		local maxIcons = options.Icons.MaxIcons or 1
		local iconsReverse = options.Icons.ReverseCooldown
		local iconsGlow = options.Icons.Glow
		local colorByDispelType = options.Icons.ColorByDispelType
		local showTooltips = options.ShowTooltips ~= false

		local slotIndex = 1

		if showKicks then
			container:SetSlot(slotIndex, {
				Texture = C_Spell.GetSpellTexture(1766),
				DurationObject = wowEx:CreateDuration(now, 3),
				Alpha = true,
				ReverseCooldown = iconsReverse,
				Glow = iconsGlow,
				FontScale = db.FontScale,
			})
			slotIndex = slotIndex + 1
		end

		local remainingSlots = maxIcons - (slotIndex - 1)
		local ccSlots, defensiveSlots =
			slotDistribution.Calculate(remainingSlots, ccCount, defensiveCount, 0)

		slotIndex = testSpellData:FillContainer(container, testCcSpells, slotIndex, {
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			ColorByDispelType = colorByDispelType,
			FontScale = db.FontScale,
			ShowTooltips = showTooltips,
			Count = ccSlots,
		})

		slotIndex = testSpellData:FillContainer(container, testDefensiveSpells, slotIndex, {
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			FontScale = db.FontScale,
			ShowTooltips = showTooltips,
			Count = defensiveSlots,
		})

		for i = slotIndex, container.Count do
			container:SetSlotUnused(i)
		end

		anchoredIcons:AnchorContainer(container, entry.Anchor, options)
		frames:ShowHideFrame(container.Frame, entry.Anchor, true, options.ExcludePlayer)
	end
end

local function Teardown()
	for _, entry in pairs(watchers) do
		anchoredIcons:TeardownEntry(entry)
	end
end

-- Wakes every entry's watcher/display back up, then discovers any unit frames that have
-- appeared since the last refresh.
local function EnsureFrames()
	for _, entry in pairs(watchers) do
		if entry.Watcher then
			entry.Watcher:Enable()
		end
		if entry.Display then
			entry.Display:SetEnabled(true)
		end
	end

	EnsureWatchers()
end

---@param entry RaidFrameAurasWatchEntry
---@param anchor table
---@param options RaidFrameAurasInstanceOptions
local function ApplyEntryOptions(entry, anchor, options)
	local iconSize = moduleUtil:GetIconSize(options.Icons, anchor, 32, 75)
	local maxIcons = tonumber(options.Icons.MaxIcons) or 1
	local style

	if entry.Display then
		style = BuildStyle(options)

		-- Category toggles map to a zero icon budget for the disabled group. One helpful group
		-- covers both remaining categories, so either toggle keeps it visible; they no longer
		-- select BETWEEN categories - the Spells tab does that.
		local showHelpful = options.ShowDefensives or options.ShowImportant
		-- Spell-id filters are gated on UnitCanAssist, so the moment a party member becomes a
		-- duel opponent the engine drops includeSpellIDs and the bare HELPFUL token matches
		-- every buff they have. Nothing can narrow it back, so the group is budgeted to zero
		-- until they are assistable again.
		if not units:CanAssist(entry.Unit) then
			showHelpful = false
		end

		budgetScratch[auraFilters.GroupKey.CrowdControl] = options.ShowCC and maxIcons or 0
		budgetScratch[HELPFUL_GROUP_KEY] = showHelpful and maxIcons or 0

		-- The tracked set is editable at runtime, so re-publish it rather than assuming the
		-- filters handed over at creation are still current.
		entry.Display:SetCandidateFilters(HELPFUL_GROUP_KEY, GetHelpfulFilters())
	end

	anchoredIcons:ApplyEntryOptions(
		entry,
		anchor,
		options,
		iconSize,
		maxIcons,
		style,
		budgetScratch,
		testModeActive,
		options.ExcludePlayer,
		IsKickActive(entry, options),
		RenderEntry
	)
end

---@param options RaidFrameAurasInstanceOptions
local function ApplyOptions(options)
	for anchor, entry in pairs(watchers) do
		ApplyEntryOptions(entry, anchor, options)
	end
end

---@return RaidFrameAurasInstanceOptions?
function M:GetOptions()
	return db and GetOptions()
end

---@param value boolean
function M:SetPaused(value)
	paused = value
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

function M:EnsureWatchers()
	EnsureWatchers()
end

function M:Teardown()
	Teardown()
end

function M:EnsureFrames()
	EnsureFrames()
end

---@param options RaidFrameAurasInstanceOptions
function M:ApplyOptions(options)
	ApplyOptions(options)
end

function M:RefreshTestIcons()
	RefreshTestIcons()
end

---Blanks and hides every entry's kick/test container, for the test-mode handover.
function M:ResetAllContainers()
	anchoredIcons:ResetContainers(watchers)
end

---12.1 path: redraws the kick icons a test-mode reset wiped.
function M:RefreshKickIcons()
	for _, entry in pairs(watchers) do
		UpdateKickIcon(entry)
	end
end

function M:OnCufUpdateVisible(frame)
	OnCufUpdateVisible(frame)
end

function M:OnCufSetUnit(frame, unit)
	OnCufSetUnit(frame, unit)
end

function M:Init()
	db = mini:GetSavedVars()

	testDefensiveSpells = testSpellData.Defensive
	testCcSpells = testSpellData.CrowdControl
end

---@class RaidFrameAurasWatchEntry
---@field Container IconSlotContainer On 12.1 this only renders the kick icon and test icons.
---@field Watcher Watcher? Legacy path only (nil on 12.1).
---@field Display AuraContainerDisplay? 12.1 path only: CC/defensive auras render through this.
---@field KickTimer table? 12.1 path only: timer that clears the kick icon on expiry.
---@field Anchor table
---@field Unit string
---@field KickKey number

---@class RaidFrameAurasModuleOptions
---@field ShowDefensives boolean
---@field ShowImportant boolean 12.1 only: Blizzard-flagged important buffs.
---@field ShowCC boolean

