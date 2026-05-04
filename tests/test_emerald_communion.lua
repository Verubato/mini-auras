-- Tests for Emerald Communion (Preservation Evoker PvP talent 5718, SpellId 370960) detection.
--
-- Emerald Communion produces no aura.  Brain detects it in two phases:
--   Predict: UNIT_SPELLCAST_CHANNEL_START + UNIT_FLAGS within 0.5s → ecPredictCallback.
--   Commit:  UNIT_SPELLCAST_CHANNEL_STOP  + UNIT_FLAGS within 0.5s → ecCooldownCallback.
-- The 10-second rearm window ties predict to commit and suppresses re-detection during the channel.
--
-- Public APIs tested:
--   B:RegisterEmeraldCommunionPredictCallback(fn)  -- fn(unit, now)
--   B:RegisterEmeraldCommunionCallback(fn)         -- fn(unit, now, castTime)
--   obs:_fireChannelStart(unit)
--   obs:_fireChannelStop(unit)
--   obs:_fireUnitFlags(unit)
--
-- Spell/talent IDs referenced:
--   Emerald Communion  SpellId=370960  RequiresTalent=5718  PvPOnly=true  NoAura=true

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods = loader.get()
local B    = mods.brain
local obs  = mods.observer

local EC_TALENT = 5718
local EC_WINDOW = 0.5
local EC_REARM  = 10

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

local function setupEvoker(unit)
    wow.setUnitClass(unit, "EVOKER")
    mods.talents._setTalent(unit, EC_TALENT, true)
end

-- Section 1: Predict fires on CHANNEL_START + UNIT_FLAGS within window

fw.describe("Emerald Communion detection - predict on CHANNEL_START + UNIT_FLAGS", function()
    fw.before_each(reset)

    fw.it("fires predict when CHANNEL_START then UNIT_FLAGS arrive within 0.5s", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.4)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 1, "predict should fire when both events arrive within 0.5s")
    end)

    fw.it("fires predict when UNIT_FLAGS then CHANNEL_START arrive within 0.5s", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(200.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(200.4)
        obs:_fireChannelStart("party1")

        fw.eq(fired, 1, "event order should not matter for predict")
    end)

    fw.it("does not predict when the gap between events exceeds 0.5s", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(300.0)
        obs:_fireChannelStart("party1")
        wow.setTime(300.6)   -- 0.6s gap > correlationWindow (0.5s)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "events more than 0.5s apart should not trigger EC predict")
    end)

    fw.it("passes the unit and timestamp to the predict callback", function()
        setupEvoker("party1")
        local capturedUnit, capturedNow
        B:RegisterEmeraldCommunionPredictCallback(function(unit, now)
            capturedUnit = unit
            capturedNow  = now
        end)

        wow.setTime(400.0)
        obs:_fireChannelStart("party1")
        wow.setTime(400.3)
        obs:_fireUnitFlags("party1")

        fw.eq(capturedUnit, "party1", "predict callback should receive the correct unit")
        fw.eq(capturedNow,  400.3,   "predict callback should receive the completing event time")
    end)
end)

-- Section 2: Commit fires on CHANNEL_STOP + UNIT_FLAGS within window

fw.describe("Emerald Communion detection - commit on CHANNEL_STOP + UNIT_FLAGS", function()
    fw.before_each(reset)

    fw.it("fires commit when CHANNEL_STOP then UNIT_FLAGS arrive within 0.5s after a predict", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- Predict
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Commit
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "commit should fire on CHANNEL_STOP + UNIT_FLAGS after a predict")
    end)

    fw.it("fires commit when UNIT_FLAGS then CHANNEL_STOP arrive within 0.5s after a predict", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- Predict
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Commit (FLAGS before STOP)
        wow.setTime(105.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(105.4)
        obs:_fireChannelStop("party1")

        fw.eq(committed, 1, "event order should not matter for commit")
    end)

    fw.it("does not commit when CHANNEL_STOP gap to UNIT_FLAGS exceeds 0.5s", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- Predict
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Commit attempt with stale UNIT_FLAGS
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.6)   -- 0.6s gap > correlationWindow
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "CHANNEL_STOP + UNIT_FLAGS more than 0.5s apart should not commit")
    end)

    fw.it("does not commit when CHANNEL_STOP arrives without a prior predict", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStop("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "CHANNEL_STOP without a prior predict should not commit")
    end)

    fw.it("commit callback receives castTime equal to the predict timestamp", function()
        setupEvoker("party1")
        local predictedNow
        local committedNow, committedCastTime
        B:RegisterEmeraldCommunionPredictCallback(function(unit, now) predictedNow = now end)
        B:RegisterEmeraldCommunionCallback(function(unit, now, castTime)
            committedNow      = now
            committedCastTime = castTime
        end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committedCastTime, predictedNow, "castTime in commit should equal the predict timestamp")
        fw.eq(committedNow, 105.1, "now in commit should be the time of the completing second-batch event")
    end)
end)

-- Section 3: Predict fires only once per channel; commit does not re-predict

fw.describe("Emerald Communion detection - predict/commit split", function()
    fw.before_each(reset)

    fw.it("first batch fires predict but not commit", function()
        setupEvoker("party1")
        local predicted = 0
        local committed = 0
        B:RegisterEmeraldCommunionPredictCallback(function() predicted = predicted + 1 end)
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(predicted, 1, "predict should fire on the first batch")
        fw.eq(committed, 0, "commit should not fire on the first batch")
    end)

    fw.it("second batch fires commit but not a second predict", function()
        setupEvoker("party1")
        local predicted = 0
        local committed = 0
        B:RegisterEmeraldCommunionPredictCallback(function() predicted = predicted + 1 end)
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- First batch
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Second batch
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(predicted, 1, "predict should fire only on the first batch")
        fw.eq(committed, 1, "commit should fire on the second batch")
    end)

    fw.it("does not commit when CHANNEL_STOP arrives after the 10s rearm window", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- Predict
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Channel stop arrives after rearm has expired
        wow.setTime(111.0)   -- 10.9s after predict (> 10s rearm)
        obs:_fireChannelStop("party1")
        wow.setTime(111.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "CHANNEL_STOP after rearm expiry should not commit")
    end)

    fw.it("does not commit when channel duration is shorter than 3.5s (4s min - tolerance)", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- 3.0s elapsed < 3.5s minimum
        wow.setTime(103.1)
        obs:_fireChannelStop("party1")
        wow.setTime(103.2)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "channel duration under 3.5s should not commit EC")
    end)

    fw.it("commits when channel duration is exactly at the 3.5s minimum boundary", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- 3.5s elapsed = 4s min - 0.5 tolerance
        wow.setTime(103.6)
        obs:_fireChannelStop("party1")
        wow.setTime(103.7)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "channel duration at exactly 3.5s should commit EC")
    end)

    fw.it("commits when channel duration is exactly at the 5.5s maximum boundary", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- 5.5s elapsed = 5s max + 0.5 tolerance
        wow.setTime(105.6)
        obs:_fireChannelStop("party1")
        wow.setTime(105.7)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "channel duration at exactly 5.5s should commit EC")
    end)

    fw.it("does not commit when channel duration exceeds 5.5s (5s max + tolerance)", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- 6.0s elapsed > 5.5s maximum
        wow.setTime(106.1)
        obs:_fireChannelStop("party1")
        wow.setTime(106.2)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "channel duration over 5.5s should not commit EC")
    end)

    fw.it("resets per-unit so a second Evoker's predict/commit is independent", function()
        setupEvoker("party1")
        setupEvoker("party2")
        local predicted = {}
        local committed = {}
        B:RegisterEmeraldCommunionPredictCallback(function(unit) predicted[unit] = (predicted[unit] or 0) + 1 end)
        B:RegisterEmeraldCommunionCallback(function(unit) committed[unit] = (committed[unit] or 0) + 1 end)

        -- party1 predict
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- party2 predict
        wow.setTime(101.0)
        obs:_fireChannelStart("party2")
        wow.setTime(101.1)
        obs:_fireUnitFlags("party2")

        -- party1 commit
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(predicted["party1"] or 0, 1, "party1 predict should have fired")
        fw.eq(predicted["party2"] or 0, 1, "party2 predict should have fired independently")
        fw.eq(committed["party1"] or 0, 1, "party1 commit should fire on its second batch")
        fw.eq(committed["party2"] or 0, 0, "party2 commit should not fire (no second batch yet)")
    end)
end)

-- Section 4: Class and talent gates

fw.describe("Emerald Communion detection - class and talent guards", function()
    fw.before_each(reset)

    fw.it("does not predict for a Warrior - EC is Evoker-only", function()
        wow.setUnitClass("party1", "WARRIOR")
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "non-Evoker unit should never trigger EC predict")
    end)

    fw.it("does not predict for an Evoker without the EC talent (5718)", function()
        wow.setUnitClass("party1", "EVOKER")
        -- Deliberately do NOT set talent 5718.
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "Evoker without talent 5718 should not predict EC")
    end)

    fw.it("predicts for an Evoker who has the EC talent (5718)", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 1, "Evoker with talent 5718 and both events should predict EC")
    end)

    fw.it("only predicts for the Evoker when multiple units receive events", function()
        setupEvoker("party1")
        wow.setUnitClass("party2", "WARRIOR")
        local fired = {}
        B:RegisterEmeraldCommunionPredictCallback(function(unit) fired[unit] = (fired[unit] or 0) + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        obs:_fireChannelStart("party2")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        obs:_fireUnitFlags("party2")

        fw.eq(fired["party1"] or 0, 1, "EC predict should fire for the Evoker (party1)")
        fw.eq(fired["party2"] or 0, 0, "EC predict should not fire for the Warrior (party2)")
    end)
end)

-- Section 5: Single event does not trigger either callback

fw.describe("Emerald Communion detection - single event does not fire", function()
    fw.before_each(reset)

    fw.it("does not predict when only CHANNEL_START fires", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")

        fw.eq(fired, 0, "CHANNEL_START alone is not sufficient for EC predict")
    end)

    fw.it("does not predict when only UNIT_FLAGS fires", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionPredictCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "UNIT_FLAGS alone is not sufficient for EC predict")
    end)

    fw.it("does not commit when only CHANNEL_STOP fires", function()
        setupEvoker("party1")
        -- Set up a predict first so the rearm guard doesn't reject the commit.
        B:RegisterEmeraldCommunionPredictCallback(function() end)
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(106.0)
        obs:_fireChannelStop("party1")

        fw.eq(committed, 0, "CHANNEL_STOP alone is not sufficient for EC commit")
    end)
end)
