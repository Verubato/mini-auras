-- Tests for Emerald Communion (Preservation Evoker PvP talent 5718, SpellId 370960) detection.
--
-- Emerald Communion produces no aura.  Brain detects it by requiring both
-- UNIT_SPELLCAST_CHANNEL_START and UNIT_FLAGS to fire within the 0.5-second
-- correlationWindow for the same unit.  A 10-second rearm guard suppresses
-- re-detection during the channel.
--
-- Public APIs tested:
--   B:RegisterEmeraldCommunionCallback(fn)   -- fn(unit, now)
--   obs:_fireChannelStart(unit)
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

-- Section 1: Both events must fire within the detection window

fw.describe("Emerald Communion detection - event pair within window", function()
    fw.before_each(reset)

    fw.it("fires callback when CHANNEL_START then UNIT_FLAGS arrive within 0.5s", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.4)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 1, "callback should fire once when both events arrive within 0.5s")
    end)

    fw.it("fires callback when UNIT_FLAGS then CHANNEL_START arrive within 0.5s", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(200.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(200.4)
        obs:_fireChannelStart("party1")

        fw.eq(fired, 1, "event order should not matter")
    end)

    fw.it("does not fire when the gap between the two events exceeds 0.5s", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(300.0)
        obs:_fireChannelStart("party1")
        wow.setTime(300.6)   -- 0.6s gap > correlationWindow (0.5s)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "events more than 0.5s apart should not trigger EC detection")
    end)

    fw.it("passes the unit and detection timestamp to the callback", function()
        setupEvoker("party1")
        local capturedUnit, capturedNow
        B:RegisterEmeraldCommunionCallback(function(unit, now)
            capturedUnit = unit
            capturedNow  = now
        end)

        wow.setTime(400.0)
        obs:_fireChannelStart("party1")
        wow.setTime(400.3)
        obs:_fireUnitFlags("party1")

        fw.eq(capturedUnit, "party1", "callback should receive the correct unit string")
        fw.eq(capturedNow,  400.3,   "callback should receive the time of the triggering event")
    end)
end)

-- Section 2: Missing one event does not trigger detection

fw.describe("Emerald Communion detection - single event does not fire", function()
    fw.before_each(reset)

    fw.it("does not fire when only CHANNEL_START fires", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")

        fw.eq(fired, 0, "CHANNEL_START alone is not sufficient for EC detection")
    end)

    fw.it("does not fire when only UNIT_FLAGS fires", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "UNIT_FLAGS alone is not sufficient for EC detection")
    end)
end)

-- Section 3: Class and talent gates

fw.describe("Emerald Communion detection - class and talent guards", function()
    fw.before_each(reset)

    fw.it("does not fire for a Warrior - EC is Evoker-only", function()
        wow.setUnitClass("party1", "WARRIOR")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "non-Evoker unit should never trigger EC detection")
    end)

    fw.it("does not fire for an Evoker without the EC talent (5718)", function()
        wow.setUnitClass("party1", "EVOKER")
        -- Deliberately do NOT set talent 5718.
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 0, "Evoker without talent 5718 should not commit EC")
    end)

    fw.it("fires for an Evoker who has the EC talent (5718)", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        fw.eq(fired, 1, "Evoker with talent 5718 and both events should commit EC")
    end)

    fw.it("only fires for the Evoker when multiple units receive events", function()
        setupEvoker("party1")
        wow.setUnitClass("party2", "WARRIOR")
        local fired = {}
        B:RegisterEmeraldCommunionCallback(function(unit) fired[unit] = (fired[unit] or 0) + 1 end)

        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        obs:_fireChannelStart("party2")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        obs:_fireUnitFlags("party2")

        fw.eq(fired["party1"] or 0, 1, "EC should fire for the Evoker (party1)")
        fw.eq(fired["party2"] or 0, 0, "EC should not fire for the Warrior (party2)")
    end)
end)

-- Section 4: Rearm window suppresses re-detection during the channel

fw.describe("Emerald Communion detection - rearm window suppresses re-detection", function()
    fw.before_each(reset)

    fw.it("suppresses a second pair that arrives within the 10s rearm window", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        -- First detection (EC channel starts)
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        fw.eq(fired, 1, "first event pair should commit EC")

        -- Second pair within the 10s rearm window
        wow.setTime(107.0)   -- 6.9s after first commit (< 10s rearm)
        obs:_fireChannelStart("party1")
        wow.setTime(107.1)
        obs:_fireUnitFlags("party1")
        fw.eq(fired, 1, "second pair within rearm window should be suppressed")
    end)

    fw.it("fires again after the 10s rearm window expires", function()
        setupEvoker("party1")
        local fired = 0
        B:RegisterEmeraldCommunionCallback(function() fired = fired + 1 end)

        -- First use
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")
        fw.eq(fired, 1, "first event pair should commit EC")

        -- Second use after rearm window has passed
        wow.setTime(111.0)   -- 10.9s after first commit (> 10s rearm)
        obs:_fireChannelStart("party1")
        wow.setTime(111.1)
        obs:_fireUnitFlags("party1")
        fw.eq(fired, 2, "second pair after rearm window should commit a new EC cast")
    end)

    fw.it("resets per-unit so a second Evoker is not affected by the first's rearm", function()
        setupEvoker("party1")
        setupEvoker("party2")
        local fired = {}
        B:RegisterEmeraldCommunionCallback(function(unit) fired[unit] = (fired[unit] or 0) + 1 end)

        -- party1 uses EC
        wow.setTime(100.0)
        obs:_fireChannelStart("party1")
        wow.setTime(100.1)
        obs:_fireUnitFlags("party1")

        -- party2 uses EC shortly after — rearm for party1 should not block party2
        wow.setTime(101.0)
        obs:_fireChannelStart("party2")
        wow.setTime(101.1)
        obs:_fireUnitFlags("party2")

        fw.eq(fired["party1"] or 0, 1, "party1 EC should have committed")
        fw.eq(fired["party2"] or 0, 1, "party2 EC should commit independently of party1's rearm")
    end)
end)
