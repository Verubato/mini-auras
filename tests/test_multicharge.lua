-- Multi-charge spell tracking tests.
--
-- Covers the charge-tracking paths in Brain.lua for spells that have >1 charge either as
-- a baseline (BaseCharges) or via a talent (MaxCharges + talent).
--
-- Section 1: Friendly commit - MaxCharges emitted from BaseCharges rule
--   · Commit for a BaseCharges=2 rule emits MaxCharges=2 in cdData (no talent needed)
--   · Commit for a MaxCharges=2 rule with talent emits MaxCharges=2 (talent mock override)
--
-- Section 2: B:PredictSpellId - multi-charge active cooldowns filter
--   · 1 of 2 charges used -> (spellId, false)  - charge is available, not on CD
--   · 2 of 2 charges used -> (spellId, true)   - all charges exhausted, blocked
--   · boolean cdEntry (single-charge format)   -> (spellId, true)  - backward-compat
--
-- Section 3: B:FindBestCandidate - alreadyOnCd with UsedCharges
--   · 1 of 2 charges used -> rule returned directly (charge available)
--   · 2 of 2 charges used -> rule returned as fallback (still committed, just blocked fast-path)
--
-- Section 4: Friendly predict via observer with activeCooldownsLookup
--   · Second charge: first charge recharging (1 of 2 used) -> glow fires
--   · All charges in use (2 of 2 used) -> glow blocked

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 5001  -- distinct from other test files

local BIG = { BIG_DEFENSIVE = true, IMPORTANT = true }
local IMP = { IMPORTANT = true }

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Captures the predictiveGlowCallback spellId; returns a getter.
local function captureGlow()
    local captured
    B:RegisterPredictiveGlowCallback(function(_, sid) captured = sid end)
    return function() return captured end
end

-- Captures the cooldownCallback's (ruleUnit, cdKey, cdData); returns a getter.
local function captureCommit()
    local unit, key, data
    B:RegisterCooldownCallback(function(u, k, d) unit, key, data = u, k, d end)
    return function() return unit, key, data end
end

-- IMPORTANT-only watcher for Zenith (spec 269 WW Monk).
local function makeImpWatcher()
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

-- A minimal UsedCharges entry (contents don't matter for Brain's count-based check).
local function usedCharge()
    return { Expiry = 9999, StartTime = 0 }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 1: Friendly commit emits correct MaxCharges
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Multi-charge commit - MaxCharges in cdData", function()
    fw.before_each(reset)

    -- Zenith (1249625): BaseCharges=2, Important=true, BuffDuration=15s, WW Monk spec 269.
    -- The mock talent module returns GetUnitMaxCharges=1; BaseCharges=2 floors it to 2.
    fw.it("BaseCharges=2 rule: commit emits MaxCharges=2 (no talent required)", function()
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("party1", 269)

        local getCommit = captureCommit()

        wow.setTime(0)
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeImpWatcher(), { "party1" })

        wow.advanceTime(15)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        local _, cdKey, cd = getCommit()
        fw.not_nil(cd, "cooldownCallback should have fired")
        fw.eq(cdKey, 1249625, "Zenith cdKey")
        fw.eq(cd.MaxCharges, 2, "MaxCharges=2 from BaseCharges floor")
    end)

    -- Prot Warrior Shield Wall (871): MaxCharges=2, talent 397103 grants the 2nd charge.
    -- Override GetUnitMaxCharges on the mock to return 2 (simulates talent active).
    fw.it("MaxCharges=2 rule with talent: commit emits MaxCharges=2", function()
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 73)  -- Protection

        -- Patch the mock talent to return 2 charges for this unit.
        local origFn = mods.talents.GetUnitMaxCharges
        mods.talents.GetUnitMaxCharges = function(self, unit, specId, classToken, abilityId)
            if abilityId == 871 then return 2 end
            return 1
        end

        local getCommit = captureCommit()

        wow.setTime(0)
        wow.setAuraFiltered("party1", AURA_ID + 1, "HELPFUL|EXTERNAL_DEFENSIVE", true)
        local watcher = loader.makeWatcher(
            { { AuraInstanceID = AURA_ID + 1 } },
            { { AuraInstanceID = AURA_ID + 1 } }
        )
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        wow.advanceTime(8)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        -- Restore mock.
        mods.talents.GetUnitMaxCharges = origFn

        local _, cdKey, cd = getCommit()
        fw.not_nil(cd, "cooldownCallback should have fired")
        fw.eq(cdKey, 871, "Shield Wall cdKey")
        fw.eq(cd.MaxCharges, 2, "MaxCharges=2 from talent-granted charges")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 2: B:PredictSpellId - multi-charge active cooldowns filter
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("PredictSpellId - multi-charge active cooldowns", function()
    fw.before_each(function()
        reset()
        wow.setUnitClass("arena1", "MONK")
        mods.talents._setSpec("arena1", 269)  -- Windwalker
    end)

    local evidence = { Cast = true }

    fw.it("1 of 2 charges used -> isOnCd=false (charge available)", function()
        local activeCooldowns = {
            [1249625] = { MaxCharges = 2, UsedCharges = { usedCharge() } }
        }
        local spellId, onCd = B:PredictSpellId("arena1", IMP, evidence, activeCooldowns)
        fw.eq(spellId, 1249625, "Zenith should be returned")
        fw.eq(onCd, false, "1 of 2 charges used - one charge still available")
    end)

    fw.it("2 of 2 charges used -> isOnCd=true (all charges exhausted)", function()
        local activeCooldowns = {
            [1249625] = { MaxCharges = 2, UsedCharges = { usedCharge(), usedCharge() } }
        }
        local spellId, onCd = B:PredictSpellId("arena1", IMP, evidence, activeCooldowns)
        fw.eq(spellId, 1249625, "Zenith should still be returned alongside isOnCd")
        fw.eq(onCd, true, "2 of 2 charges used - all charges exhausted")
    end)

    fw.it("boolean cdEntry (single-charge format) -> isOnCd=true", function()
        -- Pre-existing callers pass true/false rather than a full table.
        local activeCooldowns = { [1249625] = true }
        local spellId, onCd = B:PredictSpellId("arena1", IMP, evidence, activeCooldowns)
        fw.eq(spellId, 1249625, "Zenith")
        fw.eq(onCd, true, "boolean true -> treated as fully on cooldown")
    end)

    fw.it("entry nil (no charges used) -> isOnCd=false", function()
        local activeCooldowns = {}
        local spellId, onCd = B:PredictSpellId("arena1", IMP, evidence, activeCooldowns)
        fw.eq(spellId, 1249625, "Zenith")
        fw.eq(onCd, false, "no CD entry -> off cooldown")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 3: B:FindBestCandidate - alreadyOnCd with UsedCharges
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("FindBestCandidate - multi-charge alreadyOnCd check", function()
    fw.before_each(function()
        reset()
        wow.setUnitClass("arena1", "MONK")
        mods.talents._setSpec("arena1", 269)
    end)

    local function makeTracked(activeCooldowns)
        return {
            StartTime           = 1.0,
            AuraTypes           = IMP,
            Evidence            = { Cast = true },
            CastSnapshot        = { ["arena1"] = 1.0 },
            CastSpellIdSnapshot = {},
        }, activeCooldowns
    end

    fw.it("1 of 2 charges used -> rule returned directly (fast-path, charge available)", function()
        local activeCooldowns = {
            [1249625] = { MaxCharges = 2, UsedCharges = { usedCharge() } }
        }
        local tracked, _ = makeTracked(activeCooldowns)
        local entry = loader.makeEntry("arena1", activeCooldowns)
        local rule, unit = B:FindBestCandidate(entry, tracked, 15.0, {}, { IgnoreTalentRequirements = true })
        fw.not_nil(rule, "rule should be returned when 1 of 2 charges is in use")
        fw.eq(rule.SpellId, 1249625, "Zenith")
        fw.eq(unit, "arena1")
    end)

    fw.it("2 of 2 charges used -> rule still returned via fallback", function()
        -- When all charges are used, alreadyOnCd=true skips the direct return but stores the
        -- rule as fallback.  FindBestCandidate still returns it so the cooldown can be committed.
        local activeCooldowns = {
            [1249625] = { MaxCharges = 2, UsedCharges = { usedCharge(), usedCharge() } }
        }
        local tracked, _ = makeTracked(activeCooldowns)
        local entry = loader.makeEntry("arena1", activeCooldowns)
        local rule, unit = B:FindBestCandidate(entry, tracked, 15.0, {}, { IgnoreTalentRequirements = true })
        fw.not_nil(rule, "rule returned via fallback even when all charges used")
        fw.eq(rule.SpellId, 1249625, "Zenith")
    end)

    fw.it("no CD entry -> rule returned, not considered on cooldown", function()
        local tracked, _ = makeTracked({})
        local entry = loader.makeEntry("arena1", {})
        local rule = B:FindBestCandidate(entry, tracked, 15.0, {}, { IgnoreTalentRequirements = true })
        fw.not_nil(rule, "rule returned when no CD entry exists")
        fw.eq(rule.SpellId, 1249625, "Zenith")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 4: Friendly predict via observer with activeCooldownsLookup
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Multi-charge friendly predict - activeCooldownsLookup gate", function()
    fw.before_each(reset)

    fw.it("second charge: 1 of 2 used -> predictiveGlow fires", function()
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("party1", 269)

        -- Simulate: first charge is already recharging.
        local activeCooldowns = {
            [1249625] = { MaxCharges = 2, UsedCharges = { usedCharge() } }
        }
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party1" then return activeCooldowns end
        end)

        local getGlow = captureGlow()
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeImpWatcher(), { "party1" })

        fw.eq(getGlow(), 1249625, "second charge predicted - one charge still available")
    end)

    fw.it("both charges in use: 2 of 2 used -> predictiveGlow blocked", function()
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("party1", 269)

        -- Simulate: both charges are recharging - no charge available.
        local activeCooldowns = {
            [1249625] = { MaxCharges = 2, UsedCharges = { usedCharge(), usedCharge() } }
        }
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party1" then return activeCooldowns end
        end)

        local getGlow = captureGlow()
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeImpWatcher(), { "party1" })

        fw.is_nil(getGlow(), "both charges in use - glow blocked (isOnCd=true)")
    end)
end)
