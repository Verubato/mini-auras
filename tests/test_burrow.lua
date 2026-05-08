-- Tests for Burrow (Shaman PvP talent 5575, SpellId 409293) cooldown detection.
--
-- Burrow produces no aura.  Brain detects it by requiring the same event triplet
-- (UNIT_FLAGS + UNIT_MODEL_CHANGED + UNIT_PORTRAIT_UPDATE) to fire twice within a
-- 0.5-second correlation window per batch, with the two batches separated by no more
-- than burrowActiveDuration + burrowArmTolerance seconds (~6.5s).
--
-- This two-batch requirement prevents a false commit from the single batch of events
-- that fires when an enemy Shaman first enters render distance.
--
-- Public APIs tested:
--   B:RegisterBurrowCallback(fn)   -- fn(unit, now, castTime)
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
local BURROW_WINDOW = 0.5   -- correlation window per batch
local BURROW_ARM    = 6.5   -- max gap between batch 1 and batch 2 (active duration + tolerance)

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

local function setupShaman(unit)
    wow.setUnitClass(unit, "SHAMAN")
    mods.talents._setTalent(unit, BURROW_TALENT, true)
end

local function fireBatch(unit, t0)
    wow.setTime(t0)
    obs:_fireUnitFlags(unit)
    wow.setTime(t0 + 0.1)
    obs:_fireModelChanged(unit)
    wow.setTime(t0 + 0.2)
    obs:_firePortraitUpdate(unit)
end

-- Section 1: Two-batch commit

fw.describe("Burrow detection - two-batch commit", function()
    fw.before_each(reset)

    fw.it("commit fires when second triplet arrives within the arm window", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)   -- batch 1: arm
        fireBatch("party1", 104.0)   -- batch 2: 3.8s gap, within 6.5s window

        fw.eq(committed, 1, "commit should fire on the second batch within the arm window")
    end)

    fw.it("first batch alone does not commit", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)

        fw.eq(committed, 0, "single batch should only arm the detector, not commit")
    end)

    fw.it("commit fires regardless of event order within each batch", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        -- First batch: MODEL -> PORTRAIT -> FLAGS
        wow.setTime(100.0)
        obs:_fireModelChanged("party1")
        wow.setTime(100.1)
        obs:_firePortraitUpdate("party1")
        wow.setTime(100.3)
        obs:_fireUnitFlags("party1")

        -- Second batch: PORTRAIT -> FLAGS -> MODEL
        wow.setTime(104.0)
        obs:_firePortraitUpdate("party1")
        wow.setTime(104.2)
        obs:_fireUnitFlags("party1")
        wow.setTime(104.4)
        obs:_fireModelChanged("party1")

        fw.eq(committed, 1, "event order within each batch should not matter")
    end)

    fw.it("first batch with gap > 0.5s does not arm, so second batch does not commit", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.6)   -- 0.6s > correlationWindow
        obs:_fireModelChanged("party1")
        wow.setTime(100.7)
        obs:_firePortraitUpdate("party1")

        fireBatch("party1", 104.0)   -- second batch, but first batch never armed

        fw.eq(committed, 0, "stale first batch should not arm; second batch should not commit")
    end)

    fw.it("commit callback receives castTime equal to the arm timestamp and correct now", function()
        setupShaman("party1")
        local committedNow, committedCastTime
        B:RegisterBurrowCallback(function(unit, now, castTime)
            committedNow      = now
            committedCastTime = castTime
        end)

        fireBatch("party1", 100.0)   -- arm fires at 100.2 (last event of first batch)
        fireBatch("party1", 104.0)   -- commit fires at 104.2 (last event of second batch)

        fw.eq(committedCastTime, 100.2, "castTime should equal the arm timestamp (last event of first batch)")
        fw.eq(committedNow,      104.2, "now should equal the time of the last event of the second batch")
    end)
end)

-- Section 2: Second batch outside arm window arms, does not commit

fw.describe("Burrow detection - arm window expiry", function()
    fw.before_each(reset)

    fw.it("second batch after arm window triggers new arm, not commit", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)   -- arm at 100.2
        fireBatch("party1", 108.0)   -- 7.8s gap > 6.5s arm window -> new arm, no commit

        fw.eq(committed, 0, "second batch after arm window should re-arm, not commit")
    end)

    fw.it("third batch after expired arm still commits if second batch was within window", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)   -- arm 1 at 100.2
        fireBatch("party1", 108.0)   -- arm 2 at 108.2 (expired first arm -> new arm, no commit)
        fireBatch("party1", 112.0)   -- 3.8s gap from arm 2 -> commit

        fw.eq(committed, 1, "commit should fire when the batch after the re-arm arrives within the window")
    end)
end)

-- Section 3: Missing events do not arm

fw.describe("Burrow detection - incomplete event sets do not arm", function()
    fw.before_each(reset)

    fw.it("does not commit when only UNIT_FLAGS fires in first batch", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")

        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "UNIT_FLAGS alone does not arm; second batch should not commit")
    end)

    fw.it("does not commit when only UNIT_MODEL_CHANGED fires in first batch", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireModelChanged("party1")

        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "UNIT_MODEL_CHANGED alone does not arm")
    end)

    fw.it("does not commit when only UNIT_PORTRAIT_UPDATE fires in first batch", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_firePortraitUpdate("party1")

        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "UNIT_PORTRAIT_UPDATE alone does not arm")
    end)

    fw.it("does not commit when FLAGS and MODEL fire but PORTRAIT is missing in first batch", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_fireModelChanged("party1")

        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "two of three events in first batch are not enough to arm")
    end)

    fw.it("does not commit when FLAGS and PORTRAIT fire but MODEL is missing in first batch", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireUnitFlags("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "FLAGS + PORTRAIT without MODEL should not arm")
    end)

    fw.it("does not commit when MODEL and PORTRAIT fire but FLAGS is missing in first batch", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        wow.setTime(100.0)
        obs:_fireModelChanged("party1")
        wow.setTime(100.2)
        obs:_firePortraitUpdate("party1")

        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "MODEL + PORTRAIT without FLAGS should not arm")
    end)
end)

-- Section 4: Class and talent gates

fw.describe("Burrow detection - class and talent guards", function()
    fw.before_each(reset)

    fw.it("does not commit for a Warrior - Burrow is Shaman-only", function()
        wow.setUnitClass("party1", "WARRIOR")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)
        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "non-Shaman unit should never trigger Burrow detection")
    end)

    fw.it("does not commit for a Druid - Burrow is Shaman-only", function()
        wow.setUnitClass("party1", "DRUID")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)
        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "Druid model changes (e.g. shapeshifts) should not trigger Burrow")
    end)

    fw.it("does not commit for a Shaman without the Burrow talent", function()
        wow.setUnitClass("party1", "SHAMAN")
        -- Deliberately do NOT set any Burrow talent.
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)
        fireBatch("party1", 104.0)

        fw.eq(committed, 0, "Shaman without any Burrow talent should not commit")
    end)

    fw.it("commits for a Shaman with talent 5575 (Enhancement)", function()
        setupShaman("party1")
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)
        fireBatch("party1", 104.0)

        fw.eq(committed, 1, "Shaman with talent 5575 should commit on two batches")
    end)

    fw.it("commits for a Shaman with talent 5574 (Elemental)", function()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 5574, true)
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)
        fireBatch("party1", 104.0)

        fw.eq(committed, 1, "Shaman with talent 5574 should commit on two batches")
    end)

    fw.it("commits for a Shaman with talent 5576 (Restoration)", function()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 5576, true)
        local committed = 0
        B:RegisterBurrowCallback(function() committed = committed + 1 end)

        fireBatch("party1", 100.0)
        fireBatch("party1", 104.0)

        fw.eq(committed, 1, "Shaman with talent 5576 should commit on two batches")
    end)

    fw.it("only commits for the Shaman when multiple units receive events", function()
        setupShaman("party1")
        wow.setUnitClass("party2", "WARRIOR")
        local committed = {}
        B:RegisterBurrowCallback(function(unit) committed[unit] = (committed[unit] or 0) + 1 end)

        fireBatch("party1", 100.0)
        fireBatch("party2", 100.0)
        fireBatch("party1", 104.0)
        fireBatch("party2", 104.0)

        fw.eq(committed["party1"] or 0, 1, "Burrow should commit for the Shaman (party1)")
        fw.eq(committed["party2"] or 0, 0, "Burrow should not commit for the Warrior (party2)")
    end)
end)

-- Section 5: Per-unit isolation

fw.describe("Burrow detection - per-unit state isolation", function()
    fw.before_each(reset)

    fw.it("two Shamans are tracked independently", function()
        setupShaman("party1")
        setupShaman("party2")
        local committed = {}
        B:RegisterBurrowCallback(function(unit) committed[unit] = (committed[unit] or 0) + 1 end)

        fireBatch("party1", 100.0)   -- party1 arm
        fireBatch("party2", 101.0)   -- party2 arm

        fireBatch("party1", 104.0)   -- party1 commit (3.8s from arm)

        fw.eq(committed["party1"] or 0, 1, "party1 commit should fire on its second batch")
        fw.eq(committed["party2"] or 0, 0, "party2 commit should not fire (no second batch yet)")

        fireBatch("party2", 105.0)   -- party2 commit (3.8s from arm)

        fw.eq(committed["party2"] or 0, 1, "party2 commit should fire on its second batch")
    end)
end)
