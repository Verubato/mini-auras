---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.UnitUtil
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
local sweep = addon.Core.Sweep
local testSpellData = addon.Core.TestSpells
local changeStamp = addon.Utils.ChangeStamp

addon.Modules.ImportantAuras = addon.Modules.ImportantAuras or {}

---@class ImportantAurasDisplay
local M = {}
addon.Modules.ImportantAuras.Display = M

-- CC and defensive auras render through an AuraContainer per anchor, one group per category, with
-- an IconSlotContainer alongside for the kick icon and test mode.
local paused = false
local testModeActive = false
-- Anchor frame -> the container and display drawn on it. Owned here: the module asks for
-- whole-set operations rather than reaching into it.
---@type table<table, ImportantAurasWatchEntry>
local watchers = {}
-- Background walker declaring the aura groups of displays as they are built. Urgent, because
-- these are on a unit frame the player is looking at.
local buildSweep = sweep:New(true)
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
-- only possible because the gate on spell-id filters is UnitCanAssist and this module tracks
-- assistable units. On an enemy-facing display the same swap would show every buff. It buys the
-- spells the game never flags, at the cost of showing nothing that is not explicitly listed.
--
-- With the category tokens gone both groups carry the same filter string, and the categories are
-- kept apart by which ids reach which group. They are two groups rather than one so each can take
-- its own colour, since the engine tints a whole group.
-- Read-only stand-in so the lookups below never have to nil-check.
local EMPTY_TABLE = {}
local DEFENSIVE_GROUP_KEY = "helpfuldef"
local IMPORTANT_GROUP_KEY = "helpfulimp"
local HELPFUL_FILTER = "HELPFUL"
-- An id nothing will ever have, for a tracked set that comes out empty. An empty includeSpellIDs
-- map reads as "no ids required", so the group would match every buff on the unit instead of none
-- of them.
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

-- The Masque group these icons are skinned under, and the public MiniCCModule frame tag.
local MASQUE_GROUP = "Important Auras"
-- The two options profiles, which are also the keys an anchor keeps a display under.
local DEFAULT_PROFILE = "Default"
local RAID_PROFILE = "Raid"
-- How many frames' worth of containers to have ready before a group turns up. A party is five,
-- which is the size a solo player is most likely to become. Past that the walker keeps up, since
-- a raid fills in over several seconds anyway.
local PREWARM_FRAMES = 5
-- What a spare tracks until a frame hands it a real token.
local SPARE_UNIT = "none"
-- The walker hands its callback the item that was queued. A spare build needs none, so this
-- stands in for one.
local PREWARM_ITEM = true

-- Rebuilt whenever the tracked set changes; handed straight to the engine, which keeps the
-- reference, so they are replaced rather than mutated in place. Keyed by group.
---@type table<string, table>
local helpfulFilters
-- What the current filters were built from, so a refresh that moved nothing reuses them. One
-- tracked set per module, so one stamp key covers it.
local FILTER_STAMP_KEY = "ImportantAurasFilters"
local filterStamp = changeStamp:New()
local filterSetScratch = {}
local helpfulFilterGeneration
-- Containers built before any frame has asked for one, so a group forming does not have to wait
-- out the walker for its icons. Held off screen until a frame takes one.
---@type ImportantAurasSpare[]
local spares = {}
-- The spare currently being finished, so its groups are declared one per turn like every other
-- build. Only ever one at a time: spares are the lowest priority work the addon does.
---@type ImportantAurasSpare?
local prewarmBuilding
local prewarmSweep = sweep:New()
-- Refilled per call, and only read for a frame to size a spare from.
local anchorScratch = {}

---The spell ids currently tracked, split by the group that draws them: the curated lists for the
---categories that are switched on, minus the spells the user switched off, plus anything they
---added by hand.
---
---The category toggles pick the lists rather than an icon budget each, because a curated id can
---belong to both categories: budgeting a group to zero would take those spells down with it.
---
---Rebuilt only when the toggles or the overrides move, since this runs per entry on every roster
---refresh and the curated walk is the same answer forty times over. helpfulFilterGeneration is
---what a caller compares to skip re-publishing tables the engine already holds.
---@param options ImportantAurasInstanceOptions
---@return table filtersByGroup Group key -> candidate filters.
local function GetHelpfulFilters(options)
	local overrides = db.Modules.ImportantAuras.Spells

	-- The inputs, not the output: the curated lists are static for the session, so the toggles
	-- and the override sets are everything that can move the answer. A profile switch replaces
	-- the tables wholesale and still compares by contents here.
	filterStamp:Begin(FILTER_STAMP_KEY)
	filterStamp:Add(options.ShowDefensives == true)
	filterStamp:Add(options.ShowImportant == true)
	filterStamp:AddSet(filterSetScratch, overrides and overrides.Disabled)
	filterStamp:AddSet(filterSetScratch, overrides and overrides.Enabled)
	filterStamp:AddSet(filterSetScratch, overrides and overrides.Custom)

	local generation = filterStamp:Commit()

	if generation == helpfulFilterGeneration then
		return helpfulFilters
	end

	helpfulFilterGeneration = generation

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
		-- when that happens, or the options list it twice, under its class and under Custom,
		-- with two checkboxes driving the same tracked state.
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
---@param options ImportantAurasInstanceOptions
---@param colors table<string, number[]> Category tints, keyed by group key.
---@return table[]
local function BuildGroups(maxIcons, options, colors)
	local filters = GetHelpfulFilters(options)

	return {
		auraFilters:GroupSpec("CrowdControl", maxIcons),
		-- The helpful side filters by the user-curated spell id lists rather than Blizzard's
		-- category tokens.
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

---Which options profile is in force. A key rather than the table itself, since a profile switch
---replaces the tables and the displays an anchor keeps have to outlive that.
---@return string
local function GetProfileKey()
	return instanceOptions:IsRaid() and RAID_PROFILE or DEFAULT_PROFILE
end

local function GetOptions()
	local m = db.Modules.ImportantAuras
	if not m then
		return nil
	end
	return m[GetProfileKey()]
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
	local module = db and db.Modules.ImportantAuras

	moduleUtil:FillColor(importantColor, module and module.ImportantColor, DEFAULT_IMPORTANT_COLOR)
	moduleUtil:FillColor(defensiveColor, module and module.DefensiveColor, DEFAULT_DEFENSIVE_COLOR)
end

---The tints the helpful groups take, keyed by group key. The CC group is never in there, since it
---takes the game's dispel type colours.
---@param options ImportantAurasInstanceOptions
---@return table<string, number[]> Shared, rewritten per call.
local function HelpfulColors(options)
	RefreshCategoryColors()

	local colored = options.Icons.ColorByDispelType == true

	helpfulColors[DEFENSIVE_GROUP_KEY] = colored and defensiveColor or nil
	helpfulColors[IMPORTANT_GROUP_KEY] = colored and importantColor or nil

	return helpfulColors
end

---One anchor's aura display, built to the look the given options ask for.
---
---Seeded with its style rather than left to the restyle on the refresh behind it: a unit's display
---is built the moment it turns up, and one built mid-arena can never be restyled.
---
---The groups are declared by the walker instead, a group per turn: a roster turning up builds one
---of these per unit at once, and each group costs a batch of buttons the engine allocates on the
---spot. Icons for a category appear when its group lands, within a second or two of the frames.
---@param unit string
---@param options ImportantAurasInstanceOptions
---@param size number
---@param spacing number
---@param maxIcons number
---@return AuraContainerDisplay
local function BuildDisplay(unit, options, size, spacing, maxIcons)
	return auraContainerDisplay:New(
		UIParent,
		unit,
		BuildGroups(maxIcons, options, HelpfulColors(options)),
		size,
		spacing,
		MASQUE_GROUP,
		{ Style = BuildStyle(options), MasqueGroup = MASQUE_GROUP, DeferGroups = true }
	)
end

---Whether a kick icon currently occupies the entry's container. With kicks switched off the
---display has no kick icon to chain past.
---@param entry ImportantAurasWatchEntry
---@param options ImportantAurasInstanceOptions
---@return boolean
local function IsKickActive(entry, options)
	return options.ShowKicks and kickTracker:GetKick(entry.Unit) ~= nil
end

---Positions the aura display on its anchor, chaining after the kick container while a kick icon
---is showing.
---@param entry ImportantAurasWatchEntry
---@param anchor table
---@param options ImportantAurasInstanceOptions
local function AnchorAuraDisplay(entry, anchor, options)
	anchoredIcons:AnchorAuraDisplay(entry, anchor, options, IsKickActive(entry, options))
end

---Renders the kick icon into the entry's IconSlotContainer (slot 1) and re-anchors the aura
---display around it.
---@param entry ImportantAurasWatchEntry
local function UpdateKickIcon(entry)
	if not entry or not entry.Container or paused or testModeActive then
		return
	end

	local options = GetOptions()
	if not options or not moduleUtil:IsModuleEnabled(moduleName.ImportantAuras) then
		return
	end

	local kickEntry = options.ShowKicks and kickTracker:GetKick(entry.Unit) or nil

	anchoredIcons:RenderKickIcon(entry, options, kickEntry, function()
		entry.KickTimer = nil
		UpdateKickIcon(entry)
	end)
end

---Budgets every group for the entry's current unit, which is a question about the unit rather
---than about the options.
---
---Assist: spell-id filters are gated on UnitCanAssist, so a unit that stops being assistable
---drops includeSpellIDs and the bare HELPFUL token then matches every buff they have. A duel
---flips the unit under the frame, and a mind control has Blizzard hand a friendly frame an enemy
---unit outright.
---
---Visible: outside the player's visible world the engine stops evaluating the filters correctly
---and both groups fill with unrelated auras, so a unit that far away shows nothing at all.
---
---Neither has an event of its own, which is why the unit state poller watches them.
---@param entry ImportantAurasWatchEntry
---@param options ImportantAurasInstanceOptions
---@return number helpful
---@return number crowdControl
local function ApplyUnitGates(entry, options)
	local maxIcons = tonumber(options.Icons.MaxIcons) or 1
	local visible = units:IsVisible(entry.Unit)
	local helpful = visible and (options.ShowDefensives or options.ShowImportant)
		and units:CanAssist(entry.Unit) and maxIcons or 0
	local crowdControl = visible and options.ShowCrowdControl and maxIcons or 0

	if entry.Display then
		-- Every switched-on category gets the whole budget, since aura counts cannot be read to
		-- split the slots between them, and a category switched off has an empty id set already.
		-- Urgent, because the unit a gate zeroes is outside the visible world and emits no aura
		-- events, so a budget flip parked for combat would keep showing the garbage until regen.
		entry.Display:SetMaxIcons(DEFENSIVE_GROUP_KEY, helpful, true)
		entry.Display:SetMaxIcons(IMPORTANT_GROUP_KEY, helpful, true)
		entry.Display:SetMaxIcons(auraFilters.GroupKey.CrowdControl, crowdControl, true)
	end

	return helpful, crowdControl
end

---One entry's next group, from the walker. The display is created with none of them: a roster
---appearing builds one display per unit in the same pass, and every group declared costs a batch
---of buttons there and then.
---@param entry ImportantAurasWatchEntry
---@return SweepVerdict?
local function DeclareNextGroup(entry)
	local display = entry.Display

	if not display then
		return
	end

	local options = GetOptions()

	-- Re-published rather than trusted from creation, since the walk runs over seconds and the
	-- tracked spell list can move while an entry whose anchor is out of sight is skipped by every
	-- refresh. Only when it actually moved, because an unguarded push bounces the container into a
	-- full reparse for every group after the first.
	if options then
		local filters = GetHelpfulFilters(options)

		if entry.FilterGeneration ~= helpfulFilterGeneration then
			display:SetCandidateFilters(DEFENSIVE_GROUP_KEY, filters[DEFENSIVE_GROUP_KEY])
			display:SetCandidateFilters(IMPORTANT_GROUP_KEY, filters[IMPORTANT_GROUP_KEY])
			entry.FilterGeneration = helpfulFilterGeneration
		end
	end

	if display:AddNextGroup() then
		return sweep.Verdict.Unfinished
	end
end

---What a spare would be built to now. Sized off a real frame where there is one, so a spare taken
---later needs no resize: a restyle is refused outright while auras are secret. Without any frames
---it takes the pixel size, and the refresh that hands it over corrects that.
---@param options ImportantAurasInstanceOptions
---@return number size
---@return number spacing
local function SpareGeometry(options)
	local sample = frames:GetAll(false, false, anchorScratch)[1]

	return moduleUtil:GetIconSize(options.Icons, sample, 32, 75), options.IconSpacing or 2
end

---Whether a waiting spare could be handed to a frame asking for this look. The budget has to match
---outright: the engine hands out a group's buttons from the count it was declared with, so a spare
---built for a smaller row can never grow into a bigger one.
---@param spare ImportantAurasSpare
---@param maxIcons number
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@return boolean
local function SpareFits(spare, maxIcons, size, spacing, style)
	return spare.MaxIcons == maxIcons and anchoredIcons:DisplayFitsLook(spare.Display, size, spacing, style)
end

---How many spares are still wanted: the target, less the frames already carrying a display and the
---spares already waiting. An entry counts because a frame holding a display is doing the job a
---spare was held for.
---@return number
local function SparesWanted()
	if not moduleUtil:IsModuleEnabled(moduleName.ImportantAuras) then
		return 0
	end

	local built = 0

	for anchor, entry in pairs(watchers) do
		-- The test-mode stand-ins keep their entries for the session, so counting them would let
		-- one options preview permanently zero the target and eat the warm containers.
		if entry.Display and not frames:IsTestFrame(anchor) then
			built = built + 1
		end
	end

	return PREWARM_FRAMES - built - #spares
end

---Throws away the spares no frame could be handed any more. While they sit on the list the target
---looks met and nothing replaces them, so inside a battleground, where the look moved and a restyle
---is refused, the pool would hold nothing usable for the whole match.
local function DropStaleSpares()
	local options = GetOptions()

	if not options then
		return
	end

	local maxIcons = tonumber(options.Icons.MaxIcons) or 1
	local size, spacing = SpareGeometry(options)
	local style = BuildStyle(options)

	-- The one the walker is part way through counts too: it was started at the old settings and
	-- would be banked at them.
	if prewarmBuilding and not SpareFits(prewarmBuilding, maxIcons, size, spacing, style) then
		prewarmBuilding = nil
	end

	for index = #spares, 1, -1 do
		local spare = spares[index]

		if not SpareFits(spare, maxIcons, size, spacing, style) then
			-- Nothing releases a display; it is simply never handed out. The engine cannot free a
			-- container or the buttons under it either way.
			spare.Display:Hide()
			spare.Container.Frame:Hide()
			table.remove(spares, index)
		end
	end
end

---A container and a display for no frame in particular, built to the current settings.
---@param options ImportantAurasInstanceOptions
---@return ImportantAurasSpare
local function BuildSpare(options)
	local maxIcons = tonumber(options.Icons.MaxIcons) or 1
	local size, spacing = SpareGeometry(options)
	local container = iconSlotContainer:New(UIParent, maxIcons, size, spacing, MASQUE_GROUP, nil, MASQUE_GROUP)

	-- Nothing is drawn on it until a frame takes it, and the kick icon is what shows it again.
	container.Frame:Hide()

	return {
		Container = container,
		Display = BuildDisplay(SPARE_UNIT, options, size, spacing, maxIcons),
		MaxIcons = maxIcons,
		-- What BuildGroups resolved into the specs, so the frame that takes this knows whether the
		-- tracked set has moved since.
		FilterGeneration = helpfulFilterGeneration,
	}
end

---A spare for the frame that has just asked for one, or nil when none is waiting or none matches.
---Both halves are already parented to the screen, which is where a taken one lives too, so the
---token is all that changes.
---
---A spare bakes its size, its style and its groups' budgets in when it is built, and a restyle is
---refused outright while auras are secret, so one handed over needing a resize would keep the
---wrong look for the rest of an arena.
---@param unit string
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@param maxIcons number
---@return ImportantAurasSpare?
local function TakeSpare(unit, size, spacing, style, maxIcons)
	for index = #spares, 1, -1 do
		local spare = spares[index]

		if SpareFits(spare, maxIcons, size, spacing, style) then
			table.remove(spares, index)
			spare.Display:SetUnit(unit)

			return spare
		end
	end

	return nil
end

---A group per turn, and straight on to the next spare once one is banked, so the whole warm-up
---rides on this single queued item. Everything is re-read at fire time: the walk runs over
---seconds, in which the module can be switched off and the frames it was being held for can turn
---up on their own.
---@return SweepVerdict?
local function PrewarmNext()
	if prewarmBuilding then
		if prewarmBuilding.Display:AddNextGroup() and prewarmBuilding.Display:HasPendingGroups() then
			return sweep.Verdict.Unfinished
		end

		spares[#spares + 1] = prewarmBuilding
		prewarmBuilding = nil
	end

	local options = GetOptions()

	if not options or SparesWanted() <= 0 then
		return
	end

	prewarmBuilding = BuildSpare(options)

	return sweep.Verdict.Unfinished
end

---@param anchor table
---@param unit string?
local function EnsureWatcher(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	-- Blizzard briefly shows every frame it pre-creates, pointed at "player", while it lays them
	-- out at login: all forty-five look visible and occupied, and only the timing tells them apart
	-- from the frame the player has. The refresh after the screen builds what this skips.
	if addon:IsLoadingScreenUp() then
		return nil
	end

	-- Nobody on the token, nothing to watch. Blizzard builds its party and raid frames for a full
	-- group and calls SetUnit on every one of them at login, so a solo player's frames alone are
	-- dozens of containers for units that are not there. A unit turning up re-runs this hook, and
	-- the roster refresh walks the anchors again, so one that fills later still gets its display.
	-- Test mode is exempt: its stand-in frames name units the player does not have.
	if not testModeActive and not units:Exists(unit) then
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
		local spare = TakeSpare(unit, size, spacing, BuildStyle(options), maxIcons)
		local container = spare and spare.Container
			or iconSlotContainer:New(UIParent, maxIcons, size, spacing, MASQUE_GROUP, nil, MASQUE_GROUP)

		entry = {
			Container = container,
			Anchor = anchor,
			Unit = unit,
			KickKey = 0,
			-- Recorded so the flip a battleground brings can put the right display back.
			DisplayProfile = GetProfileKey(),
		}
		watchers[anchor] = entry

		-- The standard categories, partitioned by filter negation so an aura only ever lands in
		-- one group.
		entry.Display = spare and spare.Display or BuildDisplay(unit, options, size, spacing, maxIcons)

		-- Whatever it still owes goes on the urgent lane, ahead of the spares: a frame is holding
		-- it now. A spare may have been taken part way through its own build.
		if entry.Display:HasPendingGroups() then
			buildSweep:Append(entry, DeclareNextGroup)
		end

		-- Whichever tracked set went into the groups, so the next options pass re-publishes only
		-- when it has actually moved since.
		entry.FilterGeneration = spare and spare.FilterGeneration or helpfulFilterGeneration

		kickTracker:Watch(unit)
		entry.KickKey = kickTracker:Subscribe(unit, function()
			UpdateKickIcon(entry)
		end)

		-- The groups above are built with the full budget; ask the per-unit gates right away, or
		-- a display born for a unit already outside the visible world shows unfiltered auras
		-- until the next refresh.
		ApplyUnitGates(entry, options)
	else
		if entry.Unit ~= unit then
			-- The container tracks the new unit itself, so only the token changes.
			entry.Display:SetUnit(unit)

			kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				UpdateKickIcon(entry)
			end)

			entry.Unit = unit

			-- The gates are per unit, so a re-point can change the answer even though nothing
			-- about the options moved. The category toggles are left alone, since a re-point must
			-- not reset them from defaults.
			ApplyUnitGates(entry, options)

			entry.Container:ResetAllSlots()

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
		moduleUtil:SetTestLabel(entry.Container.Frame, L["Important Auras"])
	end

	return entry
end

---Puts the entry on the display it keeps for the profile now in force, and wires up what a swap
---leaves owing.
---@param entry ImportantAurasWatchEntry
---@param options ImportantAurasInstanceOptions
---@param size number
---@param spacing number
---@param style AuraDisplayStyle
---@param maxIcons number
local function EnsureProfileDisplay(entry, options, size, spacing, style, maxIcons)
	-- The preview moves the profile as well, and it draws through the container with the display
	-- hidden, so a display built for it here is one nobody can ever see.
	if testModeActive then
		return
	end

	local profile = GetProfileKey()

	-- Asked before the builder below is made, so an ordinary refresh allocates nothing.
	if entry.DisplayProfile == profile then
		return
	end

	local swapped = anchoredIcons:EnsureDisplayProfile(entry, profile, size, spacing, style, function()
		return BuildDisplay(entry.Unit, options, size, spacing, maxIcons)
	end)

	if not swapped then
		return
	end

	-- The display taken back carries whichever tracked set it was parked with.
	entry.FilterGeneration = nil

	if entry.Display:HasPendingGroups() then
		buildSweep:Append(entry, DeclareNextGroup)
	end
end

---@param entry ImportantAurasWatchEntry
---@param anchor table
---@param options ImportantAurasInstanceOptions
local function ApplyEntryOptions(entry, anchor, options)
	local iconSize = moduleUtil:GetIconSize(options.Icons, anchor, 32, 75)
	local maxIcons = tonumber(options.Icons.MaxIcons) or 1
	local style

	if entry.Display then
		style = BuildStyle(options)

		EnsureProfileDisplay(entry, options, iconSize, options.IconSpacing or 2, style, maxIcons)

		-- ShowCrowdControl maps to a zero icon budget for its group. The helpful side cannot: a curated
		-- spell can sit in either category, so the toggles select the tracked spell ids instead
		-- and only a display with neither category on goes to zero. Both sides also answer to the
		-- per-unit gates, which ApplyUnitGates owns.
		local helpful, crowdControl = ApplyUnitGates(entry, options)

		budgetScratch[auraFilters.GroupKey.CrowdControl] = crowdControl
		budgetScratch[DEFENSIVE_GROUP_KEY] = helpful
		budgetScratch[IMPORTANT_GROUP_KEY] = helpful

		-- The tracked set is editable at runtime, so re-publish it rather than assuming the
		-- filters handed over at creation are still current. Only when it actually moved: an
		-- unguarded push bounces the container into a full engine re-parse, and this runs for
		-- every entry on every roster refresh.
		local filters = GetHelpfulFilters(options)

		-- Pending groups are pushed at every pass, generation or no: a display built before the
		-- walker reaches it holds the filters it was built with, and those can be seconds stale by
		-- the time its groups are declared.
		if entry.FilterGeneration ~= helpfulFilterGeneration or entry.Display:HasPendingGroups() then
			entry.Display:SetCandidateFilters(DEFENSIVE_GROUP_KEY, filters[DEFENSIVE_GROUP_KEY])
			entry.Display:SetCandidateFilters(IMPORTANT_GROUP_KEY, filters[IMPORTANT_GROUP_KEY])
			entry.FilterGeneration = helpfulFilterGeneration
		end

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

---Sets how many icons one unit's groups may show, from whether it is inside the player's visible
---world and whether it can be assisted, and says whether either number moved. UNIT_FACTION fires
---for PvP flagging too, so its caller does the rest of its work only when this returns true.
---@param unit string
---@return boolean changed
function M:ReapplyUnitGates(unit)
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

---@return ImportantAurasInstanceOptions?
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

---Tops the spares up, if the walker is not already at it. Cheap to call from any refresh: the one
---queued item walks the whole warm-up, so a refresh landing part way through adds nothing.
function M:QueuePrewarm()
	DropStaleSpares()

	if prewarmSweep:HasWork() or SparesWanted() <= 0 then
		return
	end

	prewarmSweep:Append(PREWARM_ITEM, PrewarmNext)
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

---@param options ImportantAurasInstanceOptions
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

	local ccCount = options.ShowCrowdControl and #testCcSpells or 0
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

	local enabled = moduleUtil:IsModuleEnabled(moduleName.ImportantAuras)

	if anchoredIcons:RestyleIfStale(entry, frame, enabled, ApplyEntryOptions, options) then
		return
	end

	-- A torn-down entry keeps the row it last drew, so showing it again puts those icons back.
	if not enabled then
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

	-- The hooks outlive the module being switched off.
	if not moduleUtil:IsModuleEnabled(moduleName.ImportantAuras) then
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

---@class ImportantAurasWatchEntry
---@field Container IconSlotContainer Renders the kick icon and the test icons only.
---@field Display AuraContainerDisplay? CC/defensive auras render through this.
---@field KickTimer table? Timer that clears the kick icon on expiry.
---@field Anchor table
---@field Unit string
---@field KickKey number
---@field FilterGeneration number? The helpful filters the display already carries; matches
---helpfulFilterGeneration once the current tracked set has reached its groups.
---@field DisplayProfile string? Which options profile Display was built to.
---@field Displays table<string, AuraContainerDisplay>? The displays this anchor keeps for the
---profiles it is not currently wearing.

---@class ImportantAurasSpare
---@field Container IconSlotContainer
---@field Display AuraContainerDisplay
---@field MaxIcons number The icon budget its groups were born with, which nothing can change.
---@field FilterGeneration number? The tracked set its groups were built from.

---@class ImportantAurasModuleOptions
---@field ShowDefensives boolean Curated defensive and healer throughput cooldowns.
---@field ShowImportant boolean Curated important buffs and offensive cooldowns.
---@field ShowCrowdControl boolean

