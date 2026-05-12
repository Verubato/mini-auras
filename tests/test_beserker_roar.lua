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
--   f) No other unit has a concurrent IMPORTANT-only aura (solo spell press, not an AoE BR event)
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

    fw.it("returns true: hunter with co-occurring aura at commit time (BR event)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        -- Simulate warrior also got the IMPORTANT aura at the same time (BR AoE event).
        B._TestSetImportantAuraStart("party2", 1.0)
        -- count=1 (warrior) -> co-occurrence passes -> warrior has BR -> suppressed
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0, 1.0)
        fw.eq(result, true, "Short IMPORTANT aura on hunter suppressed when BR event detected")
    end)

    fw.it("returns true: hunter has no matching rule (count=0 fallback -> BR suppression fires)", function()
        -- count=0: hasMatchingRule fallback path.  Hunter has no rule matching a 3s IMPORTANT
        -- aura -> no match -> warrior check fires -> suppressed (BR is the default explanation).
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0, 1.0)
        fw.eq(result, true, "No matching rule for hunter at 3s -> BR fallback suppresses")
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

    fw.it("returns false: Paladin has CanCancelEarly BoF -> lifts suppression even during BR event", function()
        -- Paladin's Blessing of Freedom (8s, CanCancelEarly) covers BR's entire cancel range.
        -- With a co-occurring warrior aura (BR event confirmed), hasMatchingEarlyCancelRule
        -- finds BoF -> suppression is lifted -> returns false.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)  -- warrior also has concurrent aura (BR event)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0, 1.0)
        fw.eq(result, false, "Paladin BoF lifts BR suppression even during confirmed BR event")
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

    fw.it("Combustion (MinDuration 10s) commits for Fire Mage even with BR warrior in group", function()
        -- Solo Combustion press (no _TestSetImportantAuraStart -> count=0): co-occurrence check
        -- returns false immediately, so BR suppression never fires.  Combustion then commits.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- 10.0: hasMatchingRule finds Combustion's MinDuration rule -> BR suppression lifted
        local rule, unit = B:FindBestCandidate(entry, t, 10.0, { "party2" })
        fw.not_nil(rule, "Combustion should commit - MinDuration rule lifts BR suppression")
        fw.eq(rule and rule.SpellId, 190319, "SpellId should be Combustion")
        fw.eq(unit, "party1", "Fire Mage is the caster")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 4: CanCancelEarly rules on the target interact with BR suppression
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("BR suppression interacts with target's own CanCancelEarly rules", function()
    fw.before_each(reset)

    fw.it("Spell Reflect (RequiresTalent=23920) lifts suppression even during real BR event", function()
        -- Arms warrior (party1) has Spell Reflect talented.
        -- Warrior (party2) also received a concurrent IMPORTANT aura (BR event) -> count=1.
        -- confirmedAoeEvent=true -> hasMatchingEarlyCancelRule finds SR (CanCancelEarly,
        -- RequiresTalent=23920 satisfied) -> suppression is lifted -> SR rule commits.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 71)  -- Arms
        mods.talents._setTalent("party1", 23920, true)  -- Spell Reflect
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)  -- BR caster
        B._TestSetImportantAuraStart("party2", 1.0)  -- warrior also received IMPORTANT aura (BR event)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 3.0, { "party2" })
        fw.not_nil(rule, "Spell Reflect lifts BR suppression even during confirmed BR event")
        fw.eq(rule and rule.SpellId, 23920, "SpellId should be Spell Reflect (23920)")
        fw.eq(unit, "party1", "Arms warrior is the caster")
    end)

    fw.it("Spell Reflect NOT talented -> BR suppression fires in confirmed BR event", function()
        -- Arms warrior (party1) has NO Spell Reflect talent.
        -- Warrior (party2) received a concurrent IMPORTANT aura (BR event) -> count=1.
        -- confirmedAoeEvent=true -> hasMatchingEarlyCancelRule -> no 23920 talent -> false.
        -- Warrior check fires -> returns true.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 71)  -- Arms, no Spell Reflect
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0, 1.0)
        fw.eq(result, true, "No CanCancelEarly rule without talent -> BR suppression fires")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 5: Rogue Evasion is not blocked by Beserker Roar suppression
--
-- Evasion (SpellId 5277) is a 10s IMPORTANT aura with no CanCancelEarly and no MinDuration.
-- It falls within the BR suppression window (≤10.5s).
--
-- When pressed solo (count=0): hasMatchingRule finds Evasion's 10s exact-duration rule ->
-- BR suppression is NOT fired and Evasion commits normally.
--
-- When BR fires simultaneously (count>0, confirmed AoE event): hasMatchingEarlyCancelRule
-- does not find Evasion (no CanCancelEarly) -> BR suppression fires (known limitation,
-- extremely rare in practice).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Rogue Evasion is not suppressed by Beserker Roar", function()
    fw.before_each(reset)

    fw.it("Evasion (10s exact) commits for Rogue when BR warrior is in group (solo press)", function()
        -- No concurrent IMPORTANT auras (count=0) -> hasMatchingRule finds Evasion (10s exact)
        -- -> BR suppression not fired -> Evasion commits normally.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "ROGUE")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 10.0, { "party2" })
        fw.not_nil(rule, "Evasion should commit when pressed solo (count=0)")
        fw.eq(rule and rule.SpellId, 5277, "SpellId should be Evasion (5277)")
        fw.eq(unit, "party1", "Rogue is the caster")
    end)

    fw.it("BR still suppresses Rogue on predict path when no matching rule exists", function()
        -- startTime=nil -> ambiguous path; measuredDuration=nil -> only CanCancelEarly rules
        -- lift suppression in hasMatchingRule.  Evasion has no CanCancelEarly -> not found ->
        -- warrior check fires -> suppressed.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "ROGUE")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, nil)
        fw.eq(result, true, "Rogue predict path suppressed - Evasion has no CanCancelEarly")
    end)

    fw.it("Evasion suppressed when BR event fires simultaneously (warrior concurrent aura)", function()
        -- Warrior received concurrent IMPORTANT aura at same time (count=1) -> confirmedAoeEvent.
        -- hasMatchingEarlyCancelRule: Evasion has no CanCancelEarly -> not found -> suppressed.
        -- Known limitation: simultaneous Evasion + BR press is ambiguous and extremely rare.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "ROGUE")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule = B:FindBestCandidate(entry, t, 10.0, { "party2" })
        fw.is_nil(rule, "Evasion suppressed when co-occurring with simultaneous BR press")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 6: Enhancement Shaman Doomwinds is not blocked by Beserker Roar
--
-- Doomwinds (SpellId 384352, BySpec[263]) has two variants:
--   8s  base duration (no Thorim's Invocation)
--   10s extended duration (Thorim's Invocation)
-- Both are IMPORTANT-only exact-duration rules within the BR window (≤10.5s).
--
-- When pressed solo (count=0): hasMatchingRule finds Doomwinds's exact-duration rule ->
-- BR suppression is NOT fired and Doomwinds commits normally.
--
-- When BR fires simultaneously (count>0, confirmed AoE event): rule check skipped entirely ->
-- BR suppression fires (known limitation, extremely rare in practice).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Enhancement Shaman Doomwinds is not suppressed by Beserker Roar", function()
    fw.before_each(reset)

    local function setupEnhShaman()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setSpec("party1", 263)         -- Enhancement
        mods.talents._setTalent("party1", 384352, true)  -- Doomwinds talent
        -- Do NOT set 114051 (Ascendance) or 378270 (Deeply Rooted Elements):
        -- ExcludeIfTalent would disqualify both Doomwinds rules if either is present.
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)  -- BR caster
    end

    fw.it("Doomwinds (8s) commits for Enh Shaman when BR warrior is in group (solo press)", function()
        -- No concurrent IMPORTANT auras (count=0) -> hasMatchingRule finds Doomwinds (8s exact)
        -- -> BR suppression not fired -> Doomwinds commits normally.
        setupEnhShaman()
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 8.0, { "party2" })
        fw.not_nil(rule, "Doomwinds (8s) should commit when pressed solo (count=0)")
        fw.eq(rule and rule.SpellId, 384352, "SpellId should be Doomwinds (384352)")
        fw.eq(unit, "party1", "Enh Shaman is the caster")
    end)

    fw.it("Doomwinds +2s (10s, Thorim's Invocation) commits for Enh Shaman (solo press)", function()
        -- No concurrent IMPORTANT auras (count=0) -> hasMatchingRule finds Doomwinds (10s exact)
        -- -> BR suppression not fired -> Doomwinds commits normally.
        setupEnhShaman()
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 10.0, { "party2" })
        fw.not_nil(rule, "Doomwinds (10s) should commit when pressed solo (count=0)")
        fw.eq(rule and rule.SpellId, 384352, "SpellId should be Doomwinds (384352)")
        fw.eq(unit, "party1", "Enh Shaman is the caster")
    end)

    fw.it("Doomwinds suppressed when BR event fires simultaneously (warrior concurrent aura)", function()
        -- Warrior received concurrent IMPORTANT aura at same time (count=1) -> confirmedAoeEvent.
        -- hasMatchingEarlyCancelRule: Doomwinds has no CanCancelEarly -> not found -> suppressed.
        -- Known limitation: simultaneous Doomwinds + BR press is ambiguous and extremely rare.
        setupEnhShaman()
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule = B:FindBestCandidate(entry, t, 8.0, { "party2" })
        fw.is_nil(rule, "Doomwinds suppressed when co-occurring with simultaneous BR press")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 7: Monk Revival is not suppressed by Beserker Roar
--
-- Mistweaver Monks with Peaceweaver (PvP talent 5395) cast Revival/Restoral (2s IMPORTANT)
-- on all party members simultaneously.  When a warrior presses BR at the same time, all
-- party members receive concurrent IMPORTANT auras → confirmedAoeEvent=true.
--
-- IsProbablyBeserkerRoar has a Peaceweaver early-return: if the target is a Monk with
-- Peaceweaver and their cast snapshot proves they pressed Revival, return false immediately
-- so their own aura commits as Revival, not as BR spillover.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Monk Revival not suppressed by Beserker Roar", function()
    fw.before_each(reset)

    fw.it("Revival committed for Monk even when warrior with BR fires simultaneously", function()
        -- Monk (local player, party1 alias) presses Revival.
        -- Warrior (party2) presses BR at the same time -> concurrent IMPORTANT aura -> confirmedAoeEvent=true.
        -- IsProbablyBeserkerRoar: Monk+Peaceweaver, Revival in cast snapshot -> return false -> not suppressed.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party1", 270)
        mods.talents._setTalent("player", 5395, true)   -- Peaceweaver
        mods.talents._setTalent("party1", 5395, true)
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)   -- Beserker Roar
        -- Warrior also received a concurrent IMPORTANT aura (BR event) -> confirmedAoeEvent=true.
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.not_nil(rule, "Revival must commit even when a BR warrior fires simultaneously")
        fw.eq(rule and rule.SpellId, 115310, "SpellId should be Revival (115310)")
        fw.eq(unit, "party1", "Monk is the attributed caster")
    end)

    fw.it("Monk without Revival cast is still suppressed by BR (BR is the likely explanation)", function()
        -- Monk did NOT press Revival (empty cast snapshot).
        -- Warrior pressed BR (concurrent IMPORTANT aura) -> confirmedAoeEvent=true.
        -- IsProbablyRevival=false -> falls through to warrior check -> suppressed.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party1", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party1", 5395, true)
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry = loader.makeEntry("party1")
        local t     = makeTracked(IMP, 1.0, {}, nil, {})  -- empty cast snapshot
        local rule  = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "BR suppression holds when Monk has no Revival cast in snapshot")
    end)
end)

-- Section 8: Simultaneous aura removal rules out Beserker Roar
--
-- GT absorption and Revival expiry remove the IMPORTANT aura from all affected party members in
-- the same server tick.  BR falls off per-unit independently, so when multiple units lose their
-- IMPORTANT-only aura simultaneously, BR is ruled out.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Simultaneous aura removal rules out Beserker Roar", function()
    fw.before_each(reset)

    local function setupBrWarriorGroup()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
    end

    fw.it("BR suppression lifted when a second unit also lost the aura simultaneously", function()
        -- party1 (Hunter) and party2 (Warrior) both lose their IMPORTANT aura at t=3.0.
        -- The Warrior's removal is recorded first; when the Hunter's aura is evaluated
        -- the simultaneous removal count > 0, which rules out BR.
        setupBrWarriorGroup()
        B._TestSetImportantAuraStart("party1", 1.0)
        B._TestSetImportantAuraStart("party2", 1.0)
        -- Simulate the second unit's removal being recorded (e.g. GT absorbed) at t=3.0.
        B._TestSetImportantAuraEnd("party2", 3.0)
        local entry = loader.makeEntry("party1")
        -- startTime=1.0, measuredDuration=2.0 -> endTime=3.0 -> concurrent removal detected.
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local result = B:IsProbablyBeserkerRoar(t.AuraTypes, "party1", { "party2" }, 2.0, 1.0, false, {})
        fw.eq(result, false, "Simultaneous removal rules out BR for Hunter when another unit also lost aura at t=3.0")
    end)

    fw.it("BR suppression applies when removals are NOT simultaneous (BR falls off independently)", function()
        -- party2 (Warrior) lost aura at t=2.0, party1 (Hunter) at t=5.0 -> far apart -> BR suppresses.
        setupBrWarriorGroup()
        B._TestSetImportantAuraStart("party1", 1.0)
        B._TestSetImportantAuraStart("party2", 1.0)
        B._TestSetImportantAuraEnd("party2", 2.0)  -- warrior's aura ended at t=2.0
        local entry = loader.makeEntry("party1")
        -- startTime=1.0, measuredDuration=4.0 -> endTime=5.0 -> 3s apart -> not simultaneous.
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 4.0, 1.0, false, {})
        fw.eq(result, true, "BR suppression holds when removals are not simultaneous")
    end)

    fw.it("BR suppression applies when only the target unit's removal is recorded (no concurrent data)", function()
        -- Only party1's own removal is recorded; no other unit's removal in the window.
        -- This is the first-unit-processed case: count=0, BR suppression applies.
        setupBrWarriorGroup()
        B._TestSetImportantAuraStart("party1", 1.0)
        B._TestSetImportantAuraStart("party2", 1.0)
        -- No _TestSetImportantAuraEnd for party2 -> no concurrent removal recorded.
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 2.0, 1.0, false, {})
        fw.eq(result, true, "BR suppression holds when no concurrent removal data is available (first-unit case)")
    end)
end)

-- Section 9: Local player as BR warrior candidate - negative cast evidence
--
-- UNIT_SPELLCAST_SUCCEEDED always fires for the local player in 12.0.5+.
-- When the local player is the only warrior with BR and their snapshot has no BR cast,
-- FilterLocalPlayerCandidates removes them before IsProbablyBeserkerRoar is called,
-- so suppression does not fire.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Local player as BR warrior: negative cast evidence bypasses suppression", function()
    fw.before_each(reset)

    fw.it("BR does not fire when local player (only BR warrior) has no BR cast in snapshot", function()
        -- party1 = local player (Warrior with BR); targetUnit = "party2" (Hunter).
        -- Empty snapshot -> FilterLocalPlayerCandidates removes party1 -> no BR warrior candidate.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player",  "WARRIOR")
        wow.setUnitClass("party1",  "WARRIOR")
        mods.talents._setTalent("player",  5702, true)
        mods.talents._setTalent("party1",  5702, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1" }, {}, IMP, 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party2", filtered, 2.0, 1.0, false, {})
        fw.eq(result, false, "BR suppression must not fire when local player provably did not press BR")
    end)

    fw.it("BR fires when local player (only BR warrior) has BR cast in snapshot", function()
        -- Same setup but local player's snapshot contains BR cast (CastSpellId 384100).
        -- FilterLocalPlayerCandidates finds the matching rule -> party1 stays in candidates.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player",  "WARRIOR")
        wow.setUnitClass("party1",  "WARRIOR")
        mods.talents._setTalent("player",  5702, true)
        mods.talents._setTalent("party1",  5702, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        local castSnap = { ["player"] = { { SpellId = 384100, Time = 1.0 } } }
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1" }, castSnap, IMP, 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party2", filtered, 2.0, 1.0, false, castSnap)
        fw.eq(result, true, "BR suppression must fire when local player provably pressed BR")
    end)

    fw.it("BR fires when a remote warrior (not local player) is the only candidate", function()
        -- party1 = remote Warrior with BR (not the local player).
        -- No local player alias in candidates -> filter is a no-op -> BR suppression fires normally.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setTalent("party1", 5702, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1" }, {}, IMP, 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party2", filtered, 2.0, 1.0, false, {})
        fw.eq(result, true, "BR suppression must fire when a remote warrior is the candidate")
    end)

    fw.it("BR fires when a second warrior pressed BR even if local player did not", function()
        -- party1 = local player (Warrior, no BR cast); party3 = remote Warrior with BR.
        -- Filter removes party1 (no cast); party3 stays -> suppression still fires.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player",  "WARRIOR")
        wow.setUnitClass("party1",  "WARRIOR")
        mods.talents._setTalent("player",  5702, true)
        mods.talents._setTalent("party1",  5702, true)
        wow.setUnitClass("party3", "WARRIOR")
        mods.talents._setTalent("party3", 5702, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        B._TestSetImportantAuraStart("party3", 1.0)
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1", "party3" }, {}, IMP, 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party2", filtered, 2.0, 1.0, false, {})
        fw.eq(result, true, "BR suppression fires because party3 (remote warrior) pressed BR")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 10: Local warrior cancels BR early — must commit BR, not be suppressed as GT
--
-- When the local warrior presses BR, all party members (including the warrior) receive
-- a concurrent IMPORTANT aura.  A GT shaman in the group also gets the BR buff.
-- The AoE concurrent-start signal fires (confirmedAoeEvent=true) but the warrior's
-- cast evidence (384100 → BR rule, CanCancelEarly, within 10s) must override GT's
-- AoE heuristic so the warrior commits BR, not nil.
--
-- Additionally, the shaman's BR spillover must be suppressed even after the warrior has
-- left candidateUnits, because casterCastSpellId=384100 in the snapshot is enough proof.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Local warrior cancels BR early: commits BR (not suppressed as GT)", function()
    fw.before_each(reset)

    fw.it("warrior (player) with BR cast commits BR at 3.4s even when GT shaman in group", function()
        -- Concurrent IMPORTANT starts (BR AoE) produce confirmedAoeEvent=true.
        -- GT config's strictAoeCheck=false would normally trust the AoE signal and suppress.
        -- The warrior's cast evidence (384100 → BR rule, CanCancelEarly, 3.4<=10.5) must
        -- return false from IsProbablyGroundingTotem before the candidate scan reaches the shaman.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "WARRIOR")
        mods.talents._setSpec("player", 71)   -- Arms
        mods.talents._setTalent("player", 5702, true)  -- Beserker Roar
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)  -- Grounding Totem
        -- Shaman got a concurrent IMPORTANT aura (BR is AoE) -> confirmedAoeEvent fires for player.
        B._TestSetImportantAuraStart("party1", 1.0)
        local entry    = loader.makeEntry("player")
        local castSnap = { ["player"] = { { SpellId = 384100, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 3.4, { "party1" })
        fw.not_nil(rule, "BR must commit for warrior even with GT shaman and confirmedAoeEvent")
        fw.eq(rule and rule.SpellId, 1227751, "SpellId must be Beserker Roar (1227751)")
    end)

    fw.it("warrior commits BR at 3.4s when shaman has no concurrent aura (no confirmedAoeEvent)", function()
        -- Baseline: without AoE signal the warrior should also commit correctly.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "WARRIOR")
        mods.talents._setSpec("player", 71)
        mods.talents._setTalent("player", 5702, true)
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)
        -- No B._TestSetImportantAuraStart -> confirmedAoeEvent=false.
        local entry    = loader.makeEntry("player")
        local castSnap = { ["player"] = { { SpellId = 384100, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 3.4, { "party1" })
        fw.not_nil(rule, "BR must commit for warrior (no confirmedAoeEvent case)")
        fw.eq(rule and rule.SpellId, 1227751, "SpellId must be Beserker Roar")
    end)

    fw.it("shaman BR spillover suppressed via casterCastSpellId even when warrior has left candidates", function()
        -- Warrior pressed BR (cast 384100 in snapshot captured at aura start).
        -- Warrior has since left candidateUnits (empty list).
        -- casterCastSpellId=384100 in brSpilloverCfg matches the snapshot -> suppressed.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "WARRIOR")
        mods.talents._setTalent("player", 5702, true)
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)
        -- Warrior also had a concurrent IMPORTANT aura start (BR AoE).
        B._TestSetImportantAuraStart("player", 1.0)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 384100, Time = 1.0 } } }
        -- empty candidateUnits: warrior has left the group / is no longer watched
        local t   = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 3.0, {})
        fw.is_nil(rule, "Shaman's spillover must be suppressed via casterCastSpellId when warrior absent")
    end)

    fw.it("shaman BR spillover suppressed when warrior still in candidates", function()
        -- Normal case: warrior in candidates -> candidate scan suppresses.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "WARRIOR")
        mods.talents._setTalent("player", 5702, true)
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)
        B._TestSetImportantAuraStart("player", 1.0)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 384100, Time = 1.0 } } }
        local t   = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 3.0, { "player" })
        fw.is_nil(rule, "Shaman's spillover must be suppressed when warrior is still in candidates")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 11: Remote warrior cancels BR — own aura must commit as BR (not Spell Reflect)
--
-- When a remote warrior presses BR (AoE event: multiple units receive concurrent IMPORTANT
-- auras), and then cancels their own BR buff early, the warrior's own short IMPORTANT aura
-- must be committed as Beserker Roar (1227751), not Spell Reflect (23920).
--
-- Two-stage fix:
--   1) IsProbablyBeserkerRoar returns true for the warrior caster when concurrent AoE starts
--      are detected (suppresses the normal MatchRule path, which would commit Spell Reflect
--      first because spec rules are iterated before class rules).
--   2) FindBestCandidate's searchNonExternal, after IsProbablyBeserkerRoar returns true,
--      detects the warrior caster case and commits the BR rule directly via FindRuleBySpellId.
--
-- From the local player's perspective (warrior is remote, no cast snapshot available):
--   * player=shaman, party2=warrior with BR talent
--   * BR pressed at t=1.0 → both get concurrent IMPORTANT auras → count>0
--   * Warrior self-cancels their BR buff at 1.73s → warrior's aura ends, shaman's persists
--   * Commit must record BR (1227751) for the warrior, not Spell Reflect (23920).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Remote warrior self-cancels BR: own aura commits as BR (not Spell Reflect)", function()
    fw.before_each(reset)

    local function setupShamanObserverWarriorBR()
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "SHAMAN")
        mods.talents._setTalent("player", 3620, true)   -- GT (shaman is local player)
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setSpec("party2", 71)             -- Arms
        mods.talents._setTalent("party2", 5702, true)   -- Beserker Roar
        mods.talents._setTalent("party2", 23920, true)  -- Spell Reflect (warrior has talent)
    end

    fw.it("warrior's own aura commits as BR when concurrent AoE starts detected (self-cancel case)", function()
        -- BR pressed: player (shaman) also received IMPORTANT aura at same time (concurrent start).
        -- Warrior self-cancels their own BR buff at 1.73s (shaman's persists).
        -- The commit-path warrior-caster special case looks up BR via FindRuleBySpellId(384100)
        -- so BR (1227751) is recorded instead of Spell Reflect (23920) — keeps cooldown tracking.
        setupShamanObserverWarriorBR()
        B._TestSetImportantAuraStart("player", 1.0)   -- shaman got BR buff concurrently
        local entry = loader.makeEntry("party2")
        local t     = makeTracked(IMP, 1.0, {}, nil, {})
        local rule, unit = B:FindBestCandidate(entry, t, 1.73, { "player" })
        fw.not_nil(rule, "Warrior's own aura must commit as BR for the observer to track the cooldown")
        fw.eq(rule and rule.SpellId, 1227751, "SpellId must be Beserker Roar (1227751), not Spell Reflect (23920)")
        fw.eq(unit, "party2", "Warrior (party2) must be the attributed caster")
    end)

    fw.it("IsProbablyBeserkerRoar returns true for warrior when concurrent starts detected", function()
        -- Direct API test for the HasCasterTalent + concurrent starts path.
        setupShamanObserverWarriorBR()
        B._TestSetImportantAuraStart("player", 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party2", {}, 1.73, 1.0, false, {})
        fw.eq(result, true, "BR suppression must fire for warrior caster when concurrent AoE starts detected")
    end)

    fw.it("warrior's own aura NOT suppressed when no concurrent starts (solo Spell Reflect press)", function()
        -- No concurrent starts: warrior pressed Spell Reflect individually (not BR).
        -- HasCasterTalent=true but count=0 → fall through → SR commits normally.
        setupShamanObserverWarriorBR()
        -- No B._TestSetImportantAuraStart -> count=0
        local result = B:IsProbablyBeserkerRoar(IMP, "party2", {}, 1.73, 1.0, false, {})
        fw.eq(result, false, "Warrior's solo Spell Reflect must NOT be suppressed by BR check")
    end)

    fw.it("warrior's own aura NOT suppressed when startTime=nil (predict path before AoE evidence)", function()
        -- At predict time startTime may be nil for the first tick.
        -- nil startTime → concurrent check skipped → fall through → returns false (legacy behavior).
        setupShamanObserverWarriorBR()
        B._TestSetImportantAuraStart("player", 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party2", {}, nil, nil, false, {})
        fw.eq(result, false, "Warrior's aura not suppressed at predict time when startTime=nil")
    end)

    fw.it("shaman's own BR spillover still suppressed normally even when warrior is party2", function()
        -- Shaman (player) receives BR spillover from warrior (party2) in candidates.
        -- This is the normal spillover path (not the HasCasterTalent path for the warrior).
        setupShamanObserverWarriorBR()
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry = loader.makeEntry("player")
        local t     = makeTracked(IMP, 1.0, {}, nil, {})
        local rule  = B:FindBestCandidate(entry, t, 1.73, { "party2" })
        fw.is_nil(rule, "Shaman's BR spillover must be suppressed with warrior in candidates")
    end)
end)
