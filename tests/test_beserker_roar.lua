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
        -- Paladin's Blessing of Freedom (8s, CanCancelEarly, Important, no RequiresTalent)
        -- is a legitimate explanation for the aura.  Even with a co-occurring warrior aura
        -- (BR event confirmed), hasMatchingEarlyCancelRule finds BoF and lifts suppression.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)  -- warrior also has concurrent aura (BR event)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 3.0, 1.0)
        fw.eq(result, false, "BoF (no RequiresTalent) lifts BR suppression for Paladin even in BR event")
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
        -- Co-occurrence passes, but hasMatchingEarlyCancelRule finds Spell Reflect (CanCancelEarly)
        -- -> return false (not suppressed) -> Spell Reflect commits via FindBestCandidate.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 71)  -- Arms
        mods.talents._setTalent("party1", 23920, true)  -- Spell Reflect
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)  -- BR caster
        B._TestSetImportantAuraStart("party2", 1.0)  -- warrior also received IMPORTANT aura (BR event)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- Duration 3.0: within Spell Reflect (5s CanCancelEarly, <= 5.5)
        local rule, unit = B:FindBestCandidate(entry, t, 3.0, { "party2" })
        fw.not_nil(rule, "Spell Reflect should commit - CanCancelEarly lifts suppression even in BR event")
        fw.eq(rule and rule.SpellId, 23920, "SpellId should be Spell Reflect (23920)")
        fw.eq(unit, "party1", "party1 warrior is the caster")
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
-- When BR fires simultaneously (count>0, confirmed AoE event): hasMatchingEarlyCancelRule
-- does not find Doomwinds (no CanCancelEarly) -> BR suppression fires (known limitation,
-- extremely rare in practice).
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
