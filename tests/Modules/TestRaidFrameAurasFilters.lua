-- What the raid frame aura display actually tracks. Both helpful categories share one aura group,
-- so their toggles have to pick the spell ids reaching it: the bug this guards is Show Important
-- and Show Defensives acting as a single on/off switch, leaving both categories on screen until
-- the user cleared them BOTH.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local HELPFUL_GROUP_KEY = "helpful"

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("RaidFrameAurasModule", true)

env.addUnitFrame("party1", "CUF_Filters")

env.loadModule("src/Modules/RaidFrameAuras/Display.lua")
env.loadModule("src/Modules/RaidFrameAuras/Module.lua")

local module = env.addon.Modules.RaidFrameAurasModule
local categoryIds = env.addon.Core.AuraCategoryIds
local options = db.Modules.RaidFrameAurasModule.Default
local spells = db.Modules.RaidFrameAurasModule.Spells

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

---The spell ids the helpful group is currently filtering on, as published to the engine.
---@return table<number, boolean>
local function TrackedIds()
	module:Refresh()

	local containers = env.containersForUnit("party1")
	assert(#containers > 0, "no aura container for party1")

	local group = assert(containers[1]._groups[HELPFUL_GROUP_KEY], "no helpful group")
	local filters = assert(group.candidateFilters, "the helpful group published no filters")

	return assert(filters.includeSpellIDs, "the helpful group must filter by spell id")
end

fw.describe("RaidFrameAurasModule - the tracked spell ids", function()
	fw.before_each(function()
		options.ShowCC = false
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

	fw.it("takes back a hand-added copy of a curated spell, category off or not", function()
		options.ShowImportant = false
		spells.Custom[IMPORTANT] = true

		local ids = TrackedIds()

		assert(not ids[IMPORTANT], "a curated spell answers to its category, not to Custom")
		assert(not spells.Custom[IMPORTANT], "and the duplicate is dropped from the user's list")
	end)
end)
