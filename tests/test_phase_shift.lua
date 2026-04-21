-- Tests for Phase Shift (Priest PvP talent) false positives.
--
-- Phase Shift: pressing Fade applies a 1-second IMPORTANT-only self-buff on the Priest.
-- Because it is an IMPORTANT-only aura and many rules have CanCancelEarly=true with no
-- MinCancelDuration, Brain can incorrectly predict or commit those spells when the 1-second
-- aura disappears.
--
-- Key rule that is vulnerable:
--   Blessing of Freedom (class PALADIN): Important=true, ExternalDefensive=false,
--   BigDefensive=false, CanCancelEarly=true, RequiresEvidence="Cast", BuffDuration=8.
--   In 12.0.5 mode every Paladin candidate receives synthetic Cast, so a 1-second IMPORTANT
--   aura removal on any player with a Paladin in the group fires durationOk (1 <= 8.15) and
--   incorrectly commits BoF.
--
-- Already handled correctly:
--   Divine Hymn (spec 257): MinCancelDuration=1.5 rejects 1-second measurements.

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 7001   -- distinct from all other test files

local IMP = { IMPORTANT = true }

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Aura appears on party1 as IMPORTANT-only (Phase Shift).
local function makePhaseShiftWatcher()
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

-- Simulate a full Phase Shift cycle: aura appears then disappears after 1 second.
-- Returns whatever the cooldownCallback captured.
local function runPhaseShiftCycle(entry, candidates)
    local committed = nil
    B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

    wow.setTime(0)
    observer:_fireAuraChanged(entry, makePhaseShiftWatcher(), candidates)

    wow.advanceTime(1.0)
    observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), candidates)

    return committed
end

-- ── Blessing of Freedom false-positive tests ─────────────────────────────────

fw.describe("Phase Shift - Blessing of Freedom false positives", function()
    fw.before_each(reset)

    fw.it("1s IMPORTANT aura should NOT predict BoF when Paladin is in group", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)   -- Holy Priest
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)    -- Holy Paladin

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makePhaseShiftWatcher(), { "party1", "party2" })

        fw.neq(glowed, 1044, "Phase Shift should not predict Blessing of Freedom")
    end)

    fw.it("1s IMPORTANT aura removal should NOT commit BoF when Paladin is in group", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)   -- Holy Priest
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)    -- Holy Paladin

        local entry     = loader.makeEntry("party1")
        local committed = runPhaseShiftCycle(entry, { "party1", "party2" })

        fw.neq(committed, 1044, "Phase Shift 1s removal should not commit Blessing of Freedom")
    end)

    fw.it("1s IMPORTANT aura removal should NOT commit BoF for any Paladin spec", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)

        for _, palSpec in ipairs({ 65, 66, 70 }) do   -- Holy, Prot, Ret
            reset()
            wow.setUnitClass("party1", "PRIEST")
            mods.talents._setSpec("party1", 257)
            wow.setUnitClass("party2", "PALADIN")
            mods.talents._setSpec("party2", palSpec)

            local entry     = loader.makeEntry("party1")
            local committed = runPhaseShiftCycle(entry, { "party1", "party2" })

            fw.neq(committed, 1044,
                "Phase Shift should not commit BoF for Paladin spec " .. palSpec)
        end
    end)

    -- Sanity: a legitimate full-duration BoF (8s) should still commit.
    fw.it("Legitimate BoF at full duration still commits", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")   -- BoF target (not Paladin)
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        -- BoF aura appears on party1 (IMPORTANT-only, party2 is the caster)
        local entry   = loader.makeEntry("party1")
        local watcher = loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
        wow.setTime(0)
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        -- Full 8s duration
        wow.advanceTime(8.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1", "party2" })

        fw.eq(committed, 1044, "Legitimate BoF at 8s should still commit")
    end)

    -- Sanity: a legitimate BoF cancelled at 4s (early cancel) should still commit.
    fw.it("BoF cancelled at 4s (early cancel) still commits", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        local entry   = loader.makeEntry("party1")
        local watcher = loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
        wow.setTime(0)
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        wow.advanceTime(4.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1", "party2" })

        fw.eq(committed, 1044, "BoF cancelled at 4s should still commit (early cancel)")
    end)
end)

-- ── Divine Hymn guard (MinCancelDuration already in place) ───────────────────

fw.describe("Phase Shift - Divine Hymn MinCancelDuration guard", function()
    fw.before_each(reset)

    fw.it("1s IMPORTANT aura removal does NOT commit Divine Hymn (MinCancelDuration=1.5)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)   -- Holy Priest

        local entry     = loader.makeEntry("party1")
        local committed = runPhaseShiftCycle(entry, { "party1" })

        fw.neq(committed, 64843, "Phase Shift 1s should not match Divine Hymn")
    end)

    fw.it("Divine Hymn at MinCancelDuration+0.1 (1.6s) still commits", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        local entry   = loader.makeEntry("party1")
        local watcher = loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
        wow.setTime(0)
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        wow.advanceTime(1.6)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        fw.eq(committed, 64843, "Divine Hymn cancelled at 1.6s should still commit")
    end)
end)
