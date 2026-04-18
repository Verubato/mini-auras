-- Tests for PredictRule 12.0.5 PvE synthetic cast re-enablement.
--
-- On 12.0.5, UNIT_SPELLCAST_SUCCEEDED no longer fires for other players, so PredictRule
-- normally produces no predictions (no Cast evidence -> RequiresEvidence="Cast" fails).
-- In PvE without a Paladin in the group, two false-positive sources are absent:
--   · Precognition (PvP gem giving IMPORTANT self-buff) only fires in arena/battleground
--   · Blessing of Freedom (Paladin IMPORTANT external) requires a Paladin caster
-- When both conditions hold, Brain synthesizes Cast evidence on the self-cast path,
-- re-enabling predictions for self-only IMPORTANT/BIG_DEFENSIVE spells.

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 3001   -- distinct from other test files

local function reset()
    B._TestReset()
    B:_TestSetSimulateNoCastSucceeded(true)   -- 12.0.5 mode throughout this file
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Build a watcher exposing AURA_ID as BIG_DEFENSIVE + IMPORTANT (e.g. Dispersion).
-- In BuildCurrentAuraIds: aura appears in GetDefensiveState, filtered out of
-- EXTERNAL_DEFENSIVE -> BIG_DEFENSIVE; not filtered out of IMPORTANT -> IMPORTANT added.
local function makeBigImportantWatcher(unit)
    wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

-- Build a watcher exposing AURA_ID as IMPORTANT-only (e.g. Avenging Wrath, Blessing of Freedom).
-- Aura only in GetImportantState -> AuraTypes = { IMPORTANT = true }.
local function makeImportantOnlyWatcher()
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

-- Register a predictive glow callback and return a getter for the captured spell ID.
local function captureGlow()
    local captured
    B:RegisterPredictiveGlowCallback(function(_, sid) captured = sid end)
    return function() return captured end
end

-- Shadow Priest: Dispersion
-- Rule: BigDefensive=true, Important=true, RequiresEvidence="Cast", SpellId=47585
-- Uses makeBigImportantWatcher.

fw.describe("PredictRule 12.0.5 — PvE synthetic cast re-enabled", function()
    fw.before_each(reset)

    fw.it("predicts Dispersion (Shadow Priest) in PvE with no Paladin", function()
        -- instanceType defaults to "none" (PvE overworld) after wow.reset()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)   -- Shadow

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- No cast event fired -> no real Cast evidence; synthetic Cast must supply it.
        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 47585, "Dispersion should be predicted via synthetic Cast")
    end)

    fw.it("predicts Dispersion in a PvE raid instance", function()
        wow.setInstanceType("raid")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 47585, "raid instance is still PvE — prediction should fire")
    end)

    fw.it("no prediction in arena (Precognition concern)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.is_nil(getGlow(), "arena should suppress synthetic Cast -> no prediction")
    end)

    fw.it("no prediction in pvp battleground (Precognition concern)", function()
        wow.setInstanceType("pvp")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.is_nil(getGlow(), "battleground should suppress synthetic Cast -> no prediction")
    end)

    fw.it("no prediction in PvE when a Paladin is in the group (BoF concern)", function()
        -- party2 = Paladin -> allowSyntheticCast = false even though instanceType is PvE
        wow.setUnitClass("party1", "PRIEST")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        fw.is_nil(getGlow(), "Paladin in candidateUnits should suppress synthetic Cast")
    end)

    fw.it("prediction works for a solo Paladin target (no other Paladin in group)", function()
        -- The target IS a Paladin; candidateUnits = {"party1"} -> no OTHER Paladin -> allowed.
        -- Avenging Wrath (31884): Important=true, BigDefensive=false, ExternalDefensive=false.
        -- Must use IMPORTANT-only watcher (BigDefensive=false would reject a BIG+IMP auraType).
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)   -- Holy Paladin

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 31884, "solo Paladin should predict Avenging Wrath")
    end)

    fw.it("no prediction when target is Paladin and another Paladin is in the group", function()
        -- party2 = another Paladin -> allowSyntheticCast = false for party1's aura too
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 65)
        mods.talents._setSpec("party2", 65)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        fw.is_nil(getGlow(), "two Paladins in group should suppress prediction")
    end)

    fw.it("prediction still works via real cast snapshot regardless of Paladin/instance", function()
        -- Even in arena with a Paladin, a real cast snapshot bypasses allowSyntheticCast
        -- because the useSnapshot=true path doesn't need the flag.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "PRIEST")
        mods.talents._setSpec("player", 258)
        wow.setUnitClass("party1", "PALADIN")

        local entry = loader.makeEntry("player")
        local getGlow = captureGlow()

        -- Fire a real cast event for "player" (UNIT_SPELLCAST_SUCCEEDED still fires locally).
        wow.setTime(0)
        observer:_fireCast("player", 47585)

        local watcher = makeBigImportantWatcher("player")
        observer:_fireAuraChanged(entry, watcher, { "player", "party1" })

        fw.eq(getGlow(), 47585, "real cast snapshot should predict regardless of arena/Paladin flags")
    end)
end)
