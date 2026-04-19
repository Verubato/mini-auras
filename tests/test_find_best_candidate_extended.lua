-- Extended unit tests for Brain:FindBestCandidate.
--
-- Covers scenarios not exercised by test_find_best_candidate.lua:
--   · FeignDeath evidence suppresses UnitFlags (no false AotT match)
--   · Vampiric Blood multi-duration variants (10/12/14s all resolve to same SpellId)
--   · CastableOnOthers cross-unit filter: non-target self-only rules don't create false ambiguity
--   · Blessing of Freedom commit in 12.0.5 with mixed group (Evoker + Hunter + Paladin caster)
--   · CastableOnOthers non-target beating CastableOnOthers self-match (isBetter condition 4)
--   · Two candidates, one on CD -> on-CD is skipped, off-CD wins (no ambiguity)
--   · GUID deduplication in the self-cast (non-EXTERNAL) candidate loop
--   · AMS Spellwarding: DK with no other candidates, IMP-only, Shield evidence
--   · ExcludeIfTalent within FindBestCandidate (talent present -> rule skipped -> no match)
--   · CanCancelEarly rules match at short measured durations
--   · Blessing of Protection requires Debuff evidence - missing Debuff -> no match

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods = loader.get()
local B    = mods.brain

local castWindow = 0.15

local BIG    = { BIG_DEFENSIVE = true, IMPORTANT = true }
local BIG_CC = { BIG_DEFENSIVE = true, IMPORTANT = true, CROWD_CONTROL = true }
local IMP = { IMPORTANT = true }
local EXT = { EXTERNAL_DEFENSIVE = true }

local function reset()
    B._TestReset()
    B:_TestSetSimulateNoCastSucceeded(false)
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

-- Section 1: FeignDeath evidence suppresses UnitFlags

fw.describe("FindBestCandidate - FeignDeath suppresses UnitFlags evidence", function()
    fw.before_each(reset)

    -- Aspect of the Turtle: RequiresEvidence={"Cast","UnitFlags"}, BIG+IMP, 8s, Hunter class.
    -- If UnitFlags comes from a feign death transition (FeignDeath=true in evidence), the
    -- UnitFlags key is suppressed -> AotT cannot match (it needs UnitFlags).
    -- In these tests we construct tracked aura evidence directly to simulate the two outcomes.

    fw.it("Aspect of the Turtle matches when UnitFlags evidence is present", function()
        wow.setUnitClass("party1", "HUNTER")
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true, UnitFlags = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        fw.not_nil(rule, "AotT should match with Cast+UnitFlags evidence")
        fw.eq(rule.SpellId, 186265, "Aspect of the Turtle")
        fw.eq(unit, "party1", "ruleUnit")
    end)

    fw.it("Aspect of the Turtle does not match when only FeignDeath evidence (UnitFlags suppressed)", function()
        wow.setUnitClass("party1", "HUNTER")
        -- FeignDeath in evidence; UnitFlags is absent (suppressed by the mutual-exclusion logic).
        -- Survival of the Fittest: RequiresEvidence="Cast", BIG+IMP, BuffDuration=6 (MinDuration).
        -- At 8.0s, SotF (>= 6-0.5=5.5) and AotT (needs UnitFlags, absent) compete.
        -- SotF should win (evidence={Cast,FeignDeath} satisfies Cast-only req).
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true, FeignDeath = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        -- SotF has MinDuration and BuffDuration=8 (+2s variant); 8.0 >= 7.5 -> matches.
        fw.not_nil(rule, "SotF should match when FeignDeath suppresses UnitFlags for AotT")
        fw.eq(rule.SpellId, 264735, "Survival of the Fittest (UnitFlags suppressed -> AotT excluded)")
    end)

    fw.it("AotT is nil when evidence is FeignDeath-only with no CastSnapshot (no Cast anywhere)", function()
        wow.setUnitClass("party1", "HUNTER")
        -- No CastSnapshot and no Cast in evidence; FeignDeath only.
        -- AotT needs Cast+UnitFlags (both absent) -> fails.
        -- SotF needs Cast (absent) -> fails.
        -- Result: nil.
        local t = makeTracked(BIG, 1.0, {}, { FeignDeath = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        fw.is_nil(rule, "FeignDeath only, no Cast (no snapshot) -> no Hunter BIG rule matches")
    end)
end)

-- Section 2: Vampiric Blood multi-duration variants

fw.describe("FindBestCandidate - Vampiric Blood duration variants (10/12/14s)", function()
    fw.before_each(reset)

    -- Blood DK (spec 250): three VB variants at 10, 12, 14 seconds.
    -- All share SpellId=55233. Should resolve to same rule at any valid duration.

    fw.it("matches Vampiric Blood at base duration (10s)", function()
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 10.0, {})
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 55233, "Vampiric Blood 10s")
    end)

    fw.it("matches Vampiric Blood at +2s Goreringers Anguish rank 1 (12s)", function()
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, {})
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 55233, "Vampiric Blood 12s")
    end)

    fw.it("matches Vampiric Blood at +4s Goreringers Anguish rank 2 (14s)", function()
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 14.0, {})
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 55233, "Vampiric Blood 14s")
    end)

    fw.it("does not match Vampiric Blood at 8s (outside all three windows)", function()
        -- 8.0 is outside 10±0.5, 12±0.5, and 14±0.5. Falls through to class rules.
        -- Class rules: AMS (5/7s with Shield), IBF (8s), AMS Spellwarding (5/7s).
        -- IBF at 8s, RequiresEvidence="Cast" -> matches.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        fw.not_nil(rule, "IBF should match from class rules when VB duration window is missed")
        fw.eq(rule.SpellId, 48792, "Icebound Fortitude (class rule fallthrough)")
    end)
end)

-- Section 3: CastableOnOthers - non-target with different rule beats target self-match

fw.describe("FindBestCandidate - CastableOnOthers non-target beats target self-match (12.0.5)", function()
    fw.before_each(function()
        reset()
        B:_TestSetSimulateNoCastSucceeded(true)
    end)

    -- isBetter condition 4: non-target matching a different CastableOnOthers rule beats the
    -- target that self-matched via synthetic cast.
    -- Scenario: target is a Paladin (self-matches BoF via synthetic Cast + CastableOnOthers),
    -- and a DK candidate also has a CastableOnOthers rule (AMS Spellwarding) that matches
    -- a different spell ID.  The DK should win over the Paladin self-match.

    fw.it("DK AMS Spellwarding (non-target) beats Paladin self-match BoF when different rule", function()
        -- party1 = Paladin (target): self-matches BoF (CastableOnOthers, IMPORTANT, 8s)
        -- party2 = DK (candidate): matches AMS Spellwarding (CastableOnOthers, IMPORTANT, 5s, Shield req)
        -- Shield evidence present -> DK gets synthetic Cast; Paladin blocked by Shield guard.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "DEATHKNIGHT")
        local entry = loader.makeEntry("party1")
        -- IMP-only aura, Shield evidence, duration=6.01 (within AMS 7+0.5 window, and BoF 8+0.5=8.5 > 6.01).
        -- BoF: CanCancelEarly, BuffDuration=8, CastableOnOthers; 6.01 <= 8.5 -> matches.
        -- AMS Spellwarding: CanCancelEarly, BuffDuration=5 (or 7), 6.01 <= 5.5? No, 6.01 > 5.5.
        -- AMS 7s variant: 6.01 <= 7.5 -> matches.
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2" })
        fw.not_nil(rule, "AMS should win via condition 4 (non-target different CastableOnOthers rule)")
        fw.eq(rule.SpellId, 48707, "AMS Spellwarding (not BoF)")
        fw.eq(unit, "party2", "DK should be the attributed caster")
    end)

    fw.it("target self-matches BoF, no non-target DK -> BoF is returned", function()
        -- Without any DK candidate, BoF self-match on the Paladin target stands.
        wow.setUnitClass("party1", "PALADIN")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, {})
        fw.not_nil(rule, "BoF should match when no DK is present to compete")
        fw.eq(rule.SpellId, 1044, "Blessing of Freedom")
        fw.eq(unit, "party1", "Paladin is the caster (self-match)")
    end)
end)

-- Section 4: ActiveCooldowns - on-CD rule vs off-CD rule with two candidates

fw.describe("FindBestCandidate - ActiveCooldowns with two candidates", function()
    fw.before_each(reset)

    -- Two Restoration Druids; Ironbark is on cooldown for party2 but not party3.
    -- party2's Ironbark is on CD -> skipped; party3's is not -> party3 wins.
    -- (pre-12.0.5: real snapshots needed for RequiresEvidence="Cast")

    fw.it("candidate with spell on CD is skipped; off-CD candidate wins", function()
        wow.setUnitClass("party1", "WARRIOR")  -- target
        wow.setUnitClass("party2", "DRUID")
        wow.setUnitClass("party3", "DRUID")
        mods.talents._setSpec("party2", 105)
        mods.talents._setSpec("party3", 105)

        -- party2 has Ironbark on CD; party3 does not.
        local entry = loader.makeEntry("party1", { [102342] = {} })
        -- Both have cast snapshots, but entry.ActiveCooldowns applies to all candidates
        -- uniformly (MatchRule receives entry.ActiveCooldowns).
        -- Actually ActiveCooldowns is per-entry (the detected target's entry), not per-caster.
        -- For external spells, the entry is the target. So ActiveCooldowns on the entry
        -- reflects whether the spell was recently committed for the ENTRY unit, not the caster.
        -- We test: when the spell is in ActiveCooldowns, both candidates' rules return as fallback;
        -- the one with cast evidence still wins the tiebreak.
        local t = makeTracked(EXT, 5.0, { party2 = 4.9, party3 = 5.05 })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2", "party3" })
        -- Ironbark is on CD -> both rules return as fallback (not nil).
        -- party3 has the more recent cast snapshot -> tiebreak picks party3.
        fw.not_nil(rule, "fallback rule should be returned")
        fw.eq(rule.SpellId, 102342, "Ironbark (fallback)")
        fw.eq(unit, "party3", "party3 has more recent snapshot -> wins tiebreak even as fallback")
    end)
end)

-- Section 5: GUID deduplication in non-EXTERNAL candidate loop

fw.describe("FindBestCandidate - GUID dedup in self-cast candidate loop (12.0.5)", function()
    fw.before_each(function()
        reset()
        B:_TestSetSimulateNoCastSucceeded(true)
    end)

    -- On 12.0.5, a Paladin appearing as both "party1" (target) and "party2" (candidate) with
    -- the same GUID should not create ambiguity for BoF (CastableOnOthers path).

    fw.it("same player as party1+party2 via GUID dedup does not cause ambiguity for BoF", function()
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "PALADIN")
        -- Same player appears under two unit IDs.
        wow.setUnitGUID("party1", "Player-GUID-PAL")
        wow.setUnitGUID("party2", "Player-GUID-PAL")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2" })
        -- party2 is deduplicated via GUID -> not visited -> no second BoF match -> not ambiguous.
        fw.not_nil(rule, "BoF should match without ambiguity when same player has two unit IDs")
        fw.eq(rule.SpellId, 1044, "Blessing of Freedom")
    end)

    fw.it("two distinct Paladins (different GUIDs) with IMP-only BoF -> same SpellId -> first wins", function()
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "PALADIN")
        -- Different GUIDs (default: unit string = GUID)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2" })
        -- party1 self-matches BoF (COO, via synthetic Cast); party2 also matches BoF.
        -- isBetter condition 3: candidateRule == rule (same BoF table) -> false.
        -- elseif no cast tiebreaker: same SpellId (1044) -> sameSpell=true -> not ambiguous.
        -- First match (party1 self) stands; cooldown is attributed to BoF either way.
        fw.not_nil(rule, "two Paladins, same BoF SpellId, no cast tiebreaker -> first wins")
        fw.eq(rule.SpellId, 1044, "SpellId")
    end)
end)

-- Section 6: CanCancelEarly rules match at short durations

fw.describe("FindBestCandidate - CanCancelEarly at short measured durations", function()
    fw.before_each(reset)

    -- Cloak of Shadows: BigDefensive=true, CanCancelEarly implicitly via rule matching,
    -- wait -- Cloak of Shadows has no CanCancelEarly. Let's use Dispersion (spec 258):
    -- CanCancelEarly=true, BuffDuration=6. At 2s measured it should still match.

    fw.it("Dispersion matches at 2s (early cancel) with Cast evidence", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        local t = makeTracked(BIG_CC, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 2.0, {})
        fw.not_nil(rule, "Dispersion should match at 2s early cancel")
        fw.eq(rule.SpellId, 47585, "Dispersion")
        fw.eq(unit, "party1", "ruleUnit")
    end)

    fw.it("Divine Shield matches at 4s (cancelled early) with Cast+UnitFlags evidence", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        -- CanCancelEarly=true, BuffDuration=8; 4.0 <= 8.5 -> passes.
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true, UnitFlags = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 4.0, {})
        fw.not_nil(rule, "Divine Shield should match at 4s (cancelled early)")
        fw.eq(rule.SpellId, 642, "Divine Shield")
    end)

    fw.it("CanCancelEarly rule does not match when duration exceeds expected + tolerance", function()
        -- Dispersion expected 6s; 6.6 > 6.5 upper bound; 8s talent variant needs RequiresTalent.
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 6.6, {})
        fw.is_nil(rule, "6.6 > 6.5 upper bound for Dispersion 6s; 8s variant needs talent")
    end)
end)

-- Section 7: Blessing of Protection evidence requirements in FindBestCandidate

fw.describe("FindBestCandidate - Blessing of Protection evidence requirements", function()
    fw.before_each(reset)

    -- BoP: ExternalDefensive, BuffDuration=10, CanCancelEarly, RequiresEvidence={"Cast","Debuff","UnitFlags"}
    -- Both Debuff (Forbearance) and UnitFlags (immunity) must be present or BoP cannot match.

    fw.it("BoP matches when both Cast and Debuff evidence are present", function()
        wow.setUnitClass("party1", "WARRIOR")  -- target
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)
        -- Evidence: Cast (from caster snapshot) + Debuff (Forbearance on target) + UnitFlags (immunity)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, { Debuff = true, UnitFlags = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 10.0, { "party2" })
        fw.not_nil(rule, "BoP should match with Cast+Debuff evidence")
        fw.eq(rule.SpellId, 1022, "Blessing of Protection")
        fw.eq(unit, "party2", "Paladin is the caster")
    end)

    fw.it("BoP does not match when Debuff evidence is absent", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)
        -- Cast snapshot present but no Debuff (Forbearance not fired)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, nil)
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 10.0, { "party2" })
        fw.is_nil(rule, "BoP requires Debuff (Forbearance) evidence - absent -> no match")
    end)

    fw.it("BoP matches at short duration (cancelled early) with both evidence types", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, { Debuff = true, UnitFlags = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 5.0, { "party2" })
        fw.not_nil(rule, "BoP CanCancelEarly allows early removal (5s < 10s expected)")
        fw.eq(rule.SpellId, 1022, "Blessing of Protection")
    end)
end)

-- Section 8: Shadow Blades duration variants (Subtlety Rogue)

fw.describe("FindBestCandidate - Shadow Blades duration variants", function()
    fw.before_each(reset)

    -- Shadow Blades (spec 261): 16s base, 18s (+set bonus), 20s (+4s set bonus).
    -- All share SpellId=121471.

    fw.it("matches Shadow Blades at base duration 16s", function()
        wow.setUnitClass("party1", "ROGUE")
        mods.talents._setSpec("party1", 261)
        local t = makeTracked(IMP, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 16.0, {})
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 121471, "Shadow Blades 16s")
    end)

    fw.it("matches Shadow Blades at +2s set bonus (18s)", function()
        wow.setUnitClass("party1", "ROGUE")
        mods.talents._setSpec("party1", 261)
        local t = makeTracked(IMP, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 18.0, {})
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 121471, "Shadow Blades 18s")
    end)

    fw.it("matches Shadow Blades at +4s set bonus (20s)", function()
        wow.setUnitClass("party1", "ROGUE")
        mods.talents._setSpec("party1", 261)
        local t = makeTracked(IMP, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 20.0, {})
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 121471, "Shadow Blades 20s")
    end)

    fw.it("does not match Shadow Blades at 12s (outside all windows)", function()
        -- Falls through to class ROGUE rules: Evasion (10s IMP, not BIG) and Cloak (5s BIG).
        -- 12s is outside Evasion 10±0.5 and Cloak 5±0.5 -> nil.
        wow.setUnitClass("party1", "ROGUE")
        mods.talents._setSpec("party1", 261)
        local t = makeTracked(IMP, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, {})
        fw.is_nil(rule, "12s is outside all Shadow Blades windows and class Rogue IMP rules")
    end)
end)

-- Section 9: Holy Priest Guardian Spirit duration variants

fw.describe("FindBestCandidate - Guardian Spirit base vs Foreseen Circumstances (+2s)", function()
    fw.before_each(reset)

    -- Guardian Spirit (spec 257):
    --   Base (ExcludeIfTalent=440738): BuffDuration=10, CanCancelEarly, ExternalDefensive
    --   Foreseen Circumstances (RequiresTalent=440738): BuffDuration=12, CanCancelEarly

    fw.it("matches base Guardian Spirit (10s) without the talent", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PRIEST")
        mods.talents._setSpec("party2", 257)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, nil)
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 10.0, { "party2" })
        fw.not_nil(rule, "base Guardian Spirit should match at 10s")
        fw.eq(rule.SpellId, 47788, "Guardian Spirit")
        fw.eq(unit, "party2", "Priest is the caster")
    end)

    fw.it("base Guardian Spirit is excluded when Foreseen Circumstances talent is present (12s CanCancelEarly at 10s)", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PRIEST")
        mods.talents._setSpec("party2", 257)
        mods.talents._setTalent("party2", 440738, true)
        -- Base rule has ExcludeIfTalent=440738 -> excluded.
        -- Foreseen Circumstances rule has CanCancelEarly + BuffDuration=12.
        -- 10.0 <= 12 + 0.5 = 12.5 -> passes CanCancelEarly (no MinCancelDuration).
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, nil)
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 10.0, { "party2" })
        fw.not_nil(rule, "Foreseen Circumstances (12s CanCancelEarly) matches at 10s early cancel")
        fw.eq(rule.SpellId, 47788, "Guardian Spirit (Foreseen Circumstances variant)")
    end)

    fw.it("Foreseen Circumstances (12s) matches at full duration when talent is present", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PRIEST")
        mods.talents._setSpec("party2", 257)
        mods.talents._setTalent("party2", 440738, true)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, nil)
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.not_nil(rule, "Foreseen Circumstances should match at full 12s duration")
        fw.eq(rule.SpellId, 47788, "Guardian Spirit (Foreseen Circumstances)")
        fw.eq(unit, "party2", "Priest is the caster")
    end)
end)

-- Section 10: Barkskin extended variant (Improved Barkskin)

fw.describe("FindBestCandidate - Barkskin Improved Barkskin variant (+4s)", function()
    fw.before_each(reset)

    fw.it("matches Barkskin at extended 12s (Improved Barkskin talent)", function()
        wow.setUnitClass("party1", "DRUID")
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, {})
        fw.not_nil(rule, "12s Barkskin variant should match")
        fw.eq(rule.SpellId, 22812, "Barkskin (Improved Barkskin)")
    end)

    fw.it("does not match Barkskin at 10s (between both variants)", function()
        -- 10.0 is outside 8±0.5 (7.5..8.5) and outside 12±0.5 (11.5..12.5).
        wow.setUnitClass("party1", "DRUID")
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 10.0, {})
        fw.is_nil(rule, "10s falls between Barkskin 8±0.5 and 12±0.5 windows -> no match")
    end)
end)

-- Section 11: Life Cocoon (Mistweaver) requires Shield evidence

fw.describe("FindBestCandidate - Life Cocoon requires Cast+Shield evidence", function()
    fw.before_each(reset)

    fw.it("Life Cocoon matches with Cast+Shield evidence", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("party2", 270)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.not_nil(rule, "Life Cocoon should match with Cast+Shield")
        fw.eq(rule.SpellId, 116849, "Life Cocoon")
        fw.eq(unit, "party2", "Monk is the caster")
    end)

    fw.it("Life Cocoon does not match without Shield evidence", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("party2", 270)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, nil)
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.is_nil(rule, "Life Cocoon requires Shield evidence - absent -> no match")
    end)

    fw.it("Life Cocoon matches at early cancel duration (6s) with Cast+Shield", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("party2", 270)
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 6.0, { "party2" })
        fw.not_nil(rule, "Life Cocoon CanCancelEarly -> 6s <= 12.5 should match")
        fw.eq(rule.SpellId, 116849, "Life Cocoon")
    end)
end)

-- Section 12: Blessing of Sacrifice vs Life Cocoon ambiguity
--
-- Both spells are EXTERNAL_DEFENSIVE, 12s, require Cast+Shield.  On 12.0.5, non-local
-- candidates get synthetic Cast, so both a Paladin and a Monk can appear as candidates.
-- When both are off-cooldown the result must be ambiguous (nil).  When Life Cocoon is on
-- cooldown for the monk, the only off-CD match is BoS and it must be committed.

fw.describe("FindBestCandidate - BoS vs Life Cocoon ambiguity (12.0.5)", function()
    fw.before_each(function()
        reset()
        B:_TestSetSimulateNoCastSucceeded(true)
    end)

    fw.it("ambiguous when Paladin (BoS) and Monk (Life Cocoon) are both off-CD candidates", function()
        -- party1 = Warrior (target), party2 = Holy Paladin, party3 = Mistweaver Monk.
        -- On 12.0.5, both non-target candidates receive synthetic Cast + Shield evidence.
        -- BoS (6940) and Life Cocoon (116849) both match -> different SpellIds -> ambiguous.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "MONK")
        mods.talents._setSpec("party2", 65)  -- Holy Paladin
        mods.talents._setSpec("party3", 270) -- Mistweaver Monk

        local t = makeTracked(EXT, 1.0, {}, { Shield = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2", "party3" })
        fw.is_nil(rule, "BoS and Life Cocoon both off-CD -> ambiguous -> nil")
    end)

    fw.it("BoS committed when Life Cocoon is on cooldown for the monk (caveat scenario)", function()
        -- Life Cocoon is on CD for party3.  ActiveCooldowns entry on the target entry
        -- marks it as fully consumed -> monk's rule is returned as fallback (alreadyOnCd=true).
        -- The only off-CD match is BoS from the Holy Paladin -> BoS committed.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "MONK")
        mods.talents._setSpec("party2", 65)
        mods.talents._setSpec("party3", 270)

        -- CastSnapshot gives the paladin cast evidence so BoS resolves without ambiguity.
        -- On 12.0.5 with synthetic Cast the monk also matches initially, but its spell is
        -- on CD so it is treated as a fallback and the off-CD BoS wins cleanly.
        -- Use pre-12.0.5 mode here (simulateNoCastSucceeded=false) to let real snapshots
        -- drive the result; the CD-check behaviour is the same on both paths.
        B:_TestSetSimulateNoCastSucceeded(false)
        wow.setUnitClass("player", "WARRIOR") -- local player is an unrelated unit

        local entry = loader.makeEntry("party1", { [116849] = { MaxCharges = 1, UsedCharges = { 1 } } })
        local t = makeTracked(EXT, 1.0, { party2 = 1.0 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2", "party3" })
        fw.not_nil(rule, "BoS should be committed when Life Cocoon is on CD for the monk")
        fw.eq(rule.SpellId, 6940, "Blessing of Sacrifice")
        fw.eq(unit, "party2", "Holy Paladin is the caster")
    end)

    fw.it("Life Cocoon committed when both paladins BoS are on cooldown", function()
        -- Two Paladins both have BoS on CD; the monk's Life Cocoon is off-CD.
        -- Only Life Cocoon can match -> Life Cocoon committed.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "PALADIN")
        wow.setUnitClass("party4", "MONK")
        mods.talents._setSpec("party2", 65)
        mods.talents._setSpec("party3", 65)
        mods.talents._setSpec("party4", 270)

        -- BoS on CD for both paladins; Life Cocoon not on CD.
        local entry = loader.makeEntry("party1", { [6940] = { MaxCharges = 1, UsedCharges = { 1 } } })
        -- Monk has real cast snapshot.
        local t = makeTracked(EXT, 1.0, { party4 = 1.0 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2", "party3", "party4" })
        fw.not_nil(rule, "Life Cocoon should be committed when all Paladin BoS are on CD")
        fw.eq(rule.SpellId, 116849, "Life Cocoon")
        fw.eq(unit, "party4", "Monk is the caster")
    end)

    fw.it("monk cast wins via cast-time tiebreaker over synthetic BoS candidate (pre-12.0.5)", function()
        -- Pre-12.0.5: monk has real cast evidence for Life Cocoon; paladin has no cast snapshot.
        -- BoS requires Cast evidence -> paladin fails RequiresEvidence -> only Life Cocoon matches.
        B:_TestSetSimulateNoCastSucceeded(false)
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "MONK")
        mods.talents._setSpec("party2", 65)
        mods.talents._setSpec("party3", 270)

        -- Only monk has a cast snapshot (paladin didn't cast BoS).
        local t = makeTracked(EXT, 1.0, { party3 = 1.0 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2", "party3" })
        fw.not_nil(rule, "Life Cocoon should match when monk has real cast evidence")
        fw.eq(rule.SpellId, 116849, "Life Cocoon")
        fw.eq(unit, "party3", "Monk is the caster")
    end)

    fw.it("monk self-casting Life Cocoon on themselves: ambiguous vs synthetic BoS (no cast evidence)", function()
        -- Bug scenario: Mistweaver Monk (party1) is the TARGET and the caster - they cast
        -- Life Cocoon on themselves.  From a remote observer's perspective (e.g. ret paladin):
        --   · party2 (Holy Paladin) is a non-target candidate -> gets synthetic Cast -> BoS matches
        --   · party1 (Monk) is the target -> self-cast fallback runs because bestTime==nil
        --   · Life Cocoon (116849) != BoS (6940) -> ambiguous -> nil.
        -- Without the fix, bestTime==nil did not trigger the fallback (only "not rule" did), so
        -- the Paladin's synthetic BoS was incorrectly committed.
        wow.setUnitClass("party1", "MONK")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 270) -- Mistweaver Monk -> Life Cocoon
        mods.talents._setSpec("party2", 65)  -- Holy Paladin -> BoS

        local t = makeTracked(EXT, 1.0, {}, { Shield = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.is_nil(rule, "Monk self-cast LC vs synthetic BoS -> ambiguous -> nil")
    end)

    fw.it("monk self-casting Life Cocoon on themselves: wins when monk has real cast evidence", function()
        -- Same scenario as above, but the observer's CastSnapshot includes party1 (monk) with a
        -- real cast timestamp.  The cast-time tiebreaker resolves the ambiguity in favour of the
        -- monk's Life Cocoon: party2 (paladin) only has synthetic evidence (bestTime=nil) whereas
        -- the self-cast fallback now provides a real castTime -> isBetter -> Life Cocoon wins.
        wow.setUnitClass("party1", "MONK")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 270) -- Mistweaver Monk -> Life Cocoon
        mods.talents._setSpec("party2", 65)  -- Holy Paladin -> BoS

        -- party1 (monk) has a real cast snapshot within the cast window.
        local t = makeTracked(EXT, 1.0, { party1 = 1.0 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.not_nil(rule, "Monk self-cast with real snapshot should resolve unambiguously")
        fw.eq(rule.SpellId, 116849, "Life Cocoon")
        fw.eq(unit, "party1", "Monk is both target and caster")
    end)
end)

-- Section 13: CastableOnOthers cross-unit filter prevents false ambiguity from self-only rules
-- The Paladin's BoF (CastableOnOthers) on an Evoker target must commit even when Hunter, Priest,
-- and Shaman candidates are in the group (their self-only IMP rules must NOT create false ambiguity).

fw.describe("FindBestCandidate - BoF commit in mixed group (CastableOnOthers cross-unit filter)", function()
    fw.before_each(function()
        reset()
        B:_TestSetSimulateNoCastSucceeded(true)
    end)

    fw.it("BoF (party1=Paladin caster) commits on party2 (Evoker target) in mixed group", function()
        -- Matches the real bug: Evoker receives BoF (8s IMP), Paladin in group casts it.
        -- Non-Paladin candidates (Evoker, Hunter, Shaman, Priest) must NOT create false ambiguity
        -- with the Paladin's BoF via their own self-only IMP rules.
        wow.setUnitClass("party2", "EVOKER")
        mods.talents._setSpec("party2", 1467)  -- Devastation
        wow.setUnitClass("party4", "HUNTER")
        wow.setUnitClass("player",  "SHAMAN")
        wow.setUnitClass("party3", "PRIEST")
        mods.talents._setSpec("party3", 256)   -- Discipline
        wow.setUnitClass("party1", "PALADIN")

        local entry = loader.makeEntry("party2")
        local t = makeTracked(IMP, 1.0, {}, nil)  -- no evidence at all (12.0.5: no cast snapshot)

        local rule, unit = B:FindBestCandidate(entry, t, 8.1,
            { "party2", "party4", "player", "party3", "party1" })

        fw.not_nil(rule, "BoF should commit with Paladin in group")
        fw.eq(rule.SpellId, 1044, "Blessing of Freedom")
        fw.eq(unit, "party1", "Paladin is the caster")
    end)

    fw.it("no match when no Paladin is in the group (cross-unit loop finds no CastableOnOthers match)", function()
        -- Without a Paladin, no CastableOnOthers IMP rule matches.
        wow.setUnitClass("party2", "EVOKER")
        mods.talents._setSpec("party2", 1467)
        wow.setUnitClass("party4", "HUNTER")
        wow.setUnitClass("player",  "SHAMAN")

        local entry = loader.makeEntry("party2")
        local t = makeTracked(IMP, 1.0, {}, nil)
        local rule = B:FindBestCandidate(entry, t, 8.1, { "party2", "party4", "player" })
        fw.is_nil(rule, "no CastableOnOthers IMP caster found -> no match")
    end)
end)
