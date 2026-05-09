-- Tests for Beserker Roar (Warrior PvP talent 5702, SpellId 1227751) spillover suppression.
--
-- Beserker Roar applies an IMPORTANT aura on all nearby party members including the caster.
-- IsProbablyBeserkerRoar suppresses false commits and predictions on non-warrior allies
-- while allowing the warrior's own aura to be tracked via the BR rule.
--
-- Suppression fires when:
--   - The aura is IMPORTANT-only (not BIG_DEFENSIVE, not EXTERNAL_DEFENSIVE)
--   - We are in a PvP context (arena / pvp / pvp-flagged unit)
--   - The target is NOT a warrior with the BR PvP talent
--   - A warrior with the BR PvP talent IS among the candidateUnits
--   - The target has no CanCancelEarly IMPORTANT rule of their own that explains the aura
--   - The measured duration (when available) does not exceed BR's max duration + tolerance
--
-- Suppression is lifted when:
--   a) The target IS the warrior who pressed BR (BR rule handles it directly)
--   b) Duration exceeds beserkerRoarMaxDuration + tolerance (6.5s)
--   c) No warrior with BR talent is in the group
--   d) The target has their own CanCancelEarly IMPORTANT rule (e.g. Paladin's BoF lifts it)
--   e) Not in a PvP context
--
-- Key test scenarios:
--   - IsProbablyBeserkerRoar returns true for hunter/mage when BR warrior in group
--     (confirms predict path: Trueshot/Combustion would be suppressed, not falsely shown)
--   - Warrior's own Beserker Roar IS committed (rule matches for the warrior directly)
--   - Combustion and Trueshot commit normally when their full duration passes (exceeds BR max)

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods = loader.get()
local B    = mods.brain

local IMP    = { IMPORTANT = true }
local BIGDEF = { IMPORTANT = true, BIG_DEFENSIVE = true }

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

local function makeTracked(auraTypes, startTime, castSnapshot, evidence, castSpellIdSnapshot)
    return {
        StartTime           = startTime or 1.0,
        AuraTypes           = auraTypes,
        Evidence            = evidence,
        CastSnapshot        = castSnapshot or {},
        CastSpellIdSnapshot = castSpellIdSnapshot or {},
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 1: IsProbablyBeserkerRoar direct API tests
--
-- Tests the function's return values under a variety of conditions.
-- This covers the predict path suppression (IsProbablyBeserkerRoar is called in PredictRule
-- before any spell is attributed, so a true return prevents Trueshot/Combustion glows).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("IsProbablyBeserkerRoar - direct function tests", function()
    fw.before_each(reset)

    fw.it("returns true: hunter in arena, BR warrior in candidates (predict path)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        mods.talents._setSpec("party1", 254)  -- Marksmanship Hunter
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        -- measuredDuration=nil mirrors the predict path (aura just appeared)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, nil)
        fw.eq(result, true, "Hunter predict must be suppressed by BR warrior in group")
    end)

    fw.it("returns true: mage in arena, BR warrior in candidates (predict path)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)  -- Fire Mage
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, nil)
        fw.eq(result, true, "Fire Mage predict must be suppressed by BR warrior in group")
    end)

    fw.it("returns true: hunter with short measured duration within BR window (commit path)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        -- 3.0 <= 6.0 + 0.5 = 6.5: within BR window -> suppression fires
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0)
        fw.eq(result, true, "Short IMPORTANT aura on hunter suppressed when BR warrior in group")
    end)

    fw.it("returns false: target IS the warrior with BR talent (caster's own aura)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setTalent("party1", 5702, true)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", {}, 3.0)
        fw.eq(result, false, "Warrior's own BR aura must NOT be suppressed")
    end)

    fw.it("returns false: no warrior with BR talent in candidates", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        -- party2 is a warrior but has no BR talent set
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0)
        fw.eq(result, false, "Must NOT suppress when no BR warrior in group")
    end)

    fw.it("returns false: outside PvP context", function()
        -- Default wow.reset() sets instance type to 'none' (PvE)
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0)
        fw.eq(result, false, "Must NOT suppress outside PvP context")
    end)

    fw.it("returns false: measured duration exceeds BR max (10 + 0.5 = 10.5s threshold)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        -- 11.0 > 10.5: aura lasted longer than BR could -> not BR spillover
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 11.0)
        fw.eq(result, false, "Must NOT suppress when duration exceeds BR max")
    end)

    fw.it("returns false: BIG_DEFENSIVE aura is not BR spillover", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyBeserkerRoar(BIGDEF, "party1", { "party2" }, 3.0)
        fw.eq(result, false, "BIG_DEFENSIVE auras are not BR spillover")
    end)

    fw.it("returns false: Paladin has CanCancelEarly BoF (no RequiresTalent) -> lifts suppression", function()
        -- Paladin's Blessing of Freedom (8s, CanCancelEarly, Important, no RequiresTalent)
        -- is a legitimate explanation for any short IMPORTANT aura on a Paladin.
        -- hasMatchingEarlyCancelRule finds BoF -> return false -> suppression lifted.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0)
        fw.eq(result, false, "BoF (no RequiresTalent) lifts BR suppression for Paladin")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 2: Warrior's own Beserker Roar is committed
--
-- The warrior who pressed BR also receives the IMPORTANT aura.
-- IsProbablyBeserkerRoar returns false for the warrior (the BR rule handles it).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Beserker Roar committed for warrior caster", function()
    fw.before_each(reset)

    fw.it("BR commits for Arms warrior when they have the PvP talent", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 71)  -- Arms
        mods.talents._setTalent("party1", 5702, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- Duration 4.0: within BR CanCancelEarly window (<=6.5)
        local rule, unit = B:FindBestCandidate(entry, t, 4.0, {})
        fw.not_nil(rule, "BR rule should commit for the warrior")
        fw.eq(rule and rule.SpellId, 1227751, "SpellId should be Beserker Roar (1227751)")
        fw.eq(unit, "party1", "Warrior is the caster")
    end)

    fw.it("BR commits for warrior even when another BR warrior is in the group", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party1", 5702, true)
        mods.talents._setTalent("party2", 5702, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- party1 IS a warrior with BR -> IsProbablyBeserkerRoar returns false for party1
        local rule, unit = B:FindBestCandidate(entry, t, 4.0, { "party2" })
        fw.not_nil(rule, "BR should commit for party1 warrior")
        fw.eq(rule and rule.SpellId, 1227751, "SpellId should be Beserker Roar")
        fw.eq(unit, "party1", "party1 warrior is the caster")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 3: Trueshot and Combustion are NOT falsely triggered
--
-- On the predict path, IsProbablyBeserkerRoar returns true for hunters and mages
-- when a BR warrior is in the group (tested via direct API in Section 1).
--
-- On the commit path, Trueshot (15s exact) and Combustion (10s MinDuration) have
-- durations well above the BR max (6.5s threshold), so BR suppression does not fire
-- when the full spell duration passes, and these spells still commit normally.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Trueshot and Combustion commit normally when full duration passes", function()
    fw.before_each(reset)

    fw.it("Trueshot (15s) commits for MM Hunter when no BR warrior in group", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        mods.talents._setSpec("party1", 254)  -- Marksmanship
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- 15.0: exact match for the 15s Trueshot rule (within +-0.5 tolerance)
        local rule, unit = B:FindBestCandidate(entry, t, 15.0, {})
        fw.not_nil(rule, "Trueshot should commit when no BR warrior present")
        fw.eq(rule and rule.SpellId, 288613, "SpellId should be Trueshot (288613)")
        fw.eq(unit, "party1", "MM Hunter is the caster")
    end)

    fw.it("Combustion (10s MinDuration) commits for Fire Mage when no BR warrior in group", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)  -- Fire
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- 10.0 >= 10 - 0.5 = 9.5: satisfies MinDuration check
        local rule, unit = B:FindBestCandidate(entry, t, 10.0, {})
        fw.not_nil(rule, "Combustion should commit when no BR warrior present")
        fw.eq(rule and rule.SpellId, 190319, "SpellId should be Combustion (190319)")
        fw.eq(unit, "party1", "Fire Mage is the caster")
    end)

    fw.it("Trueshot (15s) still commits even with BR warrior in group (duration exceeds BR max)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        mods.talents._setSpec("party1", 254)
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- 15.0 > 10.5 -> BR suppression skipped; 15.0 matches Trueshot (exact ±0.5)
        local rule, unit = B:FindBestCandidate(entry, t, 15.0, { "party2" })
        fw.not_nil(rule, "Trueshot should commit when duration exceeds BR max")
        fw.eq(rule and rule.SpellId, 288613, "SpellId should be Trueshot")
        fw.eq(unit, "party1", "MM Hunter is the caster")
    end)

    fw.it("Combustion commits with BR warrior when duration clearly exceeds BR max (>10.5s)", function()
        -- BR lasts 10s; Combustion has MinDuration so any measured duration >= 9.5s is valid.
        -- At exactly 10s the auras are indistinguishable and BR suppression fires.
        -- At 11s the mage demonstrably held Combustion longer than BR could last -> commits.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- 11.0 > 10.5 -> BR suppression skipped; 11.0 >= 9.5 -> Combustion MinDuration matches
        local rule, unit = B:FindBestCandidate(entry, t, 11.0, { "party2" })
        fw.not_nil(rule, "Combustion should commit when duration clearly exceeds BR max")
        fw.eq(rule and rule.SpellId, 190319, "SpellId should be Combustion")
        fw.eq(unit, "party1", "Fire Mage is the caster")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 4: CanCancelEarly rules on the target interact with BR suppression
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("BR suppression interacts with target's own CanCancelEarly rules", function()
    fw.before_each(reset)

    fw.it("Spell Reflect (RequiresTalent=23920) lifts suppression when warrior is talented", function()
        -- Arms warrior (party1) has Spell Reflect talented.
        -- IsProbablyBeserkerRoar: warriorHasBeserkerRoar(party1)=false (no talent 5702).
        -- hasMatchingEarlyCancelRule finds Spell Reflect -> return false -> not suppressed.
        -- Spell Reflect then commits via FindBestCandidate.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 71)  -- Arms
        mods.talents._setTalent("party1", 23920, true)  -- Spell Reflect
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)  -- BR caster
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- Duration 3.0: within Spell Reflect (5s CanCancelEarly, <= 5.5)
        local rule, unit = B:FindBestCandidate(entry, t, 3.0, { "party2" })
        fw.not_nil(rule, "Spell Reflect should commit - CanCancelEarly rule lifts BR suppression")
        fw.eq(rule and rule.SpellId, 23920, "SpellId should be Spell Reflect (23920)")
        fw.eq(unit, "party1", "party1 warrior is the caster")
    end)

    fw.it("Spell Reflect NOT talented -> BR suppression fires for warrior target", function()
        -- Arms warrior (party1) has NO Spell Reflect talent -> RulePassesTalentGates fails.
        -- hasMatchingEarlyCancelRule returns false -> IsProbablyBeserkerRoar returns true.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 71)  -- Arms, no Spell Reflect
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0)
        fw.eq(result, true, "No CanCancelEarly rule without talent -> BR suppression fires")
    end)
end)
