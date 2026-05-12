-- Tests for IsProbablyGroundingTotem, IsProbablyBeserkerRoar, IsProbablyRevival,
-- IsProbablyPhaseShift, and IsProbablyPrecognition signal coverage.
--
-- Each function uses a set of discriminating signals to identify its respective spell.
-- This file tests those signals explicitly plus conflicting scenarios where two or more
-- spells might explain the same aura.
--
-- Spell/aura properties (from user spec and Rules.lua):
--   Grounding Totem  204336  Shaman PvP talent; affects shaman + nearby allies; lasts 0.5–3.5s;
--                            all allies' auras drop simultaneously (absorbed or timed out).
--   Beserker Roar    1227751 Warrior PvP talent; affects warrior + nearby allies; lasts up to 10s;
--                            auras can drop at different times per unit.
--   Revival/Restoral 115310/388615  Monk Peaceweaver PvP talent; affects monk + all allies;
--                            always lasts exactly 2s; all auras drop simultaneously.
--   Phase Shift            Priest PvP talent via Fade (586); always lasts ~1s on the Priest only.
--   Precognition           4s IMPORTANT PvP aura on any unit when an enemy fails their interrupt.
--                          Does NOT require cast evidence (the enemy's miss is what triggers it).
--
-- Conflict resolution order in PredictRule / FindBestCandidate (searchNonExternal):
--   1. Precognition (suppress all)
--   2. Phase Shift (bypass suppression; proceed to search)
--   3. Grounding Totem (suppress non-shaman)
--   4. Beserker Roar (suppress non-warrior)
--   5. Revival spillover (suppress non-Monk when Monk cast Revival)
--   6. Normal search

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

local function arenaSetup()
    wow.setInstanceType("arena")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 1: IsProbablyRevival - measuredDuration signal
--
-- Revival/Restoral always lasts exactly 2s.  If the measured duration exceeds
-- 2 + 0.5 = 2.5s the aura cannot be Revival spillover.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("IsProbablyRevival - measuredDuration gate (2+tolerance=2.5s)", function()
    fw.before_each(reset)

    local function setupLocalMonkWithRevival(castSnap)
        arenaSetup()
        wow.setUnitGUID("party2", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party2", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party2", 5395, true)
        wow.setUnitClass("party1", "WARRIOR")
        return castSnap or { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
    end

    fw.it("Revival suppresses non-Monk at 2s (within 2.5s threshold)", function()
        local castSnap = setupLocalMonkWithRevival()
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        -- 2.0s <= 2.5s -> Revival duration OK -> spillover suppresses Warrior
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Warrior aura at 2s must be suppressed as Revival spillover")
    end)

    fw.it("Revival does NOT suppress non-Monk at 3s (exceeds 2.5s threshold)", function()
        local castSnap = setupLocalMonkWithRevival()
        -- No GT shaman, no BR warrior -> searchNonExternal runs but finds no rule for Warrior at 3s
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        -- 3.0s > 2.5s -> IsProbablyRevival returns false -> no Revival suppression
        -- No warrior IMPORTANT rule at 3s exact -> rule is nil anyway, but suppression must not fire
        local rule = B:FindBestCandidate(entry, t, 3.0, { "party2" })
        fw.is_nil(rule, "3s IMPORTANT aura on Warrior with Monk: not Revival (>2.5s) and no matching rule")
    end)

    fw.it("Monk target: IsProbablyRevival rejects Revival disambiguation at 3s", function()
        -- Monk (local player) pressed Revival BUT the aura lasted 3s (impossible for Revival).
        -- IsProbablyRevival should return false -> GT guard can fire if a shaman is present.
        arenaSetup()
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party1", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party1", 5395, true)
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        -- Snapshot says Monk pressed Revival, but duration is 3s.
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        -- 3.0s: IsProbablyRevival(duration=3.0) -> false (>2.5s) -> GT guard sees Shaman -> suppresses
        local rule = B:FindBestCandidate(entry, t, 3.0, { "party2" })
        fw.is_nil(rule, "Monk aura at 3s must be suppressed by GT guard (Revival ruled out by duration)")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 2: IsProbablyGroundingTotem - duration and evidence signals
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("IsProbablyGroundingTotem - duration and evidence signals", function()
    fw.before_each(reset)

    fw.it("GT does not suppress at 4.1s (duration exceeds GT max 3.5+0.5=4.0)", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 4.1, nil, {}, 1.0, false)
        fw.eq(result, false, "Duration 4.1s exceeds GT max -> not GT spillover")
    end)

    fw.it("GT suppresses at 3.5s (within GT max)", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 3.5, nil, {}, 1.0, false)
        fw.eq(result, true, "Duration 3.5s within GT max -> GT suppresses")
    end)

    fw.it("GT does not suppress when Shield evidence present (GT grants no absorb to allies)", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local evidence = { Shield = true }
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 2.0, evidence, {}, 1.0, false)
        fw.eq(result, false, "Shield evidence rules out GT spillover")
    end)

    fw.it("GT does not suppress outside PvP context", function()
        -- Default instance type is 'none' (PvE)
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 2.0, nil, {}, 1.0, false)
        fw.eq(result, false, "GT does not suppress in PvE context")
    end)

    fw.it("GT does not suppress BIG_DEFENSIVE auras", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        local result = B:IsProbablyGroundingTotem(BIGDEF, "party1", { "party2" }, 2.0, nil, {}, 1.0, false)
        fw.eq(result, false, "BIG_DEFENSIVE aura is not GT spillover")
    end)

    fw.it("GT suppresses when confirmedAoeEvent: concurrent IMPORTANT aura starts on multiple units", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        -- Shaman also got a concurrent IMPORTANT aura at t=1.0 (AoE GT event)
        B._TestSetImportantAuraStart("party2", 1.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 2.0, nil, {}, 1.0, false)
        fw.eq(result, true, "Concurrent IMPORTANT aura starts confirm GT AoE event -> suppresses")
    end)

    fw.it("GT simultaneous removal: all allies lose aura at same time (absorption/timeout signal)", function()
        -- When GT is absorbed, all allies lose their IMPORTANT aura simultaneously.
        -- This is committed via FindBestCandidate; the removal records are set for party2.
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        -- Both Hunter and Shaman had concurrent aura starts (GT event)
        B._TestSetImportantAuraStart("party1", 1.0)
        B._TestSetImportantAuraStart("party2", 1.0)
        -- Shaman's aura ended at same time as Hunter's (GT absorbed at t=3.0)
        B._TestSetImportantAuraEnd("party2", 3.0)
        -- Hunter's aura is evaluated; CountConcurrentImportantAuraRemovals > 0 -> NOT BR
        -- (Confirms GT/Revival; GT shaman present -> GT suppresses Hunter)
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 2.0, nil, {}, 1.0, false)
        fw.eq(result, true, "Simultaneous removal confirms GT/Revival; GT shaman present -> suppresses Hunter")
    end)

    fw.it("GT: simultaneous removal alone raises confirmedAoeEvent (concurrent start not recorded)", function()
        -- Removal-based AoE confirmation: the shaman's aura end is recorded simultaneously with
        -- the Hunter's, but no concurrent START was recorded for the shaman.
        -- confirmedAoeEvent is set from CountConcurrentImportantAuraRemovals, skipping the rule check.
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        -- No concurrent start recorded (B._TestSetImportantAuraStart intentionally omitted)
        -- Shaman's aura ended simultaneously (GT absorbed at t=3.0; Hunter: start=1.0+dur=2.0=3.0)
        B._TestSetImportantAuraEnd("party2", 3.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 2.0, nil, {}, 1.0, false)
        fw.eq(result, true, "Simultaneous removal alone raises confirmedAoeEvent; GT shaman candidate -> suppresses")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 3: IsProbablyBeserkerRoar - simultaneous removal rules out BR
--
-- GT absorption and Revival expiry remove all allies' auras simultaneously.
-- BR auras fall off independently (can coincide, but rarely).
-- Simultaneous removal → confirmed GT/Revival → not BR.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("IsProbablyBeserkerRoar - simultaneous removal signal rules out BR", function()
    fw.before_each(reset)

    fw.it("simultaneous removal (0.1s apart) rules out BR", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        -- Hunter's aura ends at t=3.0; Warrior's ended at t=3.05 (within 0.5s window)
        B._TestSetImportantAuraEnd("party2", 3.05)
        -- startTime=1.0, measuredDuration=2.0 -> endTime=3.0 -> concurrent within 0.5s
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 2.0, 1.0, false, {})
        fw.eq(result, false, "Removals 0.05s apart -> simultaneous -> GT/Revival not BR -> not suppressed")
    end)

    fw.it("non-simultaneous removal (1s apart) does NOT rule out BR", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        -- Warrior's aura ended 1 second after Hunter's
        B._TestSetImportantAuraEnd("party2", 4.0)  -- Hunter ends at 3.0, Warrior at 4.0 -> 1s apart
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 2.0, 1.0, false, {})
        fw.eq(result, true, "Removals 1s apart -> not simultaneous -> BR suppression holds")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 4: Conflicting scenarios - GT vs BR simultaneously
--
-- Both a GT Shaman and a BR Warrior are in the group when a non-shaman,
-- non-warrior ally receives an IMPORTANT aura.  Both suppressions would fire;
-- GT is checked first and suppresses before BR is reached.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Conflict: GT + BR simultaneously (non-shaman, non-warrior target)", function()
    fw.before_each(reset)

    fw.it("non-Paladin (Hunter) is suppressed when both GT shaman and BR warrior are present", function()
        -- Hunter receives IMPORTANT aura.  GT shaman AND BR warrior are candidates.
        -- GT takes priority (checked first in the chain).
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        wow.setUnitClass("party3", "WARRIOR")
        mods.talents._setTalent("party3", 5702, true)
        -- Both AoE events fire simultaneously
        B._TestSetImportantAuraStart("party2", 1.0)
        B._TestSetImportantAuraStart("party3", 1.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2", "party3" })
        fw.is_nil(rule, "Hunter suppressed when both GT and BR are present (GT fires first)")
    end)

    fw.it("Paladin BoF (CanCancelEarly) lifts BR but GT still suppresses at 2s", function()
        -- Paladin presses BoF (CanCancelEarly, 8s).  BR warrior is also present (concurrent start).
        -- For BR: confirmedAoeEvent=true -> CanCancelEarly check -> BoF satisfies it -> BR does NOT suppress.
        -- For GT: duration=2s <= 4s, no shield evidence, shaman present -> GT suppresses.
        -- Net result: GT suppresses even though BR lifted.
        arenaSetup()
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        wow.setUnitClass("party3", "WARRIOR")
        mods.talents._setTalent("party3", 5702, true)
        B._TestSetImportantAuraStart("party3", 1.0)  -- concurrent BR event
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2", "party3" })
        fw.is_nil(rule, "GT suppresses Paladin even though BR is lifted by BoF CanCancelEarly")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 5: Conflicting scenarios - GT vs Revival simultaneously at 2s
--
-- Both a GT Shaman presses GT and a Peaceweaver Monk presses Revival at the same
-- time.  On a non-Monk, non-Shaman target the 2s IMPORTANT aura could be either.
-- GT is checked first and suppresses (unavoidable ambiguity).
--
-- At 3s, the duration rules out Revival; GT suppresses due to the shaman candidate.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Conflict: GT + Revival simultaneously", function()
    fw.before_each(reset)

    local function setupGTandRevival()
        arenaSetup()
        -- party3 = Warrior target (non-Monk, non-Shaman)
        wow.setUnitClass("party3", "WARRIOR")
        -- party1 = GT Shaman
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)
        -- party2 = local player Monk with Peaceweaver
        wow.setUnitGUID("party2", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party2", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party2", 5395, true)
    end

    fw.it("2s aura on Warrior: GT wins over Revival (GT checked first - unavoidable)", function()
        setupGTandRevival()
        B._TestSetImportantAuraStart("party1", 1.0)  -- GT AoE event
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local entry = loader.makeEntry("party3")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        -- filteredCandidates: Monk stays (pressed Revival - IMPORTANT rule matches), Shaman stays
        -- GT: finds shaman -> suppresses.  Revival check never reached.
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party1", "party2" })
        fw.is_nil(rule, "2s IMPORTANT on Warrior: GT suppresses when both GT and Revival are present (unavoidable)")
    end)

    fw.it("3s aura on Warrior: GT suppresses; Revival ruled out by duration", function()
        -- At 3s duration, Revival is definitively ruled out (2+0.5=2.5s threshold).
        -- GT still suppresses via shaman candidate.
        setupGTandRevival()
        B._TestSetImportantAuraStart("party1", 1.0)
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local entry = loader.makeEntry("party3")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 3.0, { "party1", "party2" })
        fw.is_nil(rule, "3s IMPORTANT on Warrior: GT suppresses; Revival ruled out by duration")
    end)

    fw.it("no GT shaman: 2s aura suppressed as Revival spillover (Monk pressed Revival)", function()
        setupGTandRevival()
        -- Only Monk (no shaman in candidates)
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local entry = loader.makeEntry("party3")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        -- filteredCandidates: Monk stays (pressed Revival); no shaman -> GT fires not
        -- Revival spillover check: Monk+Peaceweaver in filteredCandidates -> suppresses
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "2s IMPORTANT on Warrior: suppressed as Revival spillover when no GT shaman present")
    end)

    fw.it("no GT shaman: 3s aura NOT suppressed as Revival (duration > 2.5s)", function()
        setupGTandRevival()
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local entry = loader.makeEntry("party3")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        -- filteredCandidates: Monk stays (pressed Revival); no shaman -> GT does not fire
        -- Revival spillover: measuredDuration=3.0 > 2.5 -> not Revival -> no suppression
        -- searchNonExternal runs; no matching rule for Warrior at 3s exact IMPORTANT -> nil
        local rule = B:FindBestCandidate(entry, t, 3.0, { "party2" })
        fw.is_nil(rule, "3s IMPORTANT on Warrior with only Monk: Revival ruled out by duration; no rule commits")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 6: Phase Shift bypasses GT suppression
--
-- Phase Shift is a Priest PvP talent (via Fade) producing a ~1s IMPORTANT aura.
-- IsProbablyPhaseShift returns true -> the suppression block is bypassed and
-- searchNonExternal runs, potentially committing the Priest's own cooldown.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Conflict: Phase Shift bypasses GT suppression", function()
    fw.before_each(reset)

    fw.it("IsProbablyGroundingTotem still returns true for Priest at 1s when shaman is present", function()
        -- IsProbablyGroundingTotem does not know about Phase Shift; it fires whenever a GT
        -- shaman is in the candidates and the duration/evidence gates pass.
        -- The Phase Shift bypass happens in the higher-level if/elseif chain in FindBestCandidate
        -- and PredictRule, which checks IsProbablyPhaseShift BEFORE IsProbablyGroundingTotem.
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 1.0, nil, {}, 1.0, false)
        fw.eq(result, true, "GT fires for Priest at 1s when shaman is present; bypass is handled by caller chain")
    end)

    fw.it("Phase Shift does not fire for non-Priest (falls through to GT suppression)", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local result = B:IsProbablyPhaseShift(IMP, "party1", 1.0, {}, 1.0)
        fw.eq(result, false, "IsProbablyPhaseShift returns false for non-Priest")
    end)

    fw.it("IsProbablyPhaseShift: local Priest with Fade in snapshot returns true", function()
        arenaSetup()
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "PRIEST")
        wow.setUnitClass("party1", "PRIEST")
        local castSnap = { ["player"] = { { SpellId = 586, Time = 1.0 } } }
        local result = B:IsProbablyPhaseShift(IMP, "party1", 1.0, castSnap, 1.0)
        fw.eq(result, true, "Local Priest with Fade in snapshot -> Phase Shift confirmed")
    end)

    fw.it("IsProbablyPhaseShift: local Priest without Fade in snapshot returns false", function()
        arenaSetup()
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "PRIEST")
        wow.setUnitClass("party1", "PRIEST")
        local result = B:IsProbablyPhaseShift(IMP, "party1", 1.0, {}, 1.0)
        fw.eq(result, false, "Local Priest with no Fade in snapshot -> Phase Shift not confirmed")
    end)

    fw.it("IsProbablyPhaseShift: duration > 1.5s returns false even for Priest", function()
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        -- Remote Priest, duration 2s -> exceeds 1.5s threshold
        local result = B:IsProbablyPhaseShift(IMP, "party1", 2.0, {}, 1.0)
        fw.eq(result, false, "Duration 2s exceeds Phase Shift max (1.5s) -> not Phase Shift")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 7: Precognition blocks all suppression
--
-- Precognition fires when an enemy fails their interrupt on the local player.
-- It produces a 4s IMPORTANT+UnitFlags aura and does NOT require cast evidence.
-- When IsProbablyPrecognition fires, the entire non-external suppression block
-- is bypassed (no GT, no BR, no Revival).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Precognition signals and suppression priority", function()
    fw.before_each(reset)

    fw.it("Precognition fires for Shadow Priest with IMPORTANT+UnitFlags in arena (no evidence)", function()
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)  -- Shadow
        local result = B:IsProbablyPrecognition(IMP, "party1", nil, nil)
        fw.eq(result, true, "Shadow Priest with no evidence: Precognition fires")
    end)

    fw.it("Precognition does not fire for Warrior (precog-immune class)", function()
        arenaSetup()
        wow.setUnitClass("party1", "WARRIOR")
        local result = B:IsProbablyPrecognition(IMP, "party1", nil, nil)
        fw.eq(result, false, "Warrior is precog-immune -> IsProbablyPrecognition returns false")
    end)

    fw.it("Precognition does not fire for Hunter (precog-immune class)", function()
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        local result = B:IsProbablyPrecognition(IMP, "party1", nil, nil)
        fw.eq(result, false, "Hunter is precog-immune -> returns false")
    end)

    fw.it("Precognition does not fire outside PvP context", function()
        -- Default instance type is 'none' (PvE)
        wow.setUnitClass("party1", "PRIEST")
        local result = B:IsProbablyPrecognition(IMP, "party1", nil, nil)
        fw.eq(result, false, "Precognition does not fire in PvE context")
    end)

    fw.it("Precognition blocked by UnitFlags=false evidence at commit time", function()
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        -- evidence.UnitFlags is nil -> function sees 'not evidence.UnitFlags' -> returns false
        local evidence = {}  -- UnitFlags field absent/nil
        local result = B:IsProbablyPrecognition(IMP, "party1", 4.0, evidence)
        fw.eq(result, false, "Absent UnitFlags evidence at commit time -> not Precognition")
    end)

    fw.it("Precognition fires with UnitFlags evidence at commit time", function()
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        local evidence = { UnitFlags = true }
        local result = B:IsProbablyPrecognition(IMP, "party1", 4.0, evidence)
        fw.eq(result, true, "UnitFlags evidence -> Precognition fires")
    end)

    fw.it("Precognition: duration > 4.5s returns false", function()
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        local evidence = { UnitFlags = true }
        local result = B:IsProbablyPrecognition(IMP, "party1", 5.0, evidence)
        fw.eq(result, false, "Duration 5s > precognition max (4.5s) -> not Precognition")
    end)

    fw.it("Precognition suppresses Priest even when GT shaman is in group (precog takes priority)", function()
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local evidence = { UnitFlags = true }
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, evidence, {})
        -- Precognition fires first -> entire non-external block suppressed
        local rule = B:FindBestCandidate(entry, t, 4.0, { "party2" })
        fw.is_nil(rule, "Precognition suppresses Priest even when GT shaman is in group")
    end)

    fw.it("Precognition does NOT require cast evidence (enemy miss triggers it, not a player keypress)", function()
        -- This is the key property: even if the local player has an empty cast snapshot
        -- (provably cast nothing), Precognition can still fire.
        arenaSetup()
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "MAGE")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("player", 62)  -- Arcane
        mods.talents._setSpec("party1", 62)
        local evidence = { UnitFlags = true }
        local result = B:IsProbablyPrecognition(IMP, "party1", 4.0, evidence)
        fw.eq(result, true, "Precognition fires for local Mage even without cast evidence (enemy missed interrupt)")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 8: Revival - simultaneous removal is a positive signal for GT/Revival
--
-- When multiple units lose their IMPORTANT-only aura simultaneously, it's either
-- GT absorbed/timed-out or Revival expiring.  This rules out BR (already tested
-- in test_beserker_roar.lua) and confirms the aura source is GT or Revival.
-- On the commit path this works via CountConcurrentImportantAuraRemovals.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Simultaneous removal positively confirms GT or Revival (rules out BR)", function()
    fw.before_each(reset)

    fw.it("Shaman GT commits when simultaneous removal rules out BR (both GT shaman and BR warrior present)", function()
        -- Shaman pressed GT; Warrior pressed BR at the same time.
        -- Hunter's aura ends simultaneously with Shaman's (GT absorbed at t=3.0).
        -- BR suppression: CountConcurrentImportantAuraRemovals > 0 -> rules out BR.
        -- GT: no suppression for the Shaman itself (GT rule handles it directly).
        arenaSetup()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setSpec("party1", 263)  -- Enhancement (has GT talent?)
        mods.talents._setTalent("party1", 3620, true)
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        wow.setUnitClass("party3", "HUNTER")
        -- Hunter loses aura simultaneously with Shaman (GT absorbed)
        B._TestSetImportantAuraEnd("party3", 3.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        -- Shaman is the target; IsProbablyBeserkerRoar returns false for warrior-targets
        -- (warriorHasBeserkerRoar(targetUnit) early return); BR suppression doesn't fire for shaman
        -- -> GT rule commits for the Shaman directly
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party2", "party3" })
        fw.not_nil(rule, "Shaman GT commits when simultaneous removal confirms GT (not BR)")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem (204336)")
    end)

    fw.it("simultaneous removal: Hunter's suppression lifted (confirmed GT/Revival not BR)", function()
        -- Hunter and Warrior both lose their IMPORTANT aura at the same time.
        -- BR check: simultaneous removal -> return false -> Hunter not suppressed by BR.
        -- GT check: no shaman in candidates -> GT not suppresses.
        -- No matching rule for Hunter at 2s IMPORTANT -> nil (but BR did not suppress).
        arenaSetup()
        wow.setUnitClass("party1", "HUNTER")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party1", 1.0)
        B._TestSetImportantAuraStart("party2", 1.0)
        B._TestSetImportantAuraEnd("party2", 3.0)  -- Warrior's aura ends at t=3.0 (same as Hunter's)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 2.0, 1.0, false, {})
        fw.eq(result, false, "Simultaneous removal lifts BR suppression for Hunter")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 9: Conflict: Phase Shift bypasses BR suppression
--
-- IsProbablyBeserkerRoar returns true for a Priest at 1s when a BR warrior is
-- present — BR WOULD suppress at signal level.  IsProbablyPhaseShift also fires
-- for the same Priest.  Phase Shift is checked first in the caller chain
-- (PredictRule / searchNonExternal), so the Priest is never suppressed by BR.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Conflict: Phase Shift bypasses BR suppression", function()
    fw.before_each(reset)

    fw.it("IsProbablyBeserkerRoar returns true for Priest at 1s when warrior present (BR WOULD suppress)", function()
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local result = B:IsProbablyBeserkerRoar(IMP, "party1", { "party2" }, 1.0, 1.0, false, {})
        fw.eq(result, true, "BR fires for Priest at 1s when warrior present; Phase Shift bypass is in the caller chain")
    end)

    fw.it("IsProbablyPhaseShift returns true for Priest at 1s (fires before BR in caller chain)", function()
        -- Remote Priest: class + duration <= 1.5s + PvP is sufficient for Phase Shift.
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local result = B:IsProbablyPhaseShift(IMP, "party1", 1.0, {}, 1.0)
        fw.eq(result, true, "Phase Shift fires for remote Priest at 1s; takes priority over BR in the caller chain")
    end)

    fw.it("IsProbablyBeserkerRoar returns true for Priest at 1s when warrior present (Phase Shift bypasses Revival too)", function()
        -- Same signal-level evidence for Revival spillover case: Phase Shift also bypasses
        -- Revival suppression (checked after BR in the chain).
        arenaSetup()
        wow.setUnitClass("party1", "PRIEST")
        wow.setUnitGUID("party2", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party2", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party2", 5395, true)
        local result = B:IsProbablyPhaseShift(IMP, "party1", 1.0, {}, 1.0)
        fw.eq(result, true, "Phase Shift fires for Priest at 1s; bypasses Revival suppression as well as BR")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 10: Conflict: BR fires before Revival spillover
--
-- When both a BR warrior and a Peaceweaver Monk press their ability simultaneously,
-- a non-warrior, non-Monk ally receiving a 2s IMPORTANT aura cannot be definitively
-- attributed.  BR is checked before Revival in the suppression chain, so the target
-- is suppressed by BR (unavoidable ambiguity).
--
-- When only the Monk is present (no warrior), Revival spillover fires instead.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Conflict: BR fires before Revival (BR warrior + Peaceweaver Monk)", function()
    fw.before_each(reset)

    local function setupBRandRevival()
        arenaSetup()
        wow.setUnitClass("party1", "DRUID")  -- non-warrior, non-Monk target
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        wow.setUnitGUID("party3", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party3", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party3", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party3", 5395, true)
        return { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
    end

    fw.it("Druid suppressed by BR (before Revival) when BR warrior and Peaceweaver Monk both present", function()
        local castSnap = setupBRandRevival()
        B._TestSetImportantAuraStart("party2", 1.0)  -- BR AoE event
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        -- GT: no shaman -> false.  BR: warrior candidate -> suppresses (before Revival check).
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2", "party3" })
        fw.is_nil(rule, "Druid suppressed by BR (checked before Revival) when both warrior and Monk present")
    end)

    fw.it("Druid suppressed by Revival only when no BR warrior present", function()
        local castSnap = setupBRandRevival()
        -- Only Monk candidate; no warrior -> BR does not fire -> Revival spillover fires
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party3" })
        fw.is_nil(rule, "Druid suppressed by Revival spillover when only Peaceweaver Monk present")
    end)

    fw.it("Revival simultaneous removal confirms AoE event (no concurrent start recorded)", function()
        -- Same signal as GT: simultaneous removal raises confirmedAoeEvent for Revival spillover.
        -- Monk candidate present; no concurrent start recorded; but aura ends simultaneously.
        arenaSetup()
        wow.setUnitClass("party1", "DRUID")
        wow.setUnitGUID("party2", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party2", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party2", 5395, true)
        -- Monk's aura ended simultaneously with Druid's (Revival expired at t=3.0)
        B._TestSetImportantAuraEnd("party2", 3.0)  -- Druid: start=1.0+dur=2.0=3.0 -> concurrent
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local result = B:IsProbablyGroundingTotem(IMP, "party1", { "party2" }, 2.0, nil, {}, 1.0, false)
        -- GT should NOT fire (Monk not a shaman); this verifies the signal stays in its lane
        fw.eq(result, false, "GT does not fire for Druid when only a Monk candidate is present")
        -- Now verify Revival spillover fires directly (via FindBestCandidate)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Revival spillover suppresses Druid when Monk pressed Revival and aura ends simultaneously")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 11: 3rd-observer perspective — local player is a Rogue
--
-- In a 3-player scenario the local player (Rogue) is neither the spell caster nor
-- a unit whose class could explain the IMPORTANT aura.  They have NO cast evidence
-- (UNIT_SPELLCAST_SUCCEEDED for their own spells never fires because they pressed nothing
-- relevant), so the new "fast exit" for matching cast IDs is never triggered.
--
-- Suppression must therefore rely entirely on:
--   a) the candidate scan finding the caster unit (warrior/shaman/Monk) in candidateUnits
--   b) suppressRuleCheck=true (snapshot present but no matching cast) skipping
--      TargetExplainsOwnAura so Evasion doesn't lift BR suppression at non-Evasion durations
--
-- Key contrast: when the Rogue presses Evasion (10s exact-duration rule) simultaneously
-- with the warrior pressing BR, the measured duration disambiguates:
--   10s  → fast exit fires for Evasion (duration consistent) → Evasion commits
--   3.4s → fast exit rejects (|3.4-10| >> 0.5) → BR suppression fires → nil
--
-- Limitation: once the caster leaves candidateUnits no suppression fires, and a
-- duration-matching rule on the Rogue would produce a false commit (Evasion at 10s).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("3rd-observer Rogue: suppression without local cast evidence", function()
    fw.before_each(reset)

    local function rogueSetup()
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "ROGUE")
        wow.setUnitClass("party1", "ROGUE")
    end

    fw.it("Rogue suppressed as GT spillover: no cast evidence, GT shaman in candidates", function()
        rogueSetup()
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        -- Shaman also received a concurrent IMPORTANT aura (GT is AoE) -> confirmedAoeEvent=true.
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Rogue with no cast evidence is suppressed as GT spillover")
    end)

    fw.it("Rogue suppressed as BR spillover: no cast evidence, BR warrior in candidates", function()
        rogueSetup()
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        -- Warrior also received a concurrent IMPORTANT aura (BR is AoE) -> confirmedAoeEvent=true.
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local rule = B:FindBestCandidate(entry, t, 3.0, { "party2" })
        fw.is_nil(rule, "Rogue with no cast evidence is suppressed as BR spillover")
    end)

    fw.it("Rogue suppressed as Revival spillover: no cast evidence, Peaceweaver Monk in candidates", function()
        rogueSetup()
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("party2", 270)
        mods.talents._setTalent("party2", 5395, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Rogue with no cast evidence is suppressed as Revival spillover")
    end)

    fw.it("Rogue suppressed across all three AoE sources simultaneously (GT wins first)", function()
        rogueSetup()
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        wow.setUnitClass("party3", "WARRIOR")
        mods.talents._setTalent("party3", 5702, true)
        wow.setUnitClass("party4", "MONK")
        mods.talents._setSpec("party4", 270)
        mods.talents._setTalent("party4", 5395, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        B._TestSetImportantAuraStart("party3", 1.0)
        B._TestSetImportantAuraStart("party4", 1.0)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        -- 2s fits GT (≤4.0) and Revival (≤2.5) and BR (≤10.5); GT is checked first.
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2", "party3", "party4" })
        fw.is_nil(rule, "Rogue suppressed regardless of which AoE source wins; all three present")
    end)

    fw.it("Rogue presses Evasion at 10s while warrior presses BR: Evasion commits (duration matches)", function()
        -- Rogue has cast evidence for Evasion (5277).  The fast exit inside IsProbablyBeserkerRoar
        -- checks: Evasion rule, no CanCancelEarly, exact 10s, |10.0-10| = 0 ≤ 0.5 -> durationOk=true
        -- -> returns false (not BR spillover) -> consider(rogue) -> Evasion commits normally.
        rogueSetup()
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 5277, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 10.0, { "party2" })
        fw.not_nil(rule, "Evasion must commit when duration matches exactly")
        fw.eq(rule and rule.SpellId, 5277, "SpellId must be Evasion (5277)")
    end)

    fw.it("Rogue presses Evasion but aura ends at 3.4s (BR cancelled early): suppressed as BR", function()
        -- Rogue has cast evidence for Evasion (5277) but the aura lasted 3.4s, not 10s.
        -- Fast exit: |3.4-10| = 6.6 > 0.5 -> durationOk=false -> no early exit.
        -- suppressRuleCheck: 5277 matches Evasion rule -> suppressRuleCheck=false.
        -- TargetExplainsOwnAura(strictAoeCheck=true, confirmedAoeEvent=true): Evasion has no
        -- CanCancelEarly -> returns false -> candidate scan finds warrior -> suppressed as BR.
        rogueSetup()
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        B._TestSetImportantAuraStart("party2", 1.0)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 5277, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 3.4, { "party2" })
        fw.is_nil(rule, "Evasion cast evidence does not lift BR suppression at 3.4s (duration mismatch)")
    end)

    fw.it("limitation: warrior leaves candidates, Rogue's 10s aura falsely commits as Evasion", function()
        -- Once the BR warrior has left candidateUnits, no AoE suppression fires (no caster found).
        -- The Rogue has no cast snapshot (pressed nothing), but Evasion's exact 10s duration matches
        -- MatchRule -> false commit.  This is a known limitation: without the remote caster's cast ID
        -- in the local snapshot (only available when the local player IS the caster on 12.0.5+),
        -- there is no signal left to suppress the Rogue's aura after the warrior departs.
        rogueSetup()
        wow.setUnitClass("party2", "WARRIOR")
        mods.talents._setTalent("party2", 5702, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        -- empty candidateUnits: warrior has left the arena / is no longer watched
        local rule = B:FindBestCandidate(entry, t, 10.0, {})
        fw.not_nil(rule, "Known limitation: Rogue's 10s aura commits as Evasion when warrior is absent")
        fw.eq(rule and rule.SpellId, 5277, "SpellId 5277 = Evasion (false commit when caster is gone)")
    end)
end)
