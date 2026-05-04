-- Tests for Burrow (Shaman PvP talent 5575, SpellId 409293) cooldown detection.
--
-- Burrow produces no aura.  Brain detects it by requiring all three of
-- UNIT_FLAGS, UNIT_MODEL_CHANGED, and UNIT_PORTRAIT_UPDATE to fire within a
-- 0.5-second window for the same unit.  Two event batches fire per cast:
-- the first batch (Burrow enters ground) fires burrowPredictCallback;
-- the second batch within the 12s rearm window (Burrow exits) fires
-- burrowCooldownCallback with the measured channel duration.
--
-- Public APIs tested:
--   B:RegisterBurrowPredictCallback(fn)   -- fn(unit, now)
--   B:RegisterBurrowCallback(fn)          -- fn(unit, now, castTime)
--   observer:_fireUnitFlags(unit)
--   observer:_fireModelChanged(unit)
--   observer:_firePortraitUpdate(unit)
--
-- Spell/talent IDs referenced:
--   Burrow  SpellId=409293  RequiresTalent=5575  PvPOnly=true  NoAura=true

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods = loader.get()
local B    = mods.brain
local obs  = mods.observer

local BURROW_TALENT = 5575
local BURROW_WINDOW = 0.5
local BURROW_REARM  = 12

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

local function setupShaman(unit)
    wow.setUnitClass(unit, "SHAMAN")
    mods.talents._setTalent(unit, BURROW_TALENT, true)
end

-- Section 1: All three events must fire within the detection window

fw.describe("Burrow detection - event triplet within window", function()
    fw.before_each(reset)

    fw.it("fires predict callback when FLAGS → MODEL → PORTRAIT arrive within 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_fireModelChanged("party1")
        wow.setTime(100.4)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 1, "predict callback should fire once when all three events arrive within 0.5s")
    end)

    fw.it("fires predict callback when MODEL → PORTRAIT → FLAGS arrive within 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(200.0)
        obs:_fireModelChanged("party1")
        wow.setTime(200.1)
        obs:_firePortraitUpdate("party1")
        wow.setTime(200.3)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 1, "event order should not matter - all orderings trigger detection")
    end)

    fw.it("fires predict callback when PORTRAIT → FLAGS → MODEL arrive within 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(300.0)
        obs:_firePortraitUpdate("party1")
        wow.setTime(300.2)
        obs:_fireUnitFlags("party1")
        wow.setTime(300.4)
        obs:_fireModelChanged("party1")

        fw.eq(fired, 1, "PORTRAIT → FLAGS → MODEL ordering also triggers detection")
    end)

    fw.it("does not fire when the gap between first and last event exceeds 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(400.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(400.6)   -- 0.6s gap > correlationWindow (0.5s)
        obs:_fireModelChanged("party1")
        wow.setTime(400.8)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "events spread across > 0.5s should not trigger Burrow detection")
    end)

    fw.it("passes the unit and detection timestamp to the predict callback", function()
        setupShaman("party1")
        local capturedUnit, capturedNow
        B:RegisterBurrowPredictCallback(function(unit, now)
            capturedUnit = unit
            capturedNow  = now
        end)

        wow.setTime(500.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(500.1)
        obs:_fireModelChanged("party1")
        wow.setTime(500.3)
        obs:_firePortraitUpdate("party1")

        fw.eq(capturedUnit, "party1", "predict callback should receive the correct unit string")
        fw.eq(capturedNow,  500.3,   "predict callback should receive the time of the triggering event")
    end)
end)

-- Section 2: Missing events do not trigger detection

fw.describe("Burrow detection - incomplete event sets do not fire", function()
    fw.before_each(reset)

    fw.it("does not fire when only UNIT_FLAGS fires", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "UNIT_FLAGS alone is not sufficient for Burrow detection")
    end)

    fw.it("does not fire when only UNIT_MODEL_CHANGED fires", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireModelChanged("party1")

        fw.eq(fired, 0, "UNIT_MODEL_CHANGED alone is not sufficient for Burrow detection")
    end)

    fw.it("does not fire when only UNIT_PORTRAIT_UPDATE fires", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "UNIT_PORTRAIT_UPDATE alone is not sufficient for Burrow detection")
    end)

    fw.it("does not fire when FLAGS and MODEL fire but PORTRAIT is missing", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_fireModelChanged("party1")

        fw.eq(fired, 0, "two of three events are not enough to commit Burrow")
    end)

    fw.it("does not fire when FLAGS and PORTRAIT fire but MODEL is missing", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "FLAGS + PORTRAIT without MODEL should not trigger Burrow")
    end)

    fw.it("does not fire when MODEL and PORTRAIT fire but FLAGS is missing", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "MODEL + PORTRAIT without FLAGS should not trigger Burrow")
    end)
end)

-- Section 3: Class and talent gates

fw.describe("Burrow detection - class and talent guards", function()
    fw.before_each(reset)

    fw.it("does not fire for a Warrior - Burrow is Shaman-only", function()
        wow.setUnitClass("party1", "WARRIOR")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "non-Shaman unit should never trigger Burrow detection")
    end)

    fw.it("does not fire for a Druid - Burrow is Shaman-only", function()
        wow.setUnitClass("party1", "DRUID")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "Druid model changes (e.g. shapeshifts) should not trigger Burrow")
    end)

    fw.it("does not fire for a Shaman without the Burrow talent (neither 5575 nor 5574)", function()
        wow.setUnitClass("party1", "SHAMAN")
        -- Deliberately do NOT set either Burrow talent.
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "Shaman without either Burrow talent should not commit Burrow")
    end)

    fw.it("fires for a Shaman who has the Burrow talent (5575 - Enhancement/Restoration)", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 1, "Shaman with talent 5575 and all three events should commit Burrow")
    end)

    fw.it("fires for a Shaman who has the Burrow talent (5574 - Elemental)", function()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 5574, true)
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 1, "Shaman with talent 5574 and all three events should commit Burrow")
    end)

    fw.it("fires for a Shaman who has the Burrow talent (5576 - Restoration)", function()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 5576, true)
        local fired = 0
        B:RegisterBurrowPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 1, "Shaman with talent 5576 and all three events should commit Burrow")
    end)

    fw.it("only fires for the Shaman when multiple units receive events", function()
        setupShaman("party1")
        wow.setUnitClass("party2", "WARRIOR")
        local fired = {}
        B:RegisterBurrowPredictCallback(function(unit) fired[unit] = (fired[unit] or 0) + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        obs:_fireUnitFlags("party2")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        obs:_fireModelChanged("party2")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")
        obs:_firePortraitUpdate("party2")

        fw.eq(fired["party1"] or 0, 1, "Burrow should fire for the Shaman (party1)")
        fw.eq(fired["party2"] or 0, 0, "Burrow should not fire for the Warrior (party2)")
    end)
end)

-- Section 4: Predict/commit split

fw.describe("Burrow detection - predict/commit split", function()
    fw.before_each(reset)

    fw.it("first batch fires predict callback but not commit", function()
        setupShaman("party1")
        local predicted = 0
        local committed = 0
        B:RegisterBurrowPredictCallback(function() predicted = predicted + 1 end)
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(predicted, 1, "predict callback should fire on first batch")
        fw.eq(committed, 0, "commit callback should not fire on first batch")
    end)

    fw.it("second batch within rearm window fires commit callback but not predict", function()
        setupShaman("party1")
        local predicted = 0
        local committed = 0
        B:RegisterBurrowPredictCallback(function() predicted = predicted + 1 end)
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        -- First batch (Burrow enters)
        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        -- Second batch within 12s rearm window (Burrow exits)
        wow.setTime(106.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(106.1)
        obs:_fireModelChanged("party1")
        wow.setTime(106.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(predicted, 1, "predict should fire only on the first batch")
        fw.eq(committed, 1, "commit should fire on the second batch within rearm window")
    end)

    fw.it("commit callback receives castTime equal to the predict timestamp", function()
        setupShaman("party1")
        local predictedNow
        local committedNow, committedCastTime
        B:RegisterBurrowPredictCallback(function(unit, now) predictedNow = now end)
        B:RegisterBurrowCallback(function(unit, now, castTime)
            committedNow      = now
            committedCastTime = castTime
        end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        wow.setTime(106.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(106.1)
        obs:_fireModelChanged("party1")
        wow.setTime(106.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(committedCastTime, predictedNow, "castTime in commit should equal the predict timestamp")
        fw.eq(committedNow, 106.2, "now in commit should be the time of the completing second-batch event")
    end)

    fw.it("second batch after rearm window fires a new predict instead of commit", function()
        setupShaman("party1")
        local predicted = 0
        local committed = 0
        B:RegisterBurrowPredictCallback(function() predicted = predicted + 1 end)
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        -- First batch
        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")
        fw.eq(predicted, 1, "first batch fires predict")

        -- Second batch after 12s rearm window (new Burrow cast, not an exit batch)
        wow.setTime(113.0)   -- 12.8s after predict (> 12s rearm)
        obs:_fireUnitFlags("party1")
        wow.setTime(113.1)
        obs:_fireModelChanged("party1")
        wow.setTime(113.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(predicted, 2, "batch after rearm window fires a new predict (new Burrow cast)")
        fw.eq(committed, 0, "no commit should have fired")
    end)

    fw.it("resets per-unit so a second Shaman's predict/commit cycle is independent", function()
        setupShaman("party1")
        setupShaman("party2")
        local predicted = {}
        local committed = {}
        B:RegisterBurrowPredictCallback(function(unit) predicted[unit] = (predicted[unit] or 0) + 1 end)
        B:RegisterBurrowCallback(function(unit) committed[unit] = (committed[unit] or 0) + 1 end)

        -- party1 first batch
        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        -- party2 first batch
        wow.setTime(101.0)
        obs:_fireUnitFlags("party2")
        wow.setTime(101.1)
        obs:_fireModelChanged("party2")
        wow.setTime(101.2)
        obs:_firePortraitUpdate("party2")

        -- party1 second batch (exit)
        wow.setTime(106.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(106.1)
        obs:_fireModelChanged("party1")
        wow.setTime(106.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(predicted["party1"] or 0, 1, "party1 predict should have fired once")
        fw.eq(predicted["party2"] or 0, 1, "party2 predict should have fired independently")
        fw.eq(committed["party1"] or 0, 1, "party1 commit should fire on its second batch")
        fw.eq(committed["party2"] or 0, 0, "party2 commit should not fire (no second batch yet)")
    end)
end)
