-- Tests for PredictSpellIdForUnit intra-spec ambiguity suppression.
--
-- When two eligible rules in the same BySpec list both match the same aura-type
-- signature, prediction is suppressed rather than confidently committing to the
-- first one in the list (which may be wrong).
--
-- Concrete case: Arms Warrior (spec 71).
--   Avatar       (107574): IMPORTANT-only, RequiresTalent=107574
--   Spell Reflect (23920): IMPORTANT-only, CanCancelEarly, RequiresTalent=23920
-- Both are indistinguishable at prediction time when both talents are known.
--
-- Verified behaviour:
--   · Both talents known, neither on CD -> nil (ambiguous, suppress)
--   · Only Avatar talent known           -> Avatar predicted (no alternative)
--   · Only Spell Reflect talent known    -> Spell Reflect predicted (no alternative)
--   · Both talents known, SR on CD       -> Avatar predicted (on-CD rule is not a
--                                           genuine alternative per isAmbiguousAlternative)

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 6001   -- distinct from other test files

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Produces an IMPORTANT-only aura (Avatar and Spell Reflect are both Important=true,
-- BigDefensive=false, ExternalDefensive=false).
local function makeImportantWatcher()
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

local function captureGlow()
    local captured
    B:RegisterPredictiveGlowCallback(function(_, sid) captured = sid end)
    return function() return captured end
end

local function setupArmsWarrior(unit)
    wow.setInstanceType("arena")
    wow.setUnitClass(unit, "WARRIOR")
    mods.talents._setSpec(unit, 71)
end

fw.describe("Intra-spec ambiguity: Avatar vs Spell Reflect (Arms Warrior spec 71)", function()
    fw.before_each(reset)

    fw.it("suppresses prediction when both Avatar and Spell Reflect talents are known", function()
        setupArmsWarrior("party1")
        mods.talents._setTalent("party1", 107574, true)  -- Avatar
        mods.talents._setTalent("party1", 23920,  true)  -- Spell Reflect

        local getGlow = captureGlow()
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeImportantWatcher(), { "party1" })

        fw.is_nil(getGlow(), "both talents known: prediction must be suppressed to avoid false Avatar glow")
    end)

    fw.it("predicts Avatar when only Avatar talent is known", function()
        setupArmsWarrior("party1")
        mods.talents._setTalent("party1", 107574, true)  -- Avatar only

        local getGlow = captureGlow()
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeImportantWatcher(), { "party1" })

        fw.eq(getGlow(), 107574, "Avatar is the only eligible rule: should predict 107574")
    end)

    fw.it("predicts Spell Reflect when only Spell Reflect talent is known", function()
        setupArmsWarrior("party1")
        mods.talents._setTalent("party1", 23920, true)   -- Spell Reflect only

        local getGlow = captureGlow()
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeImportantWatcher(), { "party1" })

        fw.eq(getGlow(), 23920, "Spell Reflect is the only eligible rule: should predict 23920")
    end)

    fw.it("predicts Avatar when both talents known but Spell Reflect is on cooldown", function()
        -- isAmbiguousAlternative gates on `not IsSpellOnCooldown(...)`, so an on-CD rule is
        -- not a genuine alternative and does not trigger ambiguity suppression.
        setupArmsWarrior("party1")
        mods.talents._setTalent("party1", 107574, true)  -- Avatar
        mods.talents._setTalent("party1", 23920,  true)  -- Spell Reflect
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party1" then
                return { [23920] = { MaxCharges = 1, UsedCharges = { 1 } } }
            end
        end)

        local getGlow = captureGlow()
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeImportantWatcher(), { "party1" })

        fw.eq(getGlow(), 107574, "Spell Reflect on CD: should predict Avatar (107574)")
    end)
end)
