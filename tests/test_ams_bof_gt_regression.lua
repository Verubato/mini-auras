-- Regression tests for two related FindBestCandidate scenarios:
--
--   1. DK Anti-Magic Shell vs Paladin Blessing of Freedom (betterCOO fix)
--      When a DK's AMS aura appears as IMPORTANT-only (not BIG_DEFENSIVE) from a remote
--      observer's client, the Spellwarding AMS rule (RequiresEvidence=Shield) correctly
--      wins over BoF (no RequiresEvidence) even though the Paladin is a non-target
--      CastableOnOthers candidate.  The betterCOO guard prevents a no-evidence rule from
--      displacing an evidence-constrained match.
--
--   2. Grounding Totem spillover suppression (IsProbablyGroundingTotem)
--      When a shaman with a Grounding Totem PvP talent is in the group, short IMPORTANT
--      auras on non-shaman allies are suppressed so they do not trigger false cooldowns.
--      The suppression is lifted when Shield evidence is present (can't be GT) or when
--      the target IS the shaman (GT committed directly via the shaman's rule).
--
-- Rule constants used:
--   AMS Spellwarding  SpellId 48707  DEATHKNIGHT class, BigDefensive=false, Important=true,
--                                    CastableOnOthers=true, RequiresEvidence=Shield,
--                                    BuffDuration 5s or 7s, CanCancelEarly
--   BoF               SpellId 1044   PALADIN class, BigDefensive=false, Important=true,
--                                    CastableOnOthers=true, BuffDuration 8s, CanCancelEarly
--   Grounding Totem   SpellId 204336 SHAMAN class, BigDefensive=false, Important=true,
--                                    BuffDuration 3.5s, CanCancelEarly, MinCancelDuration=0.5,
--                                    RequiresTalent={3620,3622,715}

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods = loader.get()
local B    = mods.brain

local IMP = { IMPORTANT = true }

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

local function makeTracked(auraTypes, startTime, castSnapshot, evidence, castSpellIdSnapshot)
    return {
        StartTime           = startTime or 1.0,
        AuraTypes           = auraTypes,
        Evidence            = evidence,
        CastSnapshot        = castSnapshot or {},
        CastSpellIdSnapshot = castSpellIdSnapshot or {},
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 1: DK AMS vs Paladin BoF (betterCOO regression)
--
-- Scenario: from a shaman group-member's perspective the DK's AMS aura is only
-- visible under HELPFUL|IMPORTANT (not BIG_DEFENSIVE).  UNIT_ABSORB_AMOUNT_CHANGED
-- fires on the shaman's client so Shield evidence IS present.  The betterCOO
-- logic previously let the Paladin's BoF (no RequiresEvidence) displace the DK's
-- Spellwarding AMS (RequiresEvidence=Shield) because betterCOO fired before the
-- evidence tiebreaker.  With the fix, the evidence-constrained match is preserved.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("AMS vs BoF - betterCOO regression (DK is the target)", function()
    fw.before_each(reset)

    fw.it("AMS committed for DK target when Shield evidence present and Paladin is in group", function()
        -- party1 = DK (target).  The AMS aura is IMPORTANT-only from the observer's
        -- perspective; Shield evidence is detected via UNIT_ABSORB_AMOUNT_CHANGED.
        -- party2 = Paladin (candidate).  BoF has no RequiresEvidence and would normally
        -- match an IMPORTANT aura when betterCOO fires, but the fix gates betterCOO so
        -- an evidence-constrained existing match (AMS, Shield req.) cannot be displaced
        -- by a no-evidence new rule (BoF).
        wow.setUnitClass("party1", "DEATHKNIGHT")
        wow.setUnitClass("party2", "PALADIN")
        local entry = loader.makeEntry("party1")
        -- Duration 6.01: within AMS Spellwarding 7s CanCancelEarly window (<=7.5),
        -- and also within BoF 8s window (<=8.5), so both rules can match on duration.
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2" })
        fw.not_nil(rule, "AMS should be committed, not suppressed or replaced by BoF")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS (48707), not BoF (1044)")
        fw.eq(unit, "party1", "DK (party1) is the caster (self-cast AMS)")
    end)

    fw.it("BoF committed for Paladin when Shield evidence is absent (no AMS match)", function()
        -- Without Shield evidence the Spellwarding AMS rule cannot match (RequiresEvidence=Shield).
        -- No other DK IMPORTANT rule matches an IMP-only aura.  The Paladin's BoF (no evidence
        -- requirement) is the only match -> correctly committed.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        wow.setUnitClass("party2", "PALADIN")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2" })
        fw.not_nil(rule, "BoF should match when no Shield evidence is present")
        fw.eq(rule and rule.SpellId, 1044, "SpellId should be BoF (1044)")
        fw.eq(unit, "party2", "Paladin (party2) is attributed as the caster")
    end)

    fw.it("AMS committed for DK when no Paladin is in the group", function()
        -- Baseline: DK with Shield evidence, no competing Paladin.  AMS should always match.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, {})
        fw.not_nil(rule, "AMS should match with no competing candidates")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS")
        fw.eq(unit, "party1", "DK is the caster")
    end)

    fw.it("betterCOO still fires when Paladin target self-matches BoF and DK (non-target) matches AMS", function()
        -- Symmetric case: Paladin is the TARGET (self-matching BoF, a CastableOnOthers rule).
        -- DK is the non-target candidate with AMS (different CastableOnOthers rule, has Shield evidence).
        -- betterCOO guard: existing rule=BoF (no RequiresEvidence), new=AMS (has RequiresEvidence)
        -- -> guard does NOT block betterCOO (guard only blocks when existing has evidence, new does not).
        -- The elseif evidence-tiebreaker replaces BoF with AMS because AMS has RequiresEvidence.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "DEATHKNIGHT")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2" })
        fw.not_nil(rule, "AMS should win over Paladin self-match BoF when Shield evidence present")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS (not BoF)")
        fw.eq(unit, "party2", "DK (party2) is the attributed caster")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 2: Grounding Totem spillover suppression
--
-- When a shaman with a GT PvP talent is in the group, short IMPORTANT auras on
-- non-shaman allies are suppressed (IsProbablyGroundingTotem returns true ->
-- searchNonExternal returns early -> FindBestCandidate returns nil).
--
-- Suppression is lifted when:
--   a) Shield evidence is present (GT never grants shields to allies)
--   b) The measured duration exceeds groundingTotemMaxDuration + tolerance (4s)
--   c) The aura is BIG_DEFENSIVE (GT is never BIG_DEFENSIVE)
--   d) The target IS the shaman (the GT rule matches directly; no suppression needed)
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Grounding Totem spillover suppression", function()
    fw.before_each(reset)

    fw.it("short IMPORTANT aura on non-shaman target is suppressed when shaman has GT talent", function()
        -- Warrior (party1) receives a short IMPORTANT buff while a shaman with GT talent
        -- (party2) is in the group.  IsProbablyGroundingTotem fires -> no cooldown committed.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        -- Duration 2.0: within GT 0.5-4.0s window.
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "GT spillover suppression should prevent any cooldown being committed")
    end)

    fw.it("suppression does not fire when no shaman with GT talent is in the group", function()
        -- Paladin target self-matches BoF; shaman in group has no GT talent.
        -- IsProbablyGroundingTotem should return false -> normal matching proceeds.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "SHAMAN")
        -- party2 is a shaman but without a GT PvP talent.
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 5.0, { "party2" })
        fw.not_nil(rule, "BoF should match when shaman has no GT talent")
        fw.eq(rule and rule.SpellId, 1044, "Blessing of Freedom")
        fw.eq(unit, "party1", "Paladin is the caster (self-match)")
    end)

    fw.it("Grounding Totem commits for shaman target - suppression does not apply to shaman itself", function()
        -- The shaman (party1) is both the source and the target of GT.
        -- IsProbablyGroundingTotem short-circuits: shamanHasGroundingTotem(targetUnit) returns
        -- true -> function returns false (no suppression).  The GT rule then matches normally.
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)
        local entry = loader.makeEntry("party1")
        -- Duration 2.0: within GT MinCancelDuration(0.5)-BuffDuration+tolerance(4.0) window.
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, {})
        fw.not_nil(rule, "GT rule should commit for the shaman target")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem (204336)")
        fw.eq(unit, "party1", "Shaman is the caster")
    end)

    fw.it("Shield evidence bypasses suppression - AMS on DK tracked even when shaman has GT", function()
        -- DK (party1) self-casts AMS; Shield evidence is detected via UNIT_ABSORB_AMOUNT_CHANGED.
        -- Shaman (party2) has GT talent, but Shield evidence signals this can't be GT spillover.
        -- IsProbablyGroundingTotem returns false -> AMS matches normally.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        local entry = loader.makeEntry("party1")
        -- Duration 2.0: short (within GT window) but Shield evidence rules out GT.
        -- AMS Spellwarding 5s variant: CanCancelEarly, 2.0 <= 5.5 -> matches.
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.not_nil(rule, "AMS should be committed - Shield evidence bypasses GT suppression")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS (48707), not suppressed")
        fw.eq(unit, "party1", "DK (party1) is the caster")
    end)

    fw.it("long aura bypasses GT suppression - BoF tracked when duration exceeds GT threshold", function()
        -- Paladin (party1) self-matches BoF at 5.0s duration; shaman (party2) has GT talent.
        -- IsProbablyGroundingTotem: 5.0 > groundingTotemMaxDuration(3.5) + tolerance(0.5) = 4.0
        -- -> returns false -> no suppression -> BoF committed normally.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        local entry = loader.makeEntry("party1")
        -- BoF: BuffDuration=8, CanCancelEarly, 5.0 <= 8.5 -> matches.
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 5.0, { "party2" })
        fw.not_nil(rule, "BoF should commit when aura duration exceeds GT maximum")
        fw.eq(rule and rule.SpellId, 1044, "Blessing of Freedom")
        fw.eq(unit, "party1", "Paladin is the caster (self-match)")
    end)

    fw.it("GT suppression fires for any valid GT PvP talent variant", function()
        -- GT is granted by talent IDs 3620, 3622, and 715 (one per spec).
        -- Verify that talent 715 (another variant) also triggers suppression.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 715, true)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "GT suppression should fire for talent 715 too")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 3: Two-shaman GT disambiguation via cast snapshot
--
-- When two shamans both have the GT PvP talent and both receive the GT buff,
-- UNIT_SPELLCAST_SUCCEEDED (fires only for the local player on 12.0.5+) is used
-- to determine who actually pressed GT:
--
--   Case A: local player is the target shaman and their cast snapshot has no GT
--           cast within the window -> local player did NOT press GT; suppress their
--           commit so the other shaman is attributed.
--
--   Case B: target is a remote shaman; local player's snapshot proves they pressed
--           GT (SpellId 204336 within castWindow) and they have GT talent -> remote
--           shaman's commit is suppressed; local player's commit proceeds normally.
--
-- Without cast evidence (no snapshot key or empty list) and no PvP context, neither
-- case fires and the existing fall-through behaviour is preserved.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Two-shaman GT disambiguation via cast snapshot", function()
    fw.before_each(reset)

    -- Helper: alias party1 to the local player and set up both shamans with GT talent.
    local function setupTwoShamans()
        wow.setInstanceType("arena")
        -- party1 is the local player (GUID aliased so ResolveSnapshotUnit("party1") = "player").
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player",  "SHAMAN")
        wow.setUnitClass("party1",  "SHAMAN")
        wow.setUnitClass("party2",  "SHAMAN")
        mods.talents._setTalent("player",  3620, true)
        mods.talents._setTalent("party1",  3620, true)
        mods.talents._setTalent("party2",  3620, true)
    end

    fw.it("Case A: local player (party1) with no GT cast is suppressed", function()
        -- Both shamans receive the GT buff.  Local player (party1) has no GT cast in their
        -- snapshot -> they did not press GT -> their commit is suppressed.
        setupTwoShamans()
        local entry = loader.makeEntry("party1")
        -- CastSpellIdSnapshot has no "player" key -> local player provably cast nothing.
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "local player shaman should be suppressed when they cast no GT")
    end)

    fw.it("Case A: remote shaman (party2) still commits GT when local player cast nothing", function()
        -- Symmetric half of Case A: from party2's perspective (remote shaman as the entry),
        -- local player has no GT cast -> Case B does not fire -> GT commits normally for party2.
        setupTwoShamans()
        local entry = loader.makeEntry("party2")
        local t = makeTracked(IMP, 1.0, {}, nil, {})
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party1" })
        fw.not_nil(rule, "remote shaman (party2) should commit GT when local player cast nothing")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem")
        fw.eq(unit, "party2", "party2 is the attributed caster")
    end)

    fw.it("Case B: remote shaman (party2) suppressed when local player's snapshot has GT cast", function()
        -- Local player (party1) pressed GT; their snapshot proves it.
        -- party2 (remote shaman) receives the spillover buff; their commit is suppressed.
        setupTwoShamans()
        local entry = loader.makeEntry("party2")
        -- castSpellIdSnapshot keyed under "player" with a GT cast at t=1.0 (= tracked.StartTime).
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 1.0 } } }
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party1" })
        fw.is_nil(rule, "remote shaman (party2) suppressed when local player provably pressed GT")
    end)

    fw.it("Case B: local player (party1) commits GT when their snapshot has a GT cast", function()
        -- Symmetric half of Case B: from party1's perspective (local player as the entry),
        -- localPressedGT=true -> suppression loop skipped -> GT commits for party1.
        setupTwoShamans()
        local entry = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 1.0 } } }
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.not_nil(rule, "local player (party1) should commit GT when their snapshot has the cast")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem")
        fw.eq(unit, "party1", "party1 (local player) is the attributed caster")
    end)

    fw.it("Case A: local player tracked as 'player' commits GT despite other shaman sorting first", function()
        -- Real-game regression: local player's aura is tracked under unit "player".
        -- Another shaman is "party1". "party1" < "player" alphabetically, so the tiebreaker
        -- would suppress "player" without the localPressedGT early-return fix.
        setupTwoShamans()
        local entry = loader.makeEntry("player")
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 1.0 } } }
        local t = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party1" })
        fw.not_nil(rule, "local player should commit GT when they provably pressed it")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem")
        fw.eq(unit, "player", "player is the attributed caster")
    end)

    fw.it("Tiebreaker: 3rd-party observer - party1 (sorts first) commits, party2 suppressed", function()
        -- Rogue (local player, not a shaman) watches two GT shamans.  No cast evidence available.
        -- Tiebreaker: party1 < party2 by unit string, so party2 is suppressed and party1 commits.
        -- No GUID aliasing: neither shaman resolves to "player".
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "SHAMAN")
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)
        mods.talents._setTalent("party2", 3620, true)
        local t = makeTracked(IMP, 1.0, {}, nil, {})

        -- party1 entry: no GT shaman candidate sorts earlier than "party1" -> commits.
        local entry1 = loader.makeEntry("party1")
        local rule1, unit1 = B:FindBestCandidate(entry1, t, 2.0, { "party2" })
        fw.not_nil(rule1, "party1 (sorts first) should commit GT")
        fw.eq(rule1 and rule1.SpellId, 204336, "SpellId should be Grounding Totem")
        fw.eq(unit1, "party1", "party1 is the attributed caster")

        -- party2 entry: party1 sorts earlier -> party2 suppressed.
        local entry2 = loader.makeEntry("party2")
        local rule2 = B:FindBestCandidate(entry2, t, 2.0, { "party1" })
        fw.is_nil(rule2, "party2 (sorts later) should be suppressed by the tiebreaker")
    end)
end)
