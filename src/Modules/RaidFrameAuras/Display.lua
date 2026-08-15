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

-- CC + defensive auras render through an AuraContainer per anchor (one group per category); the
-- IconSlotContainer is kept for the kick icon and test mode. There is no dynamic slot split
-- between categories (aura counts are unreadable), so each enabled category gets the full
-- MaxIcons budget.
local paused = false
local testModeActive = false
-- Anchor frame -> the container and display drawn on it. Owned here: the module asks for
-- whole-set operations rather than reaching into it.
---@type table<table, RaidFrameAurasWatchEntry>
local watchers = {}
---@type TestSpell[]
local testDefensiveSpells = {}
---@type TestSpell[]
local testImportantSpells = {}
---@type TestSpell[]
local testCcSpells = {}
---@type Db
local db
-- Reused per-group icon budget map handed to ApplyEntryOptions.
local budgetScratch = {}
-- Reused settings handed to ApplyEntryOptions, refilled per entry.
---@type EntrySettings
local settingsScratch = {}

-- Helpful auras are filtered by spell id alone rather than by Blizzard's category flags. That is
-- only possible here because the gate on spell-id filters is UnitCanAssist, and this module
-- tracks assistable units - the same swap on an enemy-facing display would silently show every
-- buff. It buys the ability to track spells the game never flags, at the cost of showing nothing
-- that is not explicitly listed.
--
-- Not the usual big/external/important split: with the category tokens gone both groups carry the
-- same filter string, and the categories are kept apart by which ids reach which group. They are
-- two groups rather than one only so each can take its own colour - the engine tints a whole
-- group, and an aura's own id is unreadable here.
-- Read-only stand-in so the lookups below never have to nil-check.
local EMPTY_TABLE = {}
local DEFENSIVE_GROUP_KEY = "helpfuldef"
local IMPORTANT_GROUP_KEY = "helpfulimp"
local HELPFUL_FILTER = "HELPFUL"
-- An id nothing will ever have, for a tracked set that comes out empty. An EMPTY includeSpellIDs
-- map reads as "no ids required", so the group would match every buff on the unit instead of none
-- of them - see the same trap in Modules/CustomAuras/Display.
local NEVER_MATCHED_SPELL_ID = 2147483647
-- The curated lists, each tied to the toggle that owns it and the group it lands in. The unflagged
-- halves are only reachable at all because the groups filter by id.
local HELPFUL_SOURCES = {
	{ Toggle = "ShowDefensives", Group = DEFENSIVE_GROUP_KEY, Ids = auraCategoryIds.Defensive },
	{ Toggle = "ShowDefensives", Group = DEFENSIVE_GROUP_KEY, Ids = auraCategoryIds.UnflaggedDefensive },
	{ Toggle = "ShowImportant", Group = IMPORTANT_GROUP_KEY, Ids = auraCategoryIds.Important },
	{ Toggle = "ShowImportant", Group = IMPORTANT_GROUP_KEY, Ids = auraCategoryIds.UnflaggedImportant },
}

-- Fallback category tints, for a profile saved before the colours were configurable.
local DEFAULT_IMPORTANT_COLOR = { R = 1, G = 0.2, B = 0.2 }
local DEFAULT_DEFENSIVE_COLOR = { R = 0.2, G = 1, B = 0.2 }
-- The configured tints, refilled rather than reallocated. Both shapes are needed: the aura groups
-- read [1..3], the IconSlotContainer test icons read r/g/b.
local importantColor = { 1, 0.2, 0.2, r = 1, g = 0.2, b = 0.2, a = 1 }
local defensiveColor = { 0.2, 1, 0.2, r = 0.2, g = 1, b = 0.2, a = 1 }
-- Group key -> tint, or empty while the colours are switched off. The key list is separate because
-- a group going back to the plain glow has no entry in the map.
local helpfulColors = {}
local HELPFUL_GROUP_KEYS = { DEFENSIVE_GROUP_KEY, IMPORTANT_GROUP_KEY }

-- Rebuilt whenever the tracked set changes; handed straight to the engine, which keeps the
-- reference, so they are replaced rather than mutated in place. Keyed by group.
local helpfulFilters = {
	[DEFENSIVE_GROUP_KEY] = { includeSpellIDs = {} },
	[IMPORTANT_GROUP_KEY] = { includeSpellIDs = {} },
}

---The spell ids currently tracked, split by the group that draws them: the curated lists for the
---categories that are switched on, minus the spells the user switched off, plus anything they
---added by hand.
---
---The category toggles pick the lists rather than an icon budget each, because a curated id can
---belong to both categories: budgeting a group to zero would take those spells down with it.
---@param options RaidFrameAurasInstanceOptions
---@return table filtersByGroup Group key -> candidate filters.
local function GetHelpfulFilters(options)
	local overrides = db.Modules.RaidFrameAurasModule.Spells
	local disabled = (overrides and overrides.Disabled) or EMPTY_TABLE
	local idsByGroup = {
		[DEFENSIVE_GROUP_KEY] = {},
		[IMPORTANT_GROUP_KEY] = {},
	}
	-- Which group already claimed an id, so a spell listed as both defensive and important is
	-- drawn once, by the first list that wanted it. Same partition the standard filter strings
	-- make with their negations, in the one shape available here.
	local claimed = {}

	local curated = {}
	local enabled = (overrides and overrides.Enabled) or EMPTY_TABLE

	for _, source in ipairs(HELPFUL_SOURCES) do
		local shown = options[source.Toggle]

		for spellId in pairs(source.Ids) do
			-- Every curated id counts as curated whatever the toggles say: a hand-added copy of
			-- one still has to be dropped below while its category is switched off.
			curated[spellId] = true
			-- Off-by-default spells need an explicit opt-in; the rest are on unless switched off.
			local tracked = shown
				and not claimed[spellId]
				and not disabled[spellId]
				and (not auraCategoryIds.DefaultOff[spellId] or enabled[spellId])

			if tracked then
				claimed[spellId] = true
				idsByGroup[source.Group][spellId] = true
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
			-- Hand-added spells belong to neither category, so they ride with the importants and
			-- take that colour.
			idsByGroup[IMPORTANT_GROUP_KEY][spellId] = true
		end
	end

	helpfulFilters = {}

	for group, ids in pairs(idsByGroup) do
		-- The category switched off, or every listed spell switched off one by one.
		if next(ids) == nil then
			ids[NEVER_MATCHED_SPELL_ID] = true
		end

		helpfulFilters[group] = { includeSpellIDs = ids }
	end

	return helpfulFilters
end

---@param maxIcons number
---@param options RaidFrameAurasInstanceOptions
---@param colors table<string, number[]> Category tints, keyed by group key.
---@return table[]
local function BuildGroups(maxIcons, options, colors)
	local filters = GetHelpfulFilters(options)

	return {
		auraFilters:GroupSpec("CrowdControl", maxIcons),
		-- Not standard categories: the helpful side filters by the user-curated spell id lists
		-- rather than Blizzard's category tokens (see the header comment above).
		{
			Key = DEFENSIVE_GROUP_KEY,
			FilterString = HELPFUL_FILTER,
			CandidateFilters = filters[DEFENSIVE_GROUP_KEY],
			MaxIcons = maxIcons,

			GlowColor = colors[DEFENSIVE_GROUP_KEY],
		},
		{
			Key = IMPORTANT_GROUP_KEY,
			FilterString = HELPFUL_FILTER,
			CandidateFilters = filters[IMPORTANT_GROUP_KEY],
			MaxIcons = maxIcons,

			GlowColor = colors[IMPORTANT_GROUP_KEY],
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

	-- Only the CC group goes untinted here, and most CC is physical: without this a stun gets the
	-- tinted glow but no ring, which reads as the border being broken. The tinted helpful groups
	-- are unaffected, they draw their ring off the group colour.
	style.BorderWithoutDispelType = true
	style.ShowTooltips = entryOptions.ShowTooltips ~= false

	return style
end

---Refills the category tints from the module options. The test icons read these tables directly.
local function RefreshCategoryColors()
	local module = db and db.Modules.RaidFrameAurasModule

	moduleUtil:FillColor(importantColor, module and module.ImportantColor, DEFAULT_IMPORTANT_COLOR)
	moduleUtil:FillColor(defensiveColor, module and module.DefensiveColor, DEFAULT_DEFENSIVE_COLOR)
end

---The tints the helpful groups take, keyed by group key. The CC group is never in there: it takes
---the game's dispel type colours, which is all the toggle meant before there was anything to pick.
---@param options RaidFrameAurasInstanceOptions
---@return table<string, number[]> Shared, rewritten per call.
local function HelpfulColors(options)
	RefreshCategoryColors()

	local colored = options.Icons.ColorByDispelType == true

	helpfulColors[DEFENSIVE_GROUP_KEY] = colored and defensiveColor or nil
	helpfulColors[IMPORTANT_GROUP_KEY] = colored and importantColor or nil

	return helpfulColors
end

---Whether a kick icon currently occupies the entry's container. With kicks switched off the
---display has no kick icon to chain past.
---@param entry RaidFrameAurasWatchEntry
---@param options RaidFrameAurasInstanceOptions
---@return boolean
local function IsKickActive(entry, options)
	return options.ShowKicks and kickTracker:GetKick(entry.Unit) ~= nil
end

---Positions the aura display on its anchor, chaining after the kick container while a kick icon
---is showing.
---@param entry RaidFrameAurasWatchEntry
---@param anchor table
---@param options RaidFrameAurasInstanceOptions
local function AnchorAuraDisplay(entry, anchor, options)
	anchoredIcons:AnchorAuraDisplay(entry, anchor, options, IsKickActive(entry, options))
end

---Renders the kick icon into the entry's IconSlotContainer (slot 1) and re-anchors the aura
---display around it.
---@param entry RaidFrameAurasWatchEntry
local function UpdateKickIcon(entry)
	if not entry or not entry.Container or paused or testModeActive then
		return
	end

	local options = GetOptions()
	if not options or not moduleUtil:IsModuleEnabled(moduleName.RaidFrameAuras) then
		return
	end

	local kickEntry = options.ShowKicks and kickTracker:GetKick(entry.Unit) or nil

	anchoredIcons:RenderKickIcon(entry, options, kickEntry, function()
		entry.KickTimer = nil
		UpdateKickIcon(entry)
	end)
end

---Budgets every group for the entry's CURRENT unit, which is a question about the unit rather
---than about the options.
---
---Assist: spell-id filters are gated on UnitCanAssist, so a unit that stops being assistable
---drops includeSpellIDs and the bare HELPFUL token then matches every buff they have. Two ways
---in - a duel flips the unit under the frame, and a mind control has Blizzard hand a FRIENDLY
---frame an enemy unit outright.
---
---Visible: outside the player's visible world the engine stops evaluating the filters correctly
---and BOTH groups fill with unrelated auras, so a unit that far away shows nothing at all.
---
---Neither has an event of its own, which is why the unit state poller watches them.
---@param entry RaidFrameAurasWatchEntry
---@param options RaidFrameAurasInstanceOptions
---@return number helpful
---@return number crowdControl
local function ApplyUnitGates(entry, options)
	local maxIcons = tonumber(options.Icons.MaxIcons) or 1
	local visible = units:IsVisible(entry.Unit)
	local helpful = visible and (options.ShowDefensives or options.ShowImportant)
		and units:CanAssist(entry.Unit) and maxIcons or 0
	local crowdControl = visible and options.ShowCC and maxIcons or 0

	if entry.Display then
		-- Both helpful groups take the same budget: a category switched off has an empty id set
		-- already, so budgeting them apart would say the same thing twice.
		-- Urgent: the unit a gate zeroes is outside the visible world and emits no aura events,
		-- so a budget flip parked for combat would keep showing the garbage until regen.
		entry.Display:SetMaxIcons(DEFENSIVE_GROUP_KEY, helpful, true)
		entry.Display:SetMaxIcons(IMPORTANT_GROUP_KEY, helpful, true)
		entry.Display:SetMaxIcons(auraFilters.GroupKey.CrowdControl, crowdControl, true)
	end

	return helpful, crowdControl
end

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

		-- The standard categories, partitioned by filter negation so an aura only ever lands in
		-- one group (see Core/AuraFilters).
		entry.Display = auraContainerDisplay:New(
			UIParent,
			unit,
			BuildGroups(maxIcons, options, HelpfulColors(options)),
			size,
			spacing,
			"Friendly Indicators",
			-- Seeded rather than left to the restyle below: a unit's display is built the
			-- moment it turns up, and one built mid-arena can never be restyled.
			{ Style = BuildStyle(options), MasqueGroup = "Friendly Indicators" }
		)

		kickTracker:Watch(unit)
		entry.KickKey = kickTracker:Subscribe(unit, function()
			UpdateKickIcon(entry)
		end)

		-- The groups above are built with the full budget; ask the per-unit gates right away, or
		-- a display born for a unit already outside the visible world shows unfiltered auras
		-- until the next refresh.
		ApplyUnitGates(entry, options)
	else
		-- Check if unit has changed
		if entry.Unit ~= unit then
			-- The container tracks the new unit itself; only the unit token changes.
			entry.Display:SetUnit(unit)

			kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				UpdateKickIcon(entry)
			end)

			entry.Unit = unit

			-- The gates are per unit, so a re-point can change the answer even though nothing
			-- about the options moved. The category toggles are deliberately NOT re-read here
			-- (a re-point must not reset them from defaults); only the gates are re-asked.
			ApplyUnitGates(entry, options)

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()

			-- Force immediate refresh for the new unit
			UpdateKickIcon(entry)
		end
	end

	UpdateKickIcon(entry)
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

---@param entry RaidFrameAurasWatchEntry
---@param anchor table
---@param options RaidFrameAurasInstanceOptions
local function ApplyEntryOptions(entry, anchor, options)
	local iconSize = moduleUtil:GetIconSize(options.Icons, anchor, 32, 75)
	local maxIcons = tonumber(options.Icons.MaxIcons) or 1
	local style

	if entry.Display then
		style = BuildStyle(options)

		-- ShowCC maps to a zero icon budget for its group. The helpful side cannot: a curated
		-- spell can sit in either category, so the toggles select the tracked spell ids instead
		-- and only a display with neither category on goes to zero. Both sides also answer to the
		-- per-unit gates, which ApplyUnitGates owns.
		local helpful, crowdControl = ApplyUnitGates(entry, options)

		budgetScratch[auraFilters.GroupKey.CrowdControl] = crowdControl
		budgetScratch[DEFENSIVE_GROUP_KEY] = helpful
		budgetScratch[IMPORTANT_GROUP_KEY] = helpful

		-- The tracked set is editable at runtime, so re-publish it rather than assuming the
		-- filters handed over at creation are still current.
		local filters = GetHelpfulFilters(options)
		entry.Display:SetCandidateFilters(DEFENSIVE_GROUP_KEY, filters[DEFENSIVE_GROUP_KEY])
		entry.Display:SetCandidateFilters(IMPORTANT_GROUP_KEY, filters[IMPORTANT_GROUP_KEY])

		entry.Display:SetGroupGlowColors(HELPFUL_GROUP_KEYS, HelpfulColors(options))
	end

	settingsScratch.IconSize = iconSize
	settingsScratch.SlotCount = maxIcons
	settingsScratch.Style = style
	settingsScratch.Budgets = budgetScratch
	settingsScratch.TestModeActive = testModeActive
	settingsScratch.ExcludePlayer = options.ExcludePlayer
	settingsScratch.KickActive = IsKickActive(entry, options)
	settingsScratch.Render = UpdateKickIcon

	anchoredIcons:ApplyEntryOptions(entry, anchor, options, settingsScratch)
end

---Re-asks the per-unit gates for one unit, and says whether either answer moved. UNIT_FACTION
---fires for PvP flagging as much as for anything that matters here, so the module only does real
---work when this returns true.
---@param unit string
---@return boolean changed
function M:OnUnitFactionChanged(unit)
	local options = GetOptions()

	if not options then
		return false
	end

	local changed = false

	for _, entry in pairs(watchers) do
		if entry.Unit == unit and entry.Display then
			-- Either helpful group answers for both; they always carry the same budget.
			local wasHelpful = entry.Display:GetMaxIcons(DEFENSIVE_GROUP_KEY)
			local wasCc = entry.Display:GetMaxIcons(auraFilters.GroupKey.CrowdControl)
			local helpful, crowdControl = ApplyUnitGates(entry, options)

			if helpful ~= wasHelpful or crowdControl ~= wasCc then
				changed = true
			end
		end
	end

	return changed
end

---Every unit the module is currently watching. The unit state poller only scans tokens it has been
---given a baseline for, so the module hands it these: a party member who turns hostile mid-duel
---is what drops the spell-id filter, and nothing else announces that.
---@param out string[] Filled in place and returned, so the caller can keep one table.
---@return string[]
function M:CollectWatchedUnits(out)
	wipe(out)

	for _, entry in pairs(watchers) do
		if entry.Unit then
			out[#out + 1] = entry.Unit
		end
	end

	return out
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
	frames:ForEachAnchor(true, testModeActive, EnsureWatcher)
end

function M:Teardown()
	for _, entry in pairs(watchers) do
		anchoredIcons:TeardownEntry(entry)
	end
end

-- Wakes every entry's display back up, then discovers any unit frames that have appeared since
-- the last refresh.
function M:EnsureFrames()
	for _, entry in pairs(watchers) do
		if entry.Display then
			entry.Display:SetEnabled(true)
		end
	end

	M:EnsureWatchers()
end

---@param options RaidFrameAurasInstanceOptions
function M:ApplyOptions(options)
	for anchor, entry in pairs(watchers) do
		anchoredIcons:ApplyOrHideEntry(entry, anchor, ApplyEntryOptions, options)
	end
end

function M:RefreshTestIcons()
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
	local importantCount = options.ShowImportant and #testImportantSpells or 0
	local showKicks = options.ShowKicks
	local colors = HelpfulColors(options)

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
		local ccSlots, defensiveSlots, importantSlots =
			slotDistribution.Calculate(remainingSlots, ccCount, defensiveCount, importantCount)

		slotIndex = testSpellData:FillContainer(container, testCcSpells, slotIndex, {
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			ColorByDispelType = colorByDispelType,
			-- The live buttons draw border and glow together, so the preview does too.
			Border = true,
			FontScale = db.FontScale,
			ShowTooltips = showTooltips,
			Count = ccSlots,
		})

		slotIndex = testSpellData:FillContainer(container, testDefensiveSpells, slotIndex, {
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			Color = colors[DEFENSIVE_GROUP_KEY],
			Border = true,
			FontScale = db.FontScale,
			ShowTooltips = showTooltips,
			Count = defensiveSlots,
		})

		slotIndex = testSpellData:FillContainer(container, testImportantSpells, slotIndex, {
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			Color = colors[IMPORTANT_GROUP_KEY],
			Border = true,
			FontScale = db.FontScale,
			ShowTooltips = showTooltips,
			Count = importantSlots,
		})

		for i = slotIndex, container.Count do
			container:SetSlotUnused(i)
		end

		anchoredIcons:AnchorContainer(container, entry.Anchor, options)
		frames:ShowHideFrame(container.Frame, entry.Anchor, true, options.ExcludePlayer)
	end
end

---Blanks and hides every entry's kick/test container, for the test-mode handover.
function M:ResetAllContainers()
	anchoredIcons:ResetContainers(watchers)
end

---Redraws the kick icons a test-mode reset wiped.
function M:RefreshKickIcons()
	for _, entry in pairs(watchers) do
		UpdateKickIcon(entry)
	end
end

function M:OnCufUpdateVisible(frame)
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

	local enabled = moduleUtil:IsModuleEnabled(moduleName.RaidFrameAuras)

	if anchoredIcons:RestyleIfStale(entry, frame, enabled, ApplyEntryOptions, options) then
		return
	end

	-- The aura icons live in entry.Display, not the kick/test container, so it has to follow
	-- the unit frame's visibility too.
	if entry.Display then
		frames:ShowHideDisplay(entry.Display, frame, options.ExcludePlayer)
	end

	frames:ShowHideFrame(entry.Container.Frame, frame, false, options.ExcludePlayer)
end

function M:OnCufSetUnit(frame, unit)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	if not unit then
		return
	end

	EnsureWatcher(frame, unit)
end

function M:Init()
	db = mini:GetSavedVars()

	testDefensiveSpells = testSpellData.Defensive
	testImportantSpells = testSpellData.Important
	testCcSpells = testSpellData.CrowdControl
end

---@class RaidFrameAurasWatchEntry
---@field Container IconSlotContainer Renders the kick icon and the test icons only.
---@field Display AuraContainerDisplay? CC/defensive auras render through this.
---@field KickTimer table? Timer that clears the kick icon on expiry.
---@field Anchor table
---@field Unit string
---@field KickKey number

---@class RaidFrameAurasModuleOptions
---@field ShowDefensives boolean Curated defensive and healer throughput cooldowns.
---@field ShowImportant boolean Curated important buffs and offensive cooldowns.
---@field ShowCC boolean

