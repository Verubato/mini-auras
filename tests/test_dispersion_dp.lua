-- Tests for Dispersion vs Desperate Prayer disambiguation on Shadow Priest (spec 258).
--
-- Bug: SpecDurationModifiers[258][453729] added +2s to Dispersion's expectedDuration on top
-- of the variant rule (BuffDuration=8, RequiresTalent=453729) that already accounts for
-- Heightened Alteration.  This doubled the bonus: expectedDuration = 10s instead of 8s.
-- With CanCancelEarly, durationOk = (measuredDuration <= 10 + 1.5 = 11.5), so a 9.9s
-- Desperate Prayer matched Dispersion (BySpec[258], checked first) instead of falling
-- through to Desperate Prayer in ByClass["PRIEST"].
--
-- Fix: removed the SpecDurationModifier entry for Dispersion from spec 258.  The variant
-- rule (BuffDuration=8, RequiresTalent=453729) is the sole source of the 8s expected
-- duration, and GetUnitBuffDuration now returns 8 for that rule instead of 10.
--
-- Scenario: shaman (local player) watching a Shadow Priest (party1) in a PvE group.
-- party1 has no cast ID evidence (RecordCast no-op for non-player in 12.0.5).
-- Synthetic Cast is granted (not arena) so both Dispersion and Desperate Prayer are
-- candidates.  Duration at removal is the only disambiguating signal.

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 9001   -- distinct from all other test files

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Builds a watcher for a BIG_DEFENSIVE + IMPORTANT aura, optionally also CC.
-- Dispersion is both BIG+IMP and CROWD_CONTROL; Desperate Prayer is BIG+IMP only.
local function makeBigImpWatcher(unit, isCrowdControl)
    wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
    if isCrowdControl then
        -- Mark as HARMFUL|CROWD_CONTROL (not filtered = present).
        wow.setAuraFiltered(unit, AURA_ID, "HARMFUL|CROWD_CONTROL", false)
    end
    -- Default for HARMFUL|CROWD_CONTROL is filtered-out (not CC) when isCrowdControl is false.
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

-- Run a full predict + commit cycle for party1 (Shadow Priest seen from outside).
-- No cast is fired: simulates 12.0.5 third-party observer with no cast ID evidence.
-- Synthetic Cast is granted because instanceType is not arena.
-- isDispersion: true when the aura is Dispersion (CC), false when it is Desperate Prayer.
local function runCycle(hasTalent, durationSeconds, isDispersion)
    wow.setInstanceType("none")   -- PvE group: allowSyntheticCast=true
    wow.setUnitClass("party1", "PRIEST")
    mods.talents._setSpec("party1", 258)
    if hasTalent then
        mods.talents._setTalent("party1", 453729, true)  -- Heightened Alteration
    end

    local glowed    = nil
    local committed = nil
    B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)
    B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

    wow.setTime(0)
    -- No _fireCast: third-party observer has no cast ID for party1 in 12.0.5 mode.

    local entry   = loader.makeEntry("party1")
    local watcher = makeBigImpWatcher("party1", isDispersion)
    observer:_fireAuraChanged(entry, watcher, { "party1" })

    wow.advanceTime(durationSeconds)
    observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

    return glowed, committed
end

fw.describe("Dispersion vs Desperate Prayer disambiguation (Shadow Priest, 3rd-party view)", function()
    fw.before_each(reset)

    -- Dispersion aura (CC=true): both predict and commit resolve correctly via CROWD_CONTROL type.

    fw.it("Dispersion (CC aura, 6s): predicts and commits as Dispersion (47585)", function()
        local glowed, committed = runCycle(false, 6.0, true)
        fw.eq(glowed,     47585, "Dispersion must be predicted (CC aura type matches)")
        fw.eq(committed,  47585, "Dispersion must be committed at 6.0s")
    end)

    fw.it("Dispersion + HA (CC aura, 8s): predicts and commits as Dispersion (47585)", function()
        local glowed, committed = runCycle(true, 8.0, true)
        fw.eq(glowed,     47585, "Dispersion must be predicted with HA talent")
        fw.eq(committed,  47585, "Dispersion must be committed at 8.0s with HA talent")
    end)

    fw.it("Dispersion early cancel (CC aura, 4s): predicts and commits as Dispersion (47585)", function()
        local glowed, committed = runCycle(true, 4.0, true)
        fw.eq(glowed,     47585, "Dispersion must be predicted (CC)")
        fw.eq(committed,  47585, "Dispersion early cancel at 4.0s must commit as Dispersion")
    end)

    -- Desperate Prayer aura (CC=false): CC type absent, Dispersion rule skipped.

    fw.it("Desperate Prayer (non-CC aura, 10s): predicts and commits as DP (19236)", function()
        local glowed, committed = runCycle(false, 10.0, false)
        fw.eq(glowed,     19236, "Desperate Prayer must be predicted (no CC = Dispersion rule skipped)")
        fw.eq(committed,  19236, "Desperate Prayer must be committed at 10.0s")
    end)

    fw.it("Desperate Prayer with HA known (non-CC, 9.9s): predicts and commits as DP (19236)", function()
        -- With HA talent known, Dispersion (8s variant, CrowdControl=true) still requires CC.
        -- Since DP aura has no CC type, Dispersion is skipped and DP commits correctly.
        local glowed, committed = runCycle(true, 9.9, false)
        fw.eq(glowed,     19236, "Desperate Prayer must be predicted even when HA is known")
        fw.eq(committed,  19236, "Desperate Prayer must be committed at 9.9s even with HA talent known")
        fw.neq(committed, 47585, "Dispersion must NOT be committed")
    end)
end)
