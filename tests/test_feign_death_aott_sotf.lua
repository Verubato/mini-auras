-- Tests for Aspect of the Turtle (AotT) vs Survival of the Fittest (SotF)
-- disambiguation via evidence routing.
--
-- Both spells appear as BIG_DEFENSIVE+IMPORTANT auras on a Hunter.  The rules
-- are identical in aura type; evidence is the only discriminator:
--
--   AotT (186265)   RequiresEvidence = "UnitFlags"
--                   CanCancelEarly=true, BuffDuration=8
--                   UnitFlags fires when the Hunter mimics FeignDeath (body-on-floor signal).
--
--   SotF (264735)   4 class rules sharing the same SpellId:
--     6s PetAura    RequiresEvidence = "PetAura"   (pet active confirms SotF over AotT)
--     8s PetAura    RequiresEvidence = "PetAura"   (+2s talent variant)
--     6s Exclude    RequiresEvidence = {Exclude="UnitFlags"}  (no FD signal = not AotT)
--     8s Exclude    RequiresEvidence = {Exclude="UnitFlags"}  (+2s talent variant)
--                   All four are MinDuration=true; match when dur >= BuffDuration - 0.5.
--
-- Key clash scenarios:
--   + UnitFlags, no PetAura  → AotT  (SotF-Exclude blocked; SotF-PetAura missing evidence)
--   + no evidence            → SotF  (AotT missing UnitFlags; SotF-Exclude passes)
--   + PetAura, no UnitFlags  → SotF  (AotT missing UnitFlags; SotF-PetAura matches)
--   + UnitFlags + PetAura    → AotT  (UnitFlags present; SotF-Exclude blocked regardless)
--
-- Regression targets:
--   · Removing RequiresEvidence from AotT → AotT matches without UnitFlags → false AotT commits
--   · Removing {Exclude="UnitFlags"} from SotF → SotF-Exclude matches when AotT should win
--   · Changing MinDuration to CanCancelEarly on SotF → SotF matches at very short durations

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 9201   -- distinct from other test files

local BIG_IMP = { BIG_DEFENSIVE = true, IMPORTANT = true }
local AOTT    = 186265
local SOTF    = 264735

local ECD_OPTS = { IgnoreTalentRequirements = true }

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

local function makeTracked(evidence)
    return {
        StartTime           = 1.0,
        AuraTypes           = BIG_IMP,
        Evidence            = evidence,
        CastSnapshot        = {},
        CastSpellIdSnapshot = {},
    }
end

-- Build a BIG_DEFENSIVE+IMPORTANT watcher for the friendly-path tests.
-- Must be called after reset() because it mutates wow.setAuraFiltered state.
local function makeBigImpWatcher(unit)
    -- Mark the aura as absent from the EXTERNAL_DEFENSIVE filter so the observer
    -- classifies it as BIG_DEFENSIVE (not EXT).
    wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
    return loader.makeWatcher(
        { { AuraInstanceID = AURA_ID } },   -- defensive list  (gives BIG_DEFENSIVE)
        { { AuraInstanceID = AURA_ID } }    -- important list  (gives IMPORTANT)
    )
end

-- ── Enemy path: UnitFlags present → AotT wins ────────────────────────────────

fw.describe("AotT vs SotF - UnitFlags evidence routes to AotT (enemy path)", function()
    fw.before_each(reset)

    fw.it("UnitFlags evidence at 6s → AotT committed, SotF-Exclude blocked", function()
        -- SotF-Exclude requires UnitFlags to be ABSENT; with UnitFlags present the Exclude
        -- check fails for all SotF-Exclude variants.  AotT (RequiresEvidence=UnitFlags) wins.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked({ UnitFlags = true }), 6.0, {}, ECD_OPTS)
        fw.not_nil(rule, "AotT should match with UnitFlags evidence at 6s")
        fw.eq(rule and rule.SpellId, AOTT, "SpellId must be AotT (186265), not SotF (264735)")
    end)

    fw.it("UnitFlags evidence at 3s (early cancel) → AotT still committed", function()
        -- AotT is CanCancelEarly with no MinCancelDuration, so any duration ≤ 8.5s matches.
        -- This ensures early cancels (Hunter cancelled AotT at 3s) are still attributed.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked({ UnitFlags = true }), 3.0, {}, ECD_OPTS)
        fw.not_nil(rule, "AotT (CanCancelEarly) should match at 3s with UnitFlags")
        fw.eq(rule and rule.SpellId, AOTT, "SpellId must be AotT even at short early-cancel duration")
    end)

    fw.it("UnitFlags evidence → SotF (264735) is never committed", function()
        -- SotF-Exclude: {Exclude="UnitFlags"} with UnitFlags present → EvidenceMatchesReq
        -- returns false.  SotF-PetAura: RequiresEvidence="PetAura" not present → false.
        -- Neither SotF variant can match.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked({ UnitFlags = true }), 6.0, {}, ECD_OPTS)
        if rule then
            fw.neq(rule.SpellId, SOTF, "SotF must not commit when UnitFlags evidence is present")
        end
    end)
end)

-- ── Enemy path: UnitFlags absent → SotF wins ─────────────────────────────────

fw.describe("AotT vs SotF - absent UnitFlags routes to SotF (enemy path)", function()
    fw.before_each(reset)

    fw.it("no evidence at 6s → SotF committed, AotT missing UnitFlags", function()
        -- AotT: EvidenceMatchesReq("UnitFlags", nil) = false → skipped.
        -- SotF-Exclude 6s (MinDuration): Exclude passes (no UnitFlags), dur 6 ≥ 5.5 → matches.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked(nil), 6.0, {}, ECD_OPTS)
        fw.not_nil(rule, "SotF-Exclude should match without UnitFlags evidence at 6s")
        fw.eq(rule and rule.SpellId, SOTF, "SpellId must be SotF (264735), not AotT")
    end)

    fw.it("no evidence at 8s → SotF committed via 8s MinDuration variant", function()
        -- SotF-Exclude 8s (MinDuration): 8 ≥ 7.5 → matches.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked(nil), 8.0, {}, ECD_OPTS)
        fw.not_nil(rule, "SotF 8s MinDuration variant should match at 8s with no evidence")
        fw.eq(rule and rule.SpellId, SOTF, "SpellId must be SotF (264735)")
    end)

    fw.it("no evidence at 4s → nil (below SotF MinDuration floor, AotT missing UnitFlags)", function()
        -- SotF-6s MinDuration: 4 < 5.5 → no match.
        -- SotF-8s MinDuration: 4 < 7.5 → no match.
        -- AotT CanCancelEarly: evidence missing → no match.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked(nil), 4.0, {}, ECD_OPTS)
        fw.is_nil(rule, "4s aura with no evidence should not match AotT (missing UnitFlags) or SotF (below MinDuration)")
    end)

    fw.it("no evidence → AotT (186265) is never committed", function()
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked(nil), 6.0, {}, ECD_OPTS)
        if rule then
            fw.neq(rule.SpellId, AOTT, "AotT must not commit when UnitFlags evidence is absent")
        end
    end)
end)

-- ── Enemy path: PetAura present → SotF wins ──────────────────────────────────

fw.describe("AotT vs SotF - PetAura evidence routes to SotF (enemy path)", function()
    fw.before_each(reset)

    fw.it("PetAura evidence at 6s → SotF committed (AotT missing UnitFlags)", function()
        -- SotF-PetAura 6s (MinDuration): RequiresEvidence="PetAura" satisfied, 6 ≥ 5.5 → matches.
        -- AotT: EvidenceMatchesReq("UnitFlags", {PetAura=true}) = false → skipped.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked({ PetAura = true }), 6.0, {}, ECD_OPTS)
        fw.not_nil(rule, "SotF-PetAura should match with PetAura evidence at 6s")
        fw.eq(rule and rule.SpellId, SOTF, "SpellId must be SotF (264735), not AotT")
    end)

    fw.it("PetAura evidence at 9s → SotF via 8s MinDuration variant", function()
        -- 9s is above the 8s BuffDuration, which is valid for MinDuration (9 ≥ 7.5).
        -- AotT CanCancelEarly: 9 ≤ 8.5 is false → AotT would not match regardless.
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked({ PetAura = true }), 9.0, {}, ECD_OPTS)
        fw.not_nil(rule, "SotF 8s MinDuration should match at 9s (MinDuration: 9 ≥ 7.5)")
        fw.eq(rule and rule.SpellId, SOTF, "SpellId must be SotF (264735)")
    end)

    fw.it("UnitFlags+PetAura evidence → AotT wins (UnitFlags takes priority)", function()
        -- Both evidence types present.  SotF-Exclude: blocked by UnitFlags in Exclude check.
        -- SotF-PetAura: PetAura present → would match. AotT: UnitFlags present → matches.
        -- Brain returns the first match; AotT rule is evaluated before SotF-PetAura if listed
        -- before it, but both are HUNTER class rules — the SpellId returned must be AotT (186265)
        -- because UnitFlags is definitive (AotT's RequiresEvidence is the positive signal).
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local rule  = B:FindBestCandidate(entry, makeTracked({ UnitFlags = true, PetAura = true }), 6.0, {}, ECD_OPTS)
        fw.not_nil(rule, "Some rule should match when both evidence types are present")
        fw.eq(rule and rule.SpellId, AOTT,
            "AotT should win when UnitFlags is present (SotF-Exclude blocked; AotT evidence matches)")
    end)
end)

-- ── Friendly path: observer pipeline via _fireUnitFlags / _firePetAura ────────

fw.describe("AotT vs SotF - friendly path commit disambiguation", function()
    fw.before_each(reset)

    fw.it("_fireUnitFlags before aura → AotT committed at 6s", function()
        -- Simulate a Hunter who triggered the UnitFlags signal (FeignDeath or AotT body-drop)
        -- before the aura appears.  Brain records UnitFlags evidence and routes to AotT.
        wow.setUnitClass("party1", "HUNTER")

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        observer:_fireUnitFlags("party1")  -- evidence recorded before aura appears

        local entry   = loader.makeEntry("party1")
        local watcher = makeBigImpWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        wow.advanceTime(6.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        fw.eq(committed, AOTT, "AotT should be committed when UnitFlags evidence was fired")
    end)

    fw.it("no evidence before aura → SotF committed at 6s, AotT not committed", function()
        -- No UnitFlags event → AotT's RequiresEvidence="UnitFlags" unsatisfied.
        -- SotF-Exclude {Exclude="UnitFlags"}: evidence is nil, Exclude passes → matches.
        wow.setUnitClass("party1", "HUNTER")

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        local entry   = loader.makeEntry("party1")
        local watcher = makeBigImpWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        wow.advanceTime(6.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        fw.eq(committed, SOTF, "SotF should be committed when no UnitFlags evidence was fired")
    end)

    fw.it("_firePetAura before aura → SotF committed (PetAura variant, not AotT)", function()
        -- Pet aura evidence routes to SotF-PetAura.  AotT still missing UnitFlags.
        wow.setUnitClass("party1", "HUNTER")

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        observer:_firePetAura("party1")  -- pet aura evidence

        local entry   = loader.makeEntry("party1")
        local watcher = makeBigImpWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        wow.advanceTime(6.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        fw.eq(committed, SOTF, "SotF should be committed when PetAura evidence was fired")
    end)

    fw.it("_fireUnitFlags → AotT; then no UnitFlags → SotF (evidence isolated per aura)", function()
        -- Two consecutive auras on the same unit: first with UnitFlags (AotT), then without.
        -- Evidence must not bleed between tracking entries.
        wow.setUnitClass("party1", "HUNTER")

        local commits = {}
        B:RegisterCooldownCallback(function(_, cdKey) commits[#commits + 1] = cdKey end)

        local entry    = loader.makeEntry("party1")

        -- First aura: UnitFlags fired → AotT.
        wow.setTime(0)
        observer:_fireUnitFlags("party1")
        local watcher1 = makeBigImpWatcher("party1")
        observer:_fireAuraChanged(entry, watcher1, { "party1" })
        wow.advanceTime(6.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        -- Second aura: no UnitFlags → SotF.
        wow.setTime(100)
        local watcher2 = makeBigImpWatcher("party1")
        observer:_fireAuraChanged(entry, watcher2, { "party1" })
        wow.advanceTime(6.0)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        fw.eq(commits[1], AOTT, "First aura (UnitFlags) should commit AotT")
        fw.eq(commits[2], SOTF, "Second aura (no evidence) should commit SotF, not AotT")
    end)
end)
