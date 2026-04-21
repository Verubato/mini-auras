-- Tests for local player appearing under a raid/party alias in 12.0.5 arena mode.
--
-- In 12.0.5 arena, the local player is often exposed as "raid1" (or "raid2", "party1",
-- etc.) rather than "player".  Prior to the fix, RecordCast bailed early for any unit
-- != "player", so cast evidence was never stored and spells neither predicted nor
-- committed for the local player's own casts.
--
-- Fix: RecordCast resolves the unit via ResolveSnapshotUnit (GUID comparison) and stores
-- cast evidence under both "player" and the alias.  TryPredictFromKnownCastId likewise
-- resolves the target unit before looking up the cast snapshot.

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 8001   -- distinct from all other test files

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Alias "raid1" to the same GUID as "player" to simulate the arena roster layout.
-- Also mirrors class/spec onto "player" since UnitClass("player") == UnitClass("raid1") in-game.
local function aliasRaid1ToPlayer(classToken, specId)
    wow.setUnitGUID("raid1", "player-guid")
    wow.setUnitGUID("player", "player-guid")
    if classToken then
        wow.setUnitClass("player", classToken)
    end
    if specId then
        mods.talents._setSpec("player", specId)
    end
end

-- Dispersion (47585) is BigDefensive=true + Important=true.
-- Needs to be in GetDefensiveState with EXT_DEF filter set to filtered-out (= BIG_DEFENSIVE),
-- and IMPORTANT filter left at default (= not filtered = present).
local function makeDispersionWatcher(unit)
    wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
    wow.setAuraFiltered(unit, AURA_ID, "HARMFUL|CROWD_CONTROL", false)  -- Dispersion is CC
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

-- Avenging Wrath (31884): Holy Paladin spec 65, Important=true, BigDefensive=false.
-- IMPORTANT-only aura — simple test subject for the predict path.
local function makeAvengingWrathWatcher()
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

-- Holy Paladin spec 65, Avenging Wrath: IMPORTANT only, RequiresEvidence="Cast".
-- No talent or MinDuration complications.
fw.describe("Local player alias (raid1 = player) - predict path", function()
    fw.before_each(reset)

    fw.it("Avenging Wrath predicted when local Holy Paladin appears as raid1", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("raid1", "PALADIN")
        mods.talents._setSpec("raid1", 65)  -- Holy Paladin
        aliasRaid1ToPlayer("PALADIN", 65)

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        wow.setTime(0)
        observer:_fireCast("raid1", 31884)

        local entry = loader.makeEntry("raid1")
        observer:_fireAuraChanged(entry, makeAvengingWrathWatcher(), { "raid1" })

        fw.eq(glowed, 31884, "Avenging Wrath must be predicted when local player appears as raid1")
    end)

    fw.it("no predict when non-local raid1 casts (no GUID alias)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("raid1", "PALADIN")
        mods.talents._setSpec("raid1", 65)
        -- Do NOT alias raid1; it is a genuine remote player.

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        wow.setTime(0)
        observer:_fireCast("raid1", 31884)   -- no-op in 12.0.5 for non-player

        local entry = loader.makeEntry("raid1")
        observer:_fireAuraChanged(entry, makeAvengingWrathWatcher(), { "raid1" })

        -- PALADIN is not in precogIgnoreClasses, so no synthetic Cast in arena.
        fw.is_nil(glowed, "remote raid1 PALADIN: no predict without cast evidence")
    end)
end)

-- Shadow Priest spec 258, Dispersion (47585): BigDefensive + Important, RequiresEvidence="Cast".
fw.describe("Local player alias (raid1 = player) - commit path", function()
    fw.before_each(reset)

    fw.it("Dispersion commits when local Shadow Priest appears as raid1", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("raid1", "PRIEST")
        mods.talents._setSpec("raid1", 258)  -- Shadow Priest
        aliasRaid1ToPlayer("PRIEST", 258)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        observer:_fireCast("raid1", 47585)

        local entry = loader.makeEntry("raid1")
        local watcher = makeDispersionWatcher("raid1")
        observer:_fireAuraChanged(entry, watcher, { "raid1" })

        wow.advanceTime(6.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "raid1" })

        fw.eq(committed, 47585, "Dispersion must commit for local player appearing as raid1")
    end)

    fw.it("Avenging Wrath (MinDuration) commits at full duration for local player as raid1", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("raid1", "PALADIN")
        mods.talents._setSpec("raid1", 65)  -- Holy Paladin
        aliasRaid1ToPlayer("PALADIN", 65)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        observer:_fireCast("raid1", 31884)

        local entry = loader.makeEntry("raid1")
        observer:_fireAuraChanged(entry, makeAvengingWrathWatcher(), { "raid1" })

        wow.advanceTime(12.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "raid1" })

        fw.eq(committed, 31884, "Avenging Wrath must commit for local player as raid1")
    end)
end)
