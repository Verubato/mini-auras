-- What the raid frame aura display actually tracks. The helpful categories carry the same filter
-- string and are told apart only by the spell ids reaching each group, so their toggles have to
-- pick those ids. The bug this guards is Show Important and Show Defensives acting as a single
-- on/off switch, leaving both categories on screen until the user cleared them both.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local DEFENSIVE_GROUP_KEY = "helpfuldef"
local IMPORTANT_GROUP_KEY = "helpfulimp"

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("ImportantAuras", true)

env.addUnitFrame("party1", "CUF_Filters")

env.loadModule("src/Modules/ImportantAuras/Display.lua")
env.loadModule("src/Modules/ImportantAuras/Module.lua")

local module = env.addon.Modules.ImportantAurasModule
local categoryIds = env.addon.Core.AuraCategoryIds
local options = db.Modules.ImportantAuras.Default
local spells = db.Modules.ImportantAuras.Spells

module:Init()

---One spell out of a curated list, picked by id so the assertions below survive a regeneration
---of the generated data. Default-off spells are skipped: they are untracked until asked for.
---@param list table<number, boolean>
---@return number
local function SampleId(list)
	local lowest

	for spellId in pairs(list) do
		if not categoryIds.DefaultOff[spellId] and (not lowest or spellId < lowest) then
			lowest = spellId
		end
	end

	return assert(lowest, "curated list has no default-tracked spell")
end

local IMPORTANT = SampleId(categoryIds.Important)
local UNFLAGGED_IMPORTANT = SampleId(categoryIds.UnflaggedImportant)
local DEFENSIVE = SampleId(categoryIds.Defensive)
local UNFLAGGED_DEFENSIVE = SampleId(categoryIds.UnflaggedDefensive)

---The spell ids one helpful group is currently filtering on, as published to the engine.
---@param groupKey string
---@return table<number, boolean>
local function GroupIds(groupKey)
	module:Refresh()
	-- The groups are declared by the background walker, a group per turn, so a whole roster
	-- turning up does not build them all in one frame.
	require("AuraContainerMock").tickAll(40)

	local containers = env.containersForUnit("party1")
	assert(#containers > 0, "no aura container for party1")

	local group = assert(containers[1]._groups[groupKey], "no " .. groupKey .. " group")
	local filters = assert(group.candidateFilters, groupKey .. " published no filters")

	return assert(filters.includeSpellIDs, groupKey .. " must filter by spell id")
end

---Both helpful groups' ids together, for the assertions that only ask whether a spell is tracked
---at all rather than which colour it draws in.
---@return table<number, boolean>
local function TrackedIds()
	local ids = {}

	for _, groupKey in ipairs({ DEFENSIVE_GROUP_KEY, IMPORTANT_GROUP_KEY }) do
		for spellId in pairs(GroupIds(groupKey)) do
			ids[spellId] = true
		end
	end

	return ids
end

fw.describe("ImportantAuras - the tracked spell ids", function()
	fw.before_each(function()
		options.ShowCrowdControl = false
		options.ShowKicks = false
		options.ShowDefensives = true
		options.ShowImportant = true
		wipe(spells.Disabled)
		wipe(spells.Custom)
		wipe(spells.Enabled)
	end)

	fw.it("tracks both categories while both toggles are on", function()
		local ids = TrackedIds()

		assert(ids[IMPORTANT], "important")
		assert(ids[UNFLAGGED_IMPORTANT], "important, unflagged by the game")
		assert(ids[DEFENSIVE], "defensive")
		assert(ids[UNFLAGGED_DEFENSIVE], "defensive, unflagged by the game")
	end)

	fw.it("drops the important ids when Show Important goes off", function()
		options.ShowImportant = false

		local ids = TrackedIds()

		assert(not ids[IMPORTANT], "the category is gone")
		assert(not ids[UNFLAGGED_IMPORTANT], "including the spells the game does not flag")
		assert(ids[DEFENSIVE], "the other category is untouched")
	end)

	fw.it("drops the defensive ids when Show Defensives goes off", function()
		options.ShowDefensives = false

		local ids = TrackedIds()

		assert(not ids[DEFENSIVE], "the category is gone")
		assert(not ids[UNFLAGGED_DEFENSIVE], "including the spells the game does not flag")
		assert(ids[IMPORTANT], "the other category is untouched")
	end)

	fw.it("keeps a switched-off spell out of a tracked category", function()
		spells.Disabled[DEFENSIVE] = true

		local ids = TrackedIds()

		assert(not ids[DEFENSIVE], "the one spell")
		assert(ids[UNFLAGGED_DEFENSIVE], "the rest of its category")
	end)

	fw.it("filters on an impossible id once nothing is left to track", function()
		-- An empty id map reads as "no ids required", which shows every buff on the unit rather
		-- than none of them.
		options.ShowImportant = false
		options.ShowDefensives = false

		for _, groupKey in ipairs({ DEFENSIVE_GROUP_KEY, IMPORTANT_GROUP_KEY }) do
			local ids = GroupIds(groupKey)

			assert(next(ids) ~= nil, groupKey .. " must never publish an empty id map")

			for spellId in pairs(ids) do
				assert(not categoryIds.Unflagged[spellId], "and nothing real is left in it")
			end
		end
	end)

	fw.it("draws each category from its own group, so they can be coloured apart", function()
		local defensive = GroupIds(DEFENSIVE_GROUP_KEY)
		local important = GroupIds(IMPORTANT_GROUP_KEY)

		assert(defensive[DEFENSIVE] and defensive[UNFLAGGED_DEFENSIVE], "defensives in the one group")
		assert(important[IMPORTANT] and important[UNFLAGGED_IMPORTANT], "importants in the other")
		assert(not defensive[IMPORTANT] and not important[DEFENSIVE], "and neither holds the other's")
	end)

	fw.it("puts a hand-added spell in the important group", function()
		-- It belongs to neither category, so it rides with the importants and takes that colour.
		local custom = 999901

		spells.Custom[custom] = true

		assert(GroupIds(IMPORTANT_GROUP_KEY)[custom], "tracked as important")
		assert(not GroupIds(DEFENSIVE_GROUP_KEY)[custom], "and not as a defensive")
	end)

	fw.it("re-publishes nothing while the tracked set is unchanged", function()
		-- Every push marks the container for a hide/show bounce and a full engine re-parse, and
		-- this path runs for every entry on every roster refresh.
		GroupIds(DEFENSIVE_GROUP_KEY)

		local group = env.containersForUnit("party1")[1]._groups[DEFENSIVE_GROUP_KEY]
		local sets = group.candidateFilterSets or 0

		module:Refresh()
		assert((group.candidateFilterSets or 0) == sets, "an unchanged set must not reach the engine again")

		options.ShowImportant = false
		module:Refresh()
		assert((group.candidateFilterSets or 0) > sets, "a moved toggle still reaches it")
	end)

	fw.it("takes back a hand-added copy of a curated spell, category off or not", function()
		options.ShowImportant = false
		spells.Custom[IMPORTANT] = true

		local ids = TrackedIds()

		assert(not ids[IMPORTANT], "a curated spell answers to its category, not to Custom")
		assert(not spells.Custom[IMPORTANT], "and the duplicate is dropped from the user's list")
	end)
end)

fw.describe("ImportantAuras - anchors that are out of sight", function()
	-- An entry outlives its anchor: WoW frames can never be freed, so a raid's worth of them is
	-- still here in a five-man. They are skipped rather than restyled, and the risk that guards
	-- against is a stale one coming back.
	local frame = env.addUnitFrame("party2", "CUF_Hidden")

	fw.it("takes an entry off screen when its anchor goes", function()
		module:Refresh()
		assert(#env.containersForUnit("party2") > 0, "the visible frame has a container")

		frame:Hide()
		module:Refresh()

		assert(not frame:IsVisible(), "fixture: the anchor is gone")
	end)

	fw.it("brings a returning anchor back in step with the current options", function()
		local custom = 999902

		frame:Hide()
		module:Refresh()

		-- Changed while the anchor was out of sight, so a skipped entry would have missed it.
		spells.Custom[custom] = true

		frame:Show()
		module:Refresh()
		require("AuraContainerMock").tickAll(40)

		local containers = env.containersForUnit("party2")
		assert(#containers > 0, "the anchor is back, so its container is too")

		local group = assert(containers[1]._groups[IMPORTANT_GROUP_KEY], "no important group")
		local ids = assert(group.candidateFilters.includeSpellIDs, "no id filter")

		assert(ids[custom], "the entry picked up the change it slept through")

		spells.Custom[custom] = nil
	end)
end)

fw.describe("ImportantAuras - groups declared after the display", function()
	-- A display is created with none of its groups. The background walker declares them a group
	-- per turn, so a roster turning up does not build them all in one frame. The filters a
	-- display was built with can be well out of date by then.
	fw.it("declares a group with the tracked set current at that moment", function()
		local custom = 999904
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1

		-- A budget change throws every prewarmed spare away, because a group's buttons are handed
		-- out from the count it was declared with. So this frame has to build its own display, and
		-- its groups go in through the walker rather than having been declared hours ago.
		options.Icons.MaxIcons = maxIcons + 1

		env.addUnitFrame("party4", "CUF_Late")
		module:Refresh()

		spells.Custom[custom] = true
		require("AuraContainerMock").tickAll(40)

		local containers = env.containersForUnit("party4")
		assert(#containers > 0, "the frame has a container")

		local group = assert(containers[1]._groups[IMPORTANT_GROUP_KEY], "no important group")
		local ids = assert(group.candidateFilters.includeSpellIDs, "no id filter")

		assert(ids[custom], "the group went in carrying the set it was built with, not the current one")

		spells.Custom[custom] = nil
		options.Icons.MaxIcons = maxIcons
	end)
end)

fw.describe("ImportantAuras - an anchor returning without a refresh", function()
	-- A refresh skips styling for an anchor nobody can see, so the entry carries whatever it had.
	-- The unit-frame visibility hook can bring that frame back with no refresh behind it, which is
	-- the one path that has to put the styling right on its own.
	local frame = env.addUnitFrame("party3", "CUF_Returning")

	fw.it("picks up an option changed while it was out of sight", function()
		local custom = 999903

		module:Refresh()
		assert(#env.containersForUnit("party3") > 0, "fixture: the frame starts with a container")

		frame:Hide()
		module:Refresh()

		-- Changed while hidden. The refresh above and this one both skip the entry.
		spells.Custom[custom] = true
		module:Refresh()

		-- Back on screen through the hook alone, with no Refresh following. The env stub answers
		-- false to IsFriendlyCuf for everything, so the hook is told this frame is one throughout.
		local display = env.addon.Modules.ImportantAuras.Display
		local frames = env.addon.Core.Frames
		local realIsFriendlyCuf = frames.IsFriendlyCuf
		frames.IsFriendlyCuf = function(_, candidate)
			return candidate == frame
		end

		frame:Show()
		display:OnCufUpdateVisible(frame)
		require("AuraContainerMock").tickAll(40)

		frames.IsFriendlyCuf = realIsFriendlyCuf

		local containers = env.containersForUnit("party3")
		assert(#containers > 0, "the frame is back, so its container is too")

		local group = assert(containers[1]._groups[IMPORTANT_GROUP_KEY], "no important group")
		local ids = assert(group.candidateFilters.includeSpellIDs, "no id filter")

		assert(ids[custom],
			"the hook must restyle an entry the refresh skipped, or it shows the old options")

		spells.Custom[custom] = nil
	end)

	fw.it("leaves a torn-down entry down when the module is off", function()
		module:Refresh()

		local containers = env.containersForUnit("party3")
		assert(#containers > 0, "fixture: the frame starts with a container")

		local display = containers[1]

		-- Hidden while the module is on, so the entry is marked as carrying stale styling.
		frame:Hide()
		module:Refresh()

		env.setModuleEnabled("ImportantAuras", false)
		module:Refresh()
		assert(not display._enabled, "fixture: the module tore its display down")

		local frames = env.addon.Core.Frames
		local realIsFriendlyCuf = frames.IsFriendlyCuf
		frames.IsFriendlyCuf = function(_, candidate)
			return candidate == frame
		end

		frame:Show()
		env.addon.Modules.ImportantAuras.Display:OnCufUpdateVisible(frame)

		frames.IsFriendlyCuf = realIsFriendlyCuf

		assert(not display._enabled, "the hook must not wake a disabled module's display back up")

		env.setModuleEnabled("ImportantAuras", true)
		module:Refresh()
	end)
end)

fw.describe("AnchoredIcons - the stale styling flag", function()
	local anchoredIcons = env.addon.Core.AnchoredIcons
	local shownAnchor = { IsVisible = function()
		return true
	end }

	---Only the display, the container and the flag are touched by the helpers under test.
	local function FakeEntry()
		return {
			Display = {
				Enabled = true,
				SetEnabled = function(self, value)
					self.Enabled = value
				end,
				Hide = function() end,
			},
			Container = {
				ResetAllSlots = function() end,
				Frame = { Hide = function() end },
			},
		}
	end

	fw.it("is dropped by a teardown", function()
		local entry = FakeEntry()

		anchoredIcons:HideEntry(entry)
		assert(entry.StyleStale, "fixture: an entry hidden with its anchor carries stale styling")

		anchoredIcons:TeardownEntry(entry)
		assert(not entry.StyleStale, "or a later restyle would bring the entry back")
	end)

	fw.it("restyles nothing while the entry's module is off", function()
		local entry = FakeEntry()
		local applied = false
		local function Apply()
			applied = true
		end

		anchoredIcons:HideEntry(entry)

		assert(not anchoredIcons:RestyleIfStale(entry, shownAnchor, false, Apply), "off, so nothing to do")
		assert(not applied, "and the module's restyle never ran")

		assert(anchoredIcons:RestyleIfStale(entry, shownAnchor, true, Apply), "on, so the hook restyles")
		assert(applied, "through the module's own callback")
	end)
end)
