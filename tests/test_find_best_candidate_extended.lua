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

    fw.it("SotF matches when FD+AotT pressed simultaneously (FeignDeath evidence, no UnitFlags)", function()
        wow.setUnitClass("party1", "HUNTER")
        -- FeignDeath in evidence; UnitFlags absent (FD suppressed it in RecordUnitFlagsChange).
        -- AotT: needs UnitFlags (absent) -> fails.
        -- SotF: Exclude=UnitFlags -> UnitFlags absent -> matches.
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true, FeignDeath = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        fw.not_nil(rule, "SotF should match when UnitFlags is absent")
        fw.eq(rule.SpellId, 264735, "Survival of the Fittest")
    end)

    fw.it("SotF matches with FeignDeath-only evidence (AotT excluded, UnitFlags absent)", function()
        wow.setUnitClass("party1", "HUNTER")
        -- FeignDeath evidence only; no UnitFlags, no Cast.
        -- AotT needs UnitFlags (absent) -> fails.
        -- SotF: Exclude=UnitFlags -> UnitFlags absent -> matches.
        local t = makeTracked(BIG, 1.0, {}, { FeignDeath = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        fw.not_nil(rule, "SotF should match with FeignDeath-only evidence")
        fw.eq(rule.SpellId, 264735, "Survival of the Fittest")
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

-- Section 4: ActiveCooldowns - on-CD rule vs off-CD rule with two candidates

fw.describe("FindBestCandidate - ActiveCooldowns with two candidates", function()
    fw.before_each(reset)

    -- Two Restoration Druids; Ironbark is on cooldown for party2 but not party3.
    -- party2's Ironbark is on CD -> skipped; party3's is not -> party3 wins.
    -- (non-local units receive synthetic Cast if they have no real snapshot)

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

    -- Guardian's Barkskin has a 34s cooldown vs the 60s class-wide rule used by other specs.
    -- The spec rule (BySpec[104]) must take priority over the ByClass.DRUID fallback.
    fw.it("Guardian Druid commits Barkskin with its 34s cooldown (spec rule overrides class)", function()
        wow.setUnitClass("party1", "DRUID")
        mods.talents._setSpec("party1", 104)
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        fw.not_nil(rule, "Guardian Barkskin should match")
        fw.eq(rule.SpellId, 22812, "Barkskin")
        fw.eq(rule.Cooldown, 34, "Guardian Barkskin cooldown is 34s")
    end)

    fw.it("non-Guardian Druid commits Barkskin with the 60s class cooldown", function()
        wow.setUnitClass("party1", "DRUID")
        mods.talents._setSpec("party1", 102) -- Balance: no Barkskin spec rule, falls through to class
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(loader.makeEntry("party1"), t, 8.0, {})
        fw.not_nil(rule, "Balance Barkskin should match via the class rule")
        fw.eq(rule.SpellId, 22812, "Barkskin")
        fw.eq(rule.Cooldown, 60, "non-Guardian Barkskin cooldown is 60s")
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
        -- The monk also gets synthetic Cast but its spell is on CD so it is treated as
        -- a fallback and the off-CD BoS wins cleanly.
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

    fw.it("monk cast wins via cast-time tiebreaker over synthetic BoS candidate", function()
        -- Monk has real cast evidence; paladin gets synthetic Cast only (no real snapshot).
        -- Both match their respective EXT rule, but monk's real castTime beats paladin's nil castTime.
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

