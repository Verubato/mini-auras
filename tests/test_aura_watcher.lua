-- Tests for the REAL UnitAuraWatcher aura pipeline.
--
-- The watcher is normally stubbed by the test loader, so its aura processing (full rebuild and the
-- incremental UNIT_AURA delta path) had no coverage. These tests drive the real watcher through a
-- simulated aura store (aura_sim) and check two things:
--   1. content  - auras land in the right CC / defensive / buff lists, in the right order; and
--   2. consistency - the incrementally-maintained state always equals a full rebuild of the same
--      aura set (M.assertConsistent forces a rebuild and compares). This is the oracle that protects
--      the incremental delta implementation.

local fw  = require("framework")
local sim = require("aura_sim")

local SORT_DEFAULT  = 0 -- Enum.UnitAuraSortRule.Default
local SORT_UNSORTED = 1 -- Enum.UnitAuraSortRule.Unsorted
local DIR_NORMAL    = 0 -- Enum.UnitAuraSortDirection.Normal
local DIR_REVERSE   = 1 -- Enum.UnitAuraSortDirection.Reverse

local function ids(list)
	local out = {}
	for i, e in ipairs(list) do out[i] = e.AuraInstanceID end
	return table.concat(out, ",")
end

fw.describe("UnitAuraWatcher - content classification", function()
	fw.before_each(sim.reset)

	fw.it("sorts CC, defensives and buffs into the right state lists", function()
		local w = sim.newWatcher("target", nil, { CC = true, Defensives = true, Buffs = true }, SORT_UNSORTED, DIR_NORMAL)
		sim.addAura("target", { id = 1, spellId = 100, harmful = true, crowdControl = true })
		sim.addAura("target", { id = 2, spellId = 200, helpful = true, bigDefensive = true })
		sim.addAura("target", { id = 3, spellId = 300, helpful = true }) -- plain helpful buff
		sim.fire(w, "target", { added = { 1, 2, 3 } })

		fw.eq(ids(w:GetCcState()), "1", "CC list")
		fw.eq(ids(w:GetDefensiveState()), "2", "defensive list")
		fw.eq(ids(w:GetBuffState()), "2,3", "buff list = every helpful aura")
	end)

	fw.it("an aura that is both big- and external-defensive appears once (dedup)", function()
		local w = sim.newWatcher("target", nil, { Defensives = true }, SORT_UNSORTED, DIR_NORMAL)
		sim.addAura("target", { id = 9, spellId = 300, helpful = true, bigDefensive = true, externalDefensive = true })
		sim.fire(w, "target", { added = { 9 } })

		fw.eq(ids(w:GetDefensiveState()), "9", "deduped to a single entry")
		sim.assertConsistent(w, "dedup")
	end)

	fw.it("a CC-only watcher ignores defensives and buffs", function()
		local w = sim.newWatcher("target", nil, { CC = true }, SORT_UNSORTED, DIR_NORMAL)
		sim.addAura("target", { id = 1, spellId = 100, harmful = true, crowdControl = true })
		sim.addAura("target", { id = 2, spellId = 200, helpful = true, bigDefensive = true })
		sim.fire(w, "target", { added = { 1, 2 } })

		fw.eq(ids(w:GetCcState()), "1", "CC tracked")
		fw.eq(ids(w:GetDefensiveState()), "", "defensives untracked")
		fw.eq(ids(w:GetBuffState()), "", "buffs untracked")
	end)
end)

fw.describe("UnitAuraWatcher - sort order", function()
	fw.before_each(sim.reset)

	fw.it("Unsorted/Reverse orders by AuraInstanceID descending", function()
		local w = sim.newWatcher("target", nil, { CC = true }, SORT_UNSORTED, DIR_REVERSE)
		sim.addAura("target", { id = 2, spellId = 100, harmful = true, crowdControl = true })
		sim.addAura("target", { id = 1, spellId = 101, harmful = true, crowdControl = true })
		sim.addAura("target", { id = 3, spellId = 102, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 2, 1, 3 } })

		fw.eq(ids(w:GetCcState()), "3,2,1", "id descending")
	end)

	fw.it("Default follows the API's applied-sequence order", function()
		local w = sim.newWatcher("target", nil, { CC = true }, SORT_DEFAULT, DIR_NORMAL)
		-- add id 3 first (seq 1), then 1 (seq 2), then 2 (seq 3) -> default order 3,1,2
		sim.addAura("target", { id = 3, spellId = 100, harmful = true, crowdControl = true })
		sim.addAura("target", { id = 1, spellId = 101, harmful = true, crowdControl = true })
		sim.addAura("target", { id = 2, spellId = 102, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 3, 1, 2 } })

		fw.eq(ids(w:GetCcState()), "3,1,2", "applied-sequence order")
	end)
end)

fw.describe("UnitAuraWatcher - incremental matches full rebuild", function()
	fw.before_each(sim.reset)

	fw.it("stays consistent after each add / update / remove step", function()
		local w = sim.newWatcher("target", nil, { CC = true, Defensives = true, Buffs = true }, SORT_UNSORTED, DIR_NORMAL)

		sim.addAura("target", { id = 5, spellId = 100, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 5 } })
		sim.assertConsistent(w, "after add CC")

		sim.addAura("target", { id = 6, spellId = 200, helpful = true, bigDefensive = true })
		sim.addAura("target", { id = 7, spellId = 201, helpful = true, externalDefensive = true })
		sim.fire(w, "target", { added = { 6, 7 } })
		sim.assertConsistent(w, "after add defensives")

		sim.updateAura("target", 6, { duration = { remaining = 3 } })
		sim.fire(w, "target", { updated = { 6 } })
		sim.assertConsistent(w, "after update duration")

		sim.removeAura("target", 5)
		sim.fire(w, "target", { removed = { 5 } })
		sim.assertConsistent(w, "after remove CC")
	end)

	fw.it("stays consistent across a long sequence with no intervening full update", function()
		local w = sim.newWatcher("target", nil, { CC = true, Defensives = true, Buffs = true }, SORT_UNSORTED, DIR_NORMAL)

		sim.addAura("target", { id = 10, spellId = 100, harmful = true, crowdControl = true })
		sim.addAura("target", { id = 11, spellId = 200, helpful = true, bigDefensive = true })
		sim.addAura("target", { id = 12, spellId = 300, helpful = true })
		sim.fire(w, "target", { added = { 10, 11, 12 } })

		sim.addAura("target", { id = 13, spellId = 201, helpful = true, externalDefensive = true })
		sim.fire(w, "target", { added = { 13 } })

		sim.removeAura("target", 11)
		sim.fire(w, "target", { removed = { 11 } })

		sim.updateAura("target", 10, { duration = { remaining = 1 } })
		sim.fire(w, "target", { updated = { 10 } })

		sim.removeAura("target", 12)
		sim.fire(w, "target", { removed = { 12 } })

		-- One consistency check at the very end catches drift accumulated across the whole sequence.
		sim.assertConsistent(w, "end of sequence")
	end)

	fw.it("re-adding a removed AuraInstanceID is handled", function()
		local w = sim.newWatcher("target", nil, { CC = true }, SORT_UNSORTED, DIR_NORMAL)
		sim.addAura("target", { id = 1, spellId = 100, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 1 } })
		sim.removeAura("target", 1)
		sim.fire(w, "target", { removed = { 1 } })
		sim.addAura("target", { id = 1, spellId = 100, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 1 } })
		sim.assertConsistent(w, "re-add")
		fw.eq(ids(w:GetCcState()), "1", "re-added CC present once")
	end)
end)

fw.describe("UnitAuraWatcher - fuzz vs full-rebuild oracle", function()
	fw.before_each(sim.reset)

	-- A long pseudo-random add/remove/update sequence applied purely incrementally, checked against a
	-- full rebuild only every N steps (so drift has room to accumulate). The full rebuild is the
	-- trusted oracle, so any classification / dedup / removal / sort bug surfaces as a mismatch.
	local templates = {
		[1] = { spellId = 1001, harmful = true, crowdControl = true },
		[2] = { spellId = 1002, harmful = true, crowdControl = true },
		[3] = { spellId = 1003, helpful = true, bigDefensive = true },
		[4] = { spellId = 1004, helpful = true, externalDefensive = true },
		[5] = { spellId = 1005, helpful = true },                                  -- plain buff
		[6] = { spellId = 1006, helpful = true, bigDefensive = true, externalDefensive = true },
		[7] = { spellId = 1007, harmful = true },                                  -- harmful, not CC
		[8] = { spellId = 1008, helpful = true, bigDefensive = true },
	}

	local function runFuzz(interestedIn, sortDir, seed)
		math.randomseed(seed)
		local w = sim.newWatcher("target", nil, interestedIn, SORT_UNSORTED, sortDir)
		local present = {}

		for step = 1, 300 do
			local op = math.random(3)
			local id = math.random(8)
			if op == 1 and not present[id] then
				local t = templates[id]
				sim.addAura("target", {
					id = id, spellId = t.spellId, harmful = t.harmful, helpful = t.helpful,
					bigDefensive = t.bigDefensive, externalDefensive = t.externalDefensive, crowdControl = t.crowdControl,
				})
				present[id] = true
				sim.fire(w, "target", { added = { id } })
			elseif op == 2 and present[id] then
				sim.removeAura("target", id)
				present[id] = nil
				sim.fire(w, "target", { removed = { id } })
			elseif op == 3 and present[id] then
				sim.updateAura("target", id, { duration = { remaining = math.random(30) } })
				sim.fire(w, "target", { updated = { id } })
			end

			if step % 40 == 0 then
				sim.assertConsistent(w, "fuzz step " .. step)
			end
		end
		sim.assertConsistent(w, "fuzz end")
	end

	fw.it("CC + Defensives + Buffs, reverse sort", function()
		runFuzz({ CC = true, Defensives = true, Buffs = true }, DIR_REVERSE, 1337)
	end)

	fw.it("CC + Defensives (nameplate-style), normal sort", function()
		runFuzz({ CC = true, Defensives = true }, DIR_NORMAL, 4242)
	end)

	fw.it("Buffs only (precog-style), reverse sort", function()
		runFuzz({ Buffs = true }, DIR_REVERSE, 9001)
	end)
end)

fw.describe("UnitAuraWatcher - incremental path is actually taken", function()
	fw.before_each(sim.reset)

	fw.it("a partial update on an Unsorted watcher does NOT re-query all auras", function()
		local w = sim.newWatcher("target", nil, { CC = true, Defensives = true }, SORT_UNSORTED, DIR_NORMAL)
		sim.getUnitAurasCalls = 0 -- ignore the New() prime's full rebuild

		sim.addAura("target", { id = 1, spellId = 100, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 1 } })
		sim.removeAura("target", 1)
		sim.fire(w, "target", { removed = { 1 } })

		fw.eq(sim.getUnitAurasCalls, 0, "incremental path must not call GetUnitAuras")
	end)

	fw.it("a full update DOES re-query (full rebuild)", function()
		local w = sim.newWatcher("target", nil, { CC = true }, SORT_UNSORTED, DIR_NORMAL)
		sim.getUnitAurasCalls = 0
		sim.fire(w, "target", { full = true })
		fw.truthy(sim.getUnitAurasCalls > 0, "full update falls back to a full rebuild")
	end)

	fw.it("a Default-sort watcher falls back to a full rebuild on partial updates", function()
		local w = sim.newWatcher("target", nil, { CC = true }, SORT_DEFAULT, DIR_NORMAL)
		sim.getUnitAurasCalls = 0
		sim.addAura("target", { id = 1, spellId = 100, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 1 } })
		fw.truthy(sim.getUnitAurasCalls > 0, "Default sort can't go incremental, so it re-queries")
	end)
end)

fw.describe("UnitAuraWatcher - unit lifecycle", function()
	fw.before_each(sim.reset)

	fw.it("a dead unit reports empty state", function()
		local w = sim.newWatcher("target", nil, { CC = true }, SORT_UNSORTED, DIR_NORMAL)
		sim.addAura("target", { id = 1, spellId = 100, harmful = true, crowdControl = true })
		sim.fire(w, "target", { added = { 1 } })
		fw.eq(ids(w:GetCcState()), "1", "alive: has CC")

		sim.setDead("target", true)
		sim.fire(w, "target", { full = true })
		fw.eq(ids(w:GetCcState()), "", "dead: empty CC state")
	end)
end)
