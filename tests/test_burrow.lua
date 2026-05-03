-- Tests for Burrow (Shaman PvP talent 5575, SpellId 409293) cooldown detection.
--
-- Burrow produces no aura.  Brain detects it by requiring all three of
-- UNIT_FLAGS, UNIT_MODEL_CHANGED, and UNIT_PORTRAIT_UPDATE to fire within a
-- 0.5-second window for the same unit.  A 12-second rearm guard suppresses
-- the second event batch that fires when Burrow ends or is cancelled.
--
-- Public APIs tested:
--   B:RegisterBurrowCallback(fn)   -- fn(unit, now)
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

    fw.it("fires callback when FLAGS → MODEL → PORTRAIT arrive within 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_fireModelChanged("party1")
        wow.setTime(100.4)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 1, "callback should fire once when all three events arrive within 0.5s")
    end)

    fw.it("fires callback when MODEL → PORTRAIT → FLAGS arrive within 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(200.0)
        obs:_fireModelChanged("party1")
        wow.setTime(200.1)
        obs:_firePortraitUpdate("party1")
        wow.setTime(200.3)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 1, "event order should not matter - all orderings trigger detection")
    end)

    fw.it("fires callback when PORTRAIT → FLAGS → MODEL arrive within 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(300.0)
        obs:_firePortraitUpdate("party1")
        wow.setTime(300.2)
        obs:_fireUnitFlags("party1")
        wow.setTime(300.4)
        obs:_fireModelChanged("party1")

        fw.eq(fired, 1, "PORTRAIT → FLAGS → MODEL ordering also triggers detection")
    end)

    fw.it("does not fire when the window between first and last event exceeds 0.5s", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function(unit, now) fired = fired + 1 end)

        wow.setTime(400.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(400.6)   -- 0.6s gap > burrowWindow (0.5s)
        obs:_fireModelChanged("party1")
        wow.setTime(400.8)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "events spread across > 0.5s should not trigger Burrow detection")
    end)

    fw.it("passes the unit and detection timestamp to the callback", function()
        setupShaman("party1")
        local capturedUnit, capturedNow
        B:RegisterBurrowCallback(function(unit, now)
            capturedUnit = unit
            capturedNow  = now
        end)

        wow.setTime(500.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(500.1)
        obs:_fireModelChanged("party1")
        wow.setTime(500.3)
        obs:_firePortraitUpdate("party1")

        fw.eq(capturedUnit, "party1", "callback should receive the correct unit string")
        fw.eq(capturedNow,  500.3,   "callback should receive the time of the triggering event")
    end)
end)

-- Section 2: Missing events do not trigger detection

fw.describe("Burrow detection - incomplete event sets do not fire", function()
    fw.before_each(reset)

    fw.it("does not fire when only UNIT_FLAGS fires", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "UNIT_FLAGS alone is not sufficient for Burrow detection")
    end)

    fw.it("does not fire when only UNIT_MODEL_CHANGED fires", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireModelChanged("party1")

        fw.eq(fired, 0, "UNIT_MODEL_CHANGED alone is not sufficient for Burrow detection")
    end)

    fw.it("does not fire when only UNIT_PORTRAIT_UPDATE fires", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "UNIT_PORTRAIT_UPDATE alone is not sufficient for Burrow detection")
    end)

    fw.it("does not fire when FLAGS and MODEL fire but PORTRAIT is missing", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_fireModelChanged("party1")

        fw.eq(fired, 0, "two of three events are not enough to commit Burrow")
    end)

    fw.it("does not fire when FLAGS and PORTRAIT fire but MODEL is missing", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "FLAGS + PORTRAIT without MODEL should not trigger Burrow")
    end)

    fw.it("does not fire when MODEL and PORTRAIT fire but FLAGS is missing", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

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
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

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
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "Druid model changes (e.g. shapeshifts) should not trigger Burrow")
    end)

    fw.it("does not fire for a Shaman without the Burrow talent (5575)", function()
        wow.setUnitClass("party1", "SHAMAN")
        -- Deliberately do NOT set talent 5575.
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 0, "Shaman without talent 5575 should not commit Burrow")
    end)

    fw.it("fires for a Shaman who has the Burrow talent (5575)", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 1, "Shaman with talent 5575 and all three events should commit Burrow")
    end)

    fw.it("only fires for the Shaman when multiple units receive events", function()
        setupShaman("party1")
        wow.setUnitClass("party2", "WARRIOR")
        local fired = {}
        B:RegisterBurrowCallback(function(unit) fired[unit] = (fired[unit] or 0) + 1 end)

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

-- Section 4: Rearm window suppresses the second event batch

fw.describe("Burrow detection - rearm window suppresses second event batch", function()
    fw.before_each(reset)

    fw.it("suppresses a second triplet that arrives within the 12s rearm window", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        -- First batch (enters Burrow)
        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")
        fw.eq(fired, 1, "first event triplet should commit Burrow")

        -- Second batch (exits Burrow) within the 12s rearm window
        wow.setTime(108.0)   -- 7.8s after first commit (< 12s rearm)
        obs:_fireUnitFlags("party1")
        wow.setTime(108.1)
        obs:_fireModelChanged("party1")
        wow.setTime(108.2)
        obs:_firePortraitUpdate("party1")
        fw.eq(fired, 1, "second triplet within rearm window should be suppressed")
    end)

    fw.it("fires again after the 12s rearm window expires", function()
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        -- First batch
        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")
        fw.eq(fired, 1, "first event triplet should commit Burrow")

        -- Second use after rearm window has passed
        wow.setTime(113.0)   -- 12.8s after first commit (> 12s rearm)
        obs:_fireUnitFlags("party1")
        wow.setTime(113.1)
        obs:_fireModelChanged("party1")
        wow.setTime(113.2)
        obs:_firePortraitUpdate("party1")
        fw.eq(fired, 2, "second triplet after rearm window should commit a new Burrow cast")
    end)

    fw.it("suppresses a triplet whose completing event is 9s after the original commit", function()
        -- The rearm check fires at TryCommitBurrow time, which is the completing event's
        -- timestamp, not the first event's.  All three events of the second batch must
        -- complete within 12s of the commit for suppression to apply.
        setupShaman("party1")
        local fired = 0
        B:RegisterBurrowCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)   -- commit stored at 100.2
        obs:_firePortraitUpdate("party1")

        wow.setTime(109.0)   -- 8.8s after commit
        obs:_fireUnitFlags("party1")
        wow.setTime(109.1)
        obs:_fireModelChanged("party1")
        wow.setTime(109.2)   -- completing event at 9.0s after commit < 12s rearm
        obs:_firePortraitUpdate("party1")

        fw.eq(fired, 1, "second triplet completing 9s after commit should be suppressed by rearm window")
    end)

    fw.it("resets per-unit so a second Shaman is not affected by the first's rearm", function()
        setupShaman("party1")
        setupShaman("party2")
        local fired = {}
        B:RegisterBurrowCallback(function(unit) fired[unit] = (fired[unit] or 0) + 1 end)

        -- party1 uses Burrow
        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.1)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        -- party2 uses Burrow shortly after - rearm for party1 should not block party2
        wow.setTime(101.0)
        obs:_fireUnitFlags("party2")
        wow.setTime(101.1)
        obs:_fireModelChanged("party2")
        wow.setTime(101.2)
        obs:_firePortraitUpdate("party2")

        fw.eq(fired["party1"] or 0, 1, "party1 Burrow should have committed")
        fw.eq(fired["party2"] or 0, 1, "party2 Burrow should commit independently of party1's rearm")
    end)
end)
