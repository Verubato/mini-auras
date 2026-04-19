-- Tests for Time Stop (Evoker PvP talent) interaction with Dragonrage.
--
-- Time Stop (SpellId=378441): Evoker PvP talent, applies a ~5s IMPORTANT-only self-buff.
-- Lives in ByClass["EVOKER"] with RequiresTalent={5463,5464,5619} (one per spec variant).
--
-- Devastation Evoker (spec 1467) risk assessment:
--   · BySpec[1467] contains only Dragonrage: Important=true, RequiresEvidence="Cast",
--     MinDuration=true, BuffDuration=18.
--   · When the local player self-casts Time Stop, SpellId 378441 is stored in
--     CastSpellIdSnapshot["player"] (local casts are always recorded in 12.0.5 mode).
--   · TryPredictFromKnownCastId finds 378441 in the window.  Without talent data,
--     FindRuleBySpellId returns nil (RequiresTalent gate fails for the class Time Stop rule).
--     The function returns (nil, handled=true): "IDs in window but no rule matched - do not
--     fall through to indirect evidence matching."  This is the same mechanism that handles
--     Phase Shift / Fade.  Dragonrage is therefore NOT predicted. ✓
--   · Commit: Dragonrage has MinDuration=true, BuffDuration=18.  A 5s Time Stop removal
--     fails durationOk (5 < 17.85) and is never committed. ✓
--
-- Non-local party member Evoker in 12.0.5 mode:
--   · RecordCast is a no-op for non-"player" units → no CastSpellIdSnapshot entry →
--     TryPredictFromKnownCastId returns (nil, false) → falls through.
--   · allowSyntheticCast=false for EVOKER in arena → no synthetic Cast → no predict.
--   · No commit either (no Cast evidence, Dragonrage RequiresEvidence="Cast" fails).

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 6001   -- distinct from all other test files

-- Time Stop PvP talent IDs (spec-specific variants; any one is sufficient for RequiresTalent).
local TIME_STOP_TALENT_IDS = { 5463, 5464, 5619 }

local function reset()
    B._TestReset()
    B:_TestSetSimulateNoCastSucceeded(true)   -- 12.0.5 / arena mode throughout
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- IMPORTANT-only watcher (Time Stop self-buff, appears only in GetImportantState).
-- Time Stop is a friendly CC; WoW likely classifies it as HELPFUL|CROWD_CONTROL on the recipient.
-- Both filters are set so the test works regardless of which variant WoW actually uses.
local function makeTimeStopWatcher()
    wow.setAuraFiltered("player", AURA_ID, "HELPFUL|CROWD_CONTROL", false)
    wow.setAuraFiltered("player", AURA_ID, "HARMFUL|CROWD_CONTROL", false)
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

-- ── Predict path (local player self-casts Time Stop) ─────────────────────────

fw.describe("Time Stop - Devastation Evoker predict (local player)", function()
    fw.before_each(reset)

    fw.it("without talent data: TryPredictFromKnownCastId suppresses Dragonrage false-positive", function()
        -- Local player is Devastation Evoker, no PvP talent data decoded.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "EVOKER")
        mods.talents._setSpec("player", 1467)

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        -- Local player self-casts Time Stop (recorded in CastSpellIdSnapshot["player"]).
        wow.setTime(0)
        observer:_fireCast("player", 378441)

        local entry = loader.makeEntry("player")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "player" })

        -- TryPredictFromKnownCastId sees 378441 in window, no rule matches (talent gate fails),
        -- returns handled=true → falls through is blocked → Dragonrage not predicted.
        fw.is_nil(glowed, "Dragonrage must NOT be predicted; TryPredictFromKnownCastId blocks fallthrough")
    end)

    fw.it("with talent data: Time Stop correctly predicted via fast path", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "EVOKER")
        mods.talents._setSpec("player", 1467)
        mods.talents._setTalent("player", TIME_STOP_TALENT_IDS[1], true)

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        wow.setTime(0)
        observer:_fireCast("player", 378441)

        local entry = loader.makeEntry("player")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "player" })

        fw.eq(glowed, 378441, "Time Stop should be predicted when talent data is available")
        fw.neq(glowed, 375087, "Dragonrage must not be predicted")
    end)
end)

-- ── Commit path ───────────────────────────────────────────────────────────────

fw.describe("Time Stop - Devastation Evoker commit safety", function()
    fw.before_each(reset)

    fw.it("5s Time Stop removal does NOT commit Dragonrage (MinDuration=18 blocks it)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "EVOKER")
        mods.talents._setSpec("player", 1467)   -- no talent data

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        observer:_fireCast("player", 378441)

        local entry = loader.makeEntry("player")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "player" })

        wow.advanceTime(5.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "player" })

        fw.neq(committed, 375087, "Dragonrage must not commit on 5s Time Stop removal")
        fw.is_nil(committed, "no spell should be committed")
    end)

    fw.it("with talent data: Time Stop commits correctly at full duration", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "EVOKER")
        mods.talents._setSpec("player", 1467)
        mods.talents._setTalent("player", TIME_STOP_TALENT_IDS[1], true)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        observer:_fireCast("player", 378441)

        local entry = loader.makeEntry("player")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "player" })

        wow.advanceTime(5.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "player" })

        fw.eq(committed, 378441, "Time Stop should commit when talent data is known")
    end)

    fw.it("Dragonrage at full duration still commits correctly", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "EVOKER")
        mods.talents._setSpec("player", 1467)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        observer:_fireCast("player", 375087)

        local entry = loader.makeEntry("player")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "player" })

        wow.advanceTime(18.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "player" })

        fw.eq(committed, 375087, "Dragonrage should commit at full 18s duration")
    end)
end)

-- ── 3rd-party observer perspective ───────────────────────────────────────────
--
-- In 12.0.5 arena mode the observer never has cast evidence for a party member:
--   · RecordCast is a no-op for non-"player" units
--   · allowSyntheticCast=false for EVOKER in arena (not a precogIgnoreClasses melee class)
--   → No predict fires at all — not even a false Dragonrage.
--
-- In PvE (instanceType != arena/pvp), allowSyntheticCast=true and synthetic Cast would be
-- granted to the Evoker candidate, causing Dragonrage to be falsely predicted.  However,
-- Time Stop is a PvP-only talent that cannot be used in PvE, so this path is unreachable
-- in practice.

fw.describe("Time Stop - 3rd party observer (arena, 12.0.5 mode)", function()
    fw.before_each(reset)

    fw.it("observer has no cast evidence: Dragonrage is NOT predicted (allowSyntheticCast=false for EVOKER)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "EVOKER")
        mods.talents._setSpec("party1", 1467)
        -- No _fireCast: observer has no cast evidence (RecordCast no-op for non-local in 12.0.5)

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "party1" })

        fw.is_nil(glowed, "no Cast evidence + allowSyntheticCast=false: nothing should be predicted")
    end)

    fw.it("synthetic Cast is blocked for EVOKER in arena (precog guard)", function()
        -- Confirms the reason: EVOKER is not in precogIgnoreClasses, so IMPORTANT auras in
        -- arena never receive synthetic Cast (same as MAGE, PRIEST, etc.).
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "EVOKER")
        mods.talents._setSpec("party1", 1467)

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "party1" })

        fw.is_nil(glowed, "EVOKER in arena: precog guard suppresses synthetic Cast for IMPORTANT auras")
    end)
end)

fw.describe("Time Stop - 3rd party observer (PvE - hypothetical)", function()
    fw.before_each(reset)

    fw.it("PvE: synthetic Cast IS given and Dragonrage would be falsely predicted (PvP talent unreachable in practice)", function()
        -- instanceType = "none" (PvE overworld): allowSyntheticCast=true for any class.
        -- Time Stop cannot actually fire in PvE (PvP-only talent), so this is only a
        -- theoretical confirmation that the precog guard is what protects arena.
        wow.setInstanceType("none")
        wow.setUnitClass("party1", "EVOKER")
        mods.talents._setSpec("party1", 1467)

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "party1" })

        fw.eq(glowed, 375087, "PvE: synthetic Cast + IMPORTANT aura causes false Dragonrage predict (Time Stop is PvP-only so unreachable)")
    end)
end)

-- ── Augmentation Evoker: not vulnerable ───────────────────────────────────────

fw.describe("Time Stop - Augmentation Evoker is not vulnerable", function()
    fw.before_each(reset)

    fw.it("without talent data: no false predict on Augmentation Evoker", function()
        -- BySpec[1473] has Obsidian Scales (BigDefensive=true): needs BIG_DEFENSIVE aura type.
        -- Time Stop is IMPORTANT-only, so Obsidian Scales is always rejected.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "EVOKER")
        mods.talents._setSpec("player", 1473)

        local glowed = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) glowed = sid end)

        wow.setTime(0)
        observer:_fireCast("player", 378441)

        local entry = loader.makeEntry("player")
        observer:_fireAuraChanged(entry, makeTimeStopWatcher(), { "player" })

        fw.is_nil(glowed, "Aug Evoker: Obsidian Scales needs BIG_DEFENSIVE, never matches IMPORTANT-only")
    end)
end)
