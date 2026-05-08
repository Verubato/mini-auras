-- Tests for Emerald Communion (Preservation Evoker PvP talent 5718, SpellId 370960) detection.
--
-- Emerald Communion produces no aura.  Brain detects it via two event batches:
--   Arm:    UNIT_SPELLCAST_CHANNEL_START + UNIT_FLAGS within 0.5s → arms the commit window.
--   Commit: UNIT_SPELLCAST_CHANNEL_STOP  + UNIT_FLAGS within 0.5s → ecCooldownCallback.
-- The 10-second rearm window ties the arm phase to the commit and suppresses re-detection
-- during the channel.  There is no predict callback; only the commit path is used.
--
-- Public APIs tested:
--   B:RegisterEmeraldCommunionCallback(fn)  -- fn(unit, now, castTime)
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
local EC_REARM  = 6.5

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

local function setupEvoker(unit)
    wow.setUnitClass(unit, "EVOKER")
    mods.talents._setTalent(unit, EC_TALENT, true)
end

-- Section 1: Arm phase (CHANNEL_START + UNIT_FLAGS) enables the commit window

fw.describe("Emerald Communion detection - arm phase enables commit", function()
    fw.before_each(reset)

    fw.it("commit fires when arm used CHANNEL_START then UNIT_FLAGS within 0.5s", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.4)
        obs:_fireUnitFlags("party1")

        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "commit should fire after arm with CHANNEL_START then UNIT_FLAGS within 0.5s")
    end)

    fw.it("commit fires when arm used UNIT_FLAGS then CHANNEL_START within 0.5s", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(200.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(200.4)
        obs:_fireChannelStart("party1")

        wow.setTime(205.0)
        obs:_fireChannelStop("party1")
        wow.setTime(205.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "event order within the arm phase should not matter")
    end)

    fw.it("commit does not fire when arm events are more than 0.5s apart", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(300.0)
        obs:_fireChannelStart("party1")
        wow.setTime(300.6)   -- 0.6s gap > correlationWindow (0.5s)
        obs:_fireUnitFlags("party1")

        wow.setTime(305.0)
        obs:_fireChannelStop("party1")
        wow.setTime(305.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "arm events more than 0.5s apart should not enable the commit")
    end)
end)

-- Section 2: Commit fires on CHANNEL_STOP + UNIT_FLAGS within window

fw.describe("Emerald Communion detection - commit on CHANNEL_STOP + UNIT_FLAGS", function()
    fw.before_each(reset)

    fw.it("fires commit when CHANNEL_STOP then UNIT_FLAGS arrive within 0.5s after arm", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- Arm
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Commit
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "commit should fire on CHANNEL_STOP + UNIT_FLAGS after arm")
    end)

    fw.it("fires commit when UNIT_FLAGS then CHANNEL_STOP arrive within 0.5s after arm", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- Arm
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

        -- Arm
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

    fw.it("does not commit when CHANNEL_STOP arrives without a prior arm", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStop("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "CHANNEL_STOP without a prior arm should not commit")
    end)

    fw.it("commit callback receives castTime equal to the arm timestamp", function()
        setupEvoker("party1")
        local committedNow, committedCastTime
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

        fw.eq(committedCastTime, 100.1, "castTime in commit should equal the arm timestamp")
        fw.eq(committedNow, 105.1, "now in commit should be the time of the completing second-batch event")
    end)
end)

-- Section 3: Arm fires only once per channel; second batch commits but does not re-arm

fw.describe("Emerald Communion detection - arm/commit split", function()
    fw.before_each(reset)

    fw.it("first batch arms but does not commit", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "commit should not fire on the first batch")
    end)

    fw.it("second batch fires commit but not a second arm", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- First batch (arm)
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Second batch (commit)
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "commit should fire exactly once on the second batch")
    end)

    fw.it("does not commit when CHANNEL_STOP arrives after the 6.5s rearm window", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        -- Arm
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- Channel stop arrives after rearm has expired
        wow.setTime(111.0)   -- 10.9s after arm (> 6.5s rearm)
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

    fw.it("resets per-unit so a second Evoker's arm/commit is independent", function()
        setupEvoker("party1")
        setupEvoker("party2")
        local committed = {}
        B:RegisterEmeraldCommunionCallback(function(unit) committed[unit] = (committed[unit] or 0) + 1 end)

        -- party1 arm
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- party2 arm
        wow.setTime(101.0)
        obs:_fireChannelStart("party2")
        wow.setTime(101.1)
        obs:_fireUnitFlags("party2")

        -- party1 commit
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed["party1"] or 0, 1, "party1 commit should fire on its second batch")
        fw.eq(committed["party2"] or 0, 0, "party2 commit should not fire (no second batch yet)")
    end)
end)

-- Section 4: Class and talent gates

fw.describe("Emerald Communion detection - class and talent guards", function()
    fw.before_each(reset)

    fw.it("does not commit for a Warrior - EC is Evoker-only", function()
        wow.setUnitClass("party1", "WARRIOR")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "non-Evoker unit should never trigger EC commit")
    end)

    fw.it("does not commit for an Evoker without the EC talent (5718)", function()
        wow.setUnitClass("party1", "EVOKER")
        -- Deliberately do NOT set talent 5718.
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "Evoker without talent 5718 should not commit EC")
    end)

    fw.it("predicts for an Evoker who has the EC talent (5718)", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 1, "Evoker with talent 5718 and both batches should commit EC")
    end)

    fw.it("only commits for the Evoker when multiple units receive events", function()
        setupEvoker("party1")
        wow.setUnitClass("party2", "WARRIOR")
        local committed = {}
        B:RegisterEmeraldCommunionCallback(function(unit) committed[unit] = (committed[unit] or 0) + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        obs:_fireChannelStart("party2")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        obs:_fireUnitFlags("party2")
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        obs:_fireChannelStop("party2")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")
        obs:_fireUnitFlags("party2")

        fw.eq(committed["party1"] or 0, 1, "EC commit should fire for the Evoker (party1)")
        fw.eq(committed["party2"] or 0, 0, "EC commit should not fire for the Warrior (party2)")
    end)
end)

-- Section 5: Single event does not trigger the commit

fw.describe("Emerald Communion detection - single event does not fire", function()
    fw.before_each(reset)

    fw.it("does not commit when only CHANNEL_START fires", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        -- No UNIT_FLAGS -> arm never completes -> commit cannot fire
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "CHANNEL_START alone does not arm the commit")
    end)

    fw.it("does not commit when only UNIT_FLAGS fires", function()
        setupEvoker("party1")
        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        -- No CHANNEL_START -> arm never completes
        wow.setTime(105.0)
        obs:_fireChannelStop("party1")
        wow.setTime(105.1)
        obs:_fireUnitFlags("party1")

        fw.eq(committed, 0, "UNIT_FLAGS alone does not arm the commit")
    end)

    fw.it("does not commit when only CHANNEL_STOP fires", function()
        setupEvoker("party1")
        -- Arm the detector first so the rearm guard does not reject the commit.
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        local committed = 0
        B:RegisterEmeraldCommunionCallback(function() committed = committed + 1 end)

        wow.setTime(106.0)
        obs:_fireChannelStop("party1")
        -- No second UNIT_FLAGS -> commit batch incomplete

        fw.eq(committed, 0, "CHANNEL_STOP alone is not sufficient for EC commit")
    end)
end)
