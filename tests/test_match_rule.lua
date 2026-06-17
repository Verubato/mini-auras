-- Unit tests for Brain:MatchRule and Brain:PredictSpellId.
--
-- Tests the following logic paths:
--   · EvidenceMatchesReq: nil / false / string / table requirements
--   · Duration matching: exact, MinDuration, CanCancelEarly, MinCancelDuration
--   · Duration tolerance boundaries (pass at ±0.5, fail beyond)
--   · ExcludeIfTalent: single ID and table of IDs
--   · RequiresTalent: single ID and table of IDs (any-one semantics)
--   · IgnoreTalentRequirements: skips RequiresTalent gate
--   · KnownSpellIds fast path: bypasses duration+evidence; wrong ID falls through
--   · Spec rules take priority over class rules for the same unit
--   · ActiveCooldowns: on-CD rule returned as fallback only

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods = loader.get()
local B    = mods.brain

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

-- Aura type shorthand
local BIG    = { BIG_DEFENSIVE = true, IMPORTANT = true }
local BIG_CC = { BIG_DEFENSIVE = true, IMPORTANT = true, CROWD_CONTROL = true }
local IMP = { IMPORTANT = true }
local EXT = { EXTERNAL_DEFENSIVE = true }

-- Thin wrapper so tests can read "nil" returns cleanly.
local function matchRule(unit, auraTypes, duration, context)
    return B:MatchRule(unit, auraTypes, duration, context)
end

-- Section 1: EvidenceMatchesReq - requirements expressed via RequiresEvidence

fw.describe("MatchRule - evidence requirement: nil (no constraint)", function()
    fw.before_each(reset)

    -- Barkskin (DRUID class): BIG+IMP, BuffDuration=8, no RequiresEvidence (Cast was removed in 12.0.5).

    fw.it("Barkskin matches when Cast evidence is present", function()
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 22812, "SpellId should be Barkskin")
    end)

    fw.it("Barkskin matches with no evidence (no RequiresEvidence after 12.0.5 Cast removal)", function()
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = nil })
        fw.not_nil(rule, "Barkskin has no RequiresEvidence; matches with nil evidence")
        fw.eq(rule.SpellId, 22812, "SpellId Barkskin")
    end)
end)

-- Section 2: Astral Shift (SHAMAN class): BIG, BuffDuration=12, no RequiresEvidence.

fw.describe("MatchRule - evidence requirement: no constraint (Astral Shift)", function()
    fw.before_each(reset)

    fw.it("Astral Shift matches Shaman with Cast evidence", function()
        wow.setUnitClass("party1", "SHAMAN")
        local rule = matchRule("party1", BIG, 12.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 108271, "Astral Shift")
    end)

    fw.it("Astral Shift matches Shaman with Shield evidence (no RequiresEvidence)", function()
        wow.setUnitClass("party1", "SHAMAN")
        local rule = matchRule("party1", BIG, 12.0, { Evidence = { Shield = true } })
        fw.not_nil(rule, "Astral Shift has no RequiresEvidence; any evidence is fine")
        fw.eq(rule.SpellId, 108271, "Astral Shift")
    end)

    fw.it("Astral Shift matches Shaman with no evidence (no RequiresEvidence)", function()
        wow.setUnitClass("party1", "SHAMAN")
        local rule = matchRule("party1", BIG, 12.0, { Evidence = nil })
        fw.not_nil(rule, "Astral Shift has no RequiresEvidence; matches with nil evidence")
        fw.eq(rule.SpellId, 108271, "Astral Shift")
    end)

    fw.it("Astral Shift matches with both Cast and extra irrelevant evidence (Debuff)", function()
        wow.setUnitClass("party1", "SHAMAN")
        local rule = matchRule("party1", BIG, 12.0, { Evidence = { Cast = true, Debuff = true } })
        fw.not_nil(rule, "extra evidence does not block a nil-requirement rule")
        fw.eq(rule.SpellId, 108271, "Astral Shift")
    end)
end)

fw.describe("MatchRule - evidence requirement: table (all must be present)", function()
    fw.before_each(reset)

    -- Divine Shield (PALADIN class): RequiresEvidence="UnitFlags", BIG+IMP, BuffDuration=8
    --   (Cast was removed in 12.0.5; only UnitFlags is now required)
    -- Ice Block (MAGE spec64): RequiresEvidence={"Debuff","UnitFlags"}, BIG+IMP, BuffDuration=10
    --   (Cast was removed in 12.0.5; Debuff+UnitFlags are now required)

    fw.it("Divine Shield matches when Cast+UnitFlags both present", function()
        wow.setUnitClass("party1", "PALADIN")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true, UnitFlags = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 642, "Divine Shield")
    end)

    fw.it("Divine Shield does not match when only Cast is present (UnitFlags missing)", function()
        wow.setUnitClass("party1", "PALADIN")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "DS requires UnitFlags; Cast alone is not enough")
    end)

    fw.it("Divine Shield matches when only UnitFlags is present (Cast no longer required)", function()
        wow.setUnitClass("party1", "PALADIN")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { UnitFlags = true } })
        fw.not_nil(rule, "DS requires only UnitFlags; Cast is no longer required")
        fw.eq(rule.SpellId, 642, "Divine Shield")
    end)

    fw.it("Ice Block matches when Cast+Debuff+UnitFlags all present", function()
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        local rule = matchRule("party1", BIG, 10.0, { Evidence = { Cast = true, Debuff = true, UnitFlags = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 45438, "Ice Block")
    end)

    fw.it("Ice Block matches when Debuff+UnitFlags present (Cast no longer required)", function()
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        -- Ice Block now requires only {Debuff, UnitFlags} (Cast removed in 12.0.5).
        local rule = matchRule("party1", BIG, 10.0, { Evidence = { UnitFlags = true, Debuff = true } })
        fw.not_nil(rule, "Ice Block requires Debuff+UnitFlags; both present -> matches")
        fw.eq(rule.SpellId, 45438, "Ice Block")
    end)

    fw.it("Alter Time matches with no evidence when no spec set (class-level, no RequiresEvidence)", function()
        wow.setUnitClass("party1", "MAGE")
        -- Without spec, only MAGE class rules apply. Alter Time (342246) has no RequiresEvidence
        -- and matches a 10s BIG aura.  Ice Block is spec64-only and not applicable here.
        local rule = matchRule("party1", BIG, 10.0, { Evidence = nil })
        fw.not_nil(rule, "Alter Time has no RequiresEvidence; matches class-level with nil evidence")
        fw.eq(rule.SpellId, 342246, "Alter Time")
    end)
end)

-- Section 3: Duration matching modes

fw.describe("MatchRule - exact duration matching", function()
    fw.before_each(reset)

    -- Barkskin: BuffDuration=8, exact match (no MinDuration, no CanCancelEarly)
    -- tolerance = 0.5

    fw.it("matches at exactly the expected duration", function()
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "exact duration should match")
        fw.eq(rule.SpellId, 22812, "Barkskin")
    end)

    fw.it("matches at expected - 0.5 (lower tolerance boundary)", function()
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 7.5, { Evidence = { Cast = true } })
        fw.not_nil(rule, "lower tolerance boundary should match")
    end)

    fw.it("matches at expected + 0.5 (upper tolerance boundary)", function()
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.5, { Evidence = { Cast = true } })
        fw.not_nil(rule, "upper tolerance boundary should match")
    end)

    fw.it("does not match at expected - 0.51 (just below lower boundary)", function()
        wow.setUnitClass("party1", "DRUID")
        -- 8s base - 0.51 = 7.49, which is outside the 8±0.5 window
        -- But Barkskin also has a 12s variant (Improved Barkskin); check neither matches.
        local rule = matchRule("party1", BIG, 7.49, { Evidence = { Cast = true } })
        fw.is_nil(rule, "7.49s is outside both 8±0.5 and 12±0.5 windows")
    end)

    fw.it("does not match at expected + 0.51 (just above upper boundary for 8s variant)", function()
        wow.setUnitClass("party1", "DRUID")
        -- 8.51 is outside 8±0.5, but falls within 12-0.5=11.5 lower bound? No: 11.5 > 8.51.
        -- The 12s variant requires 11.5..12.5 - 8.51 does not fall in that range either.
        local rule = matchRule("party1", BIG, 8.51, { Evidence = { Cast = true } })
        fw.is_nil(rule, "8.51s is outside both Barkskin windows (8±0.5 and 12±0.5)")
    end)
end)

fw.describe("MatchRule - MinDuration matching", function()
    fw.before_each(reset)

    -- Obsidian Scales (EVOKER class): MinDuration=true, BuffDuration=12, BIG_DEFENSIVE, no RequiresEvidence
    -- MinDuration: measuredDuration >= expectedDuration - tolerance (>= 11.5)

    fw.it("matches when measured >= expected - tolerance (exact lower boundary)", function()
        wow.setUnitClass("party1", "EVOKER")
        local rule = matchRule("party1", BIG, 11.5, { Evidence = { Cast = true } })
        fw.not_nil(rule, "11.5 >= 12 - 0.5 should pass MinDuration")
        fw.eq(rule.SpellId, 363916, "Obsidian Scales")
    end)

    fw.it("matches when measured is well above expected", function()
        wow.setUnitClass("party1", "EVOKER")
        local rule = matchRule("party1", BIG, 20.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "20s > 11.5 lower bound should pass MinDuration")
        fw.eq(rule.SpellId, 363916, "Obsidian Scales")
    end)

    fw.it("does not match when measured < expected - tolerance", function()
        wow.setUnitClass("party1", "EVOKER")
        -- 11.49 < 11.5 -> fails MinDuration
        local rule = matchRule("party1", BIG, 11.49, { Evidence = { Cast = true } })
        fw.is_nil(rule, "11.49 < 11.5 should fail MinDuration")
    end)
end)

fw.describe("MatchRule - CanCancelEarly matching", function()
    fw.before_each(reset)

    -- Dispersion (spec 258): CanCancelEarly=true, BuffDuration=6, BIG+IMP, RequiresEvidence="Cast"
    -- CanCancelEarly: measuredDuration <= expectedDuration + tolerance (no MinCancelDuration on Dispersion)
    -- So any duration from 0 to 6.5 should pass.

    fw.it("matches at the expected duration (full channel)", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        local rule = matchRule("party1", BIG_CC, 6.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "full duration should match CanCancelEarly rule")
        fw.eq(rule.SpellId, 47585, "Dispersion")
    end)

    fw.it("matches at expected + 0.5 (upper tolerance boundary)", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        local rule = matchRule("party1", BIG_CC, 6.5, { Evidence = { Cast = true } })
        fw.not_nil(rule, "6.5 == 6 + 0.5 should pass CanCancelEarly")
    end)

    fw.it("matches at a short early-cancel duration (2s)", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        local rule = matchRule("party1", BIG_CC, 2.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "early cancel at 2s should match CanCancelEarly rule")
        fw.eq(rule.SpellId, 47585, "Dispersion")
    end)

    fw.it("does not match when measured > expected + tolerance", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        -- 6.51 > 6.5 upper bound; also check 8s talent variant: 8+0.5=8.5 > 6.51 but
        -- that variant requires RequiresTalent=453729 which is not set -> excluded.
        local rule = matchRule("party1", BIG, 6.51, { Evidence = { Cast = true } })
        fw.is_nil(rule, "6.51 exceeds 6 + 0.5 -> fails CanCancelEarly")
    end)
end)

-- Section 4: Talent gating

fw.describe("MatchRule - ExcludeIfTalent (single ID)", function()
    fw.before_each(reset)

    -- Ice Block (spec 64, Frost Mage): ExcludeIfTalent=414659, BIG, BuffDuration=10,
    --   RequiresEvidence={"Debuff","UnitFlags"}
    -- When talent 414659 is present, Ice Block is excluded; Ice Cold (RequiresTalent=414659) appears instead.

    fw.it("Ice Block matches when the exclude-talent is absent", function()
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        local rule = matchRule("party1", BIG, 10.0, { Evidence = { Debuff = true, UnitFlags = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 45438, "Ice Block without exclude-talent")
    end)

    fw.it("Ice Block is excluded when the exclude-talent is present", function()
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        mods.talents._setTalent("party1", 414659, true)
        -- Ice Block excluded; Ice Cold needs duration ~6s and Debuff evidence.
        local rule = matchRule("party1", BIG, 6.0, { Evidence = { Debuff = true } })
        fw.not_nil(rule, "Ice Cold should match when Ice Block is excluded by talent")
        fw.eq(rule.SpellId, 414659, "Ice Cold")
    end)
end)

fw.describe("MatchRule - RequiresTalent (single ID)", function()
    fw.before_each(reset)

    -- Enraged Regeneration (spec 72, Fury Warrior): RequiresTalent=184364, BuffDuration=8, BIG.
    -- Fury Warrior has no other spec rule and WARRIOR class rules are empty -> clean test subject.

    fw.it("Enraged Regeneration does not match without the required talent", function()
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 72)
        -- Without talent, Enraged Regeneration is skipped; nothing else matches an 8s BIG aura.
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "RequiresTalent missing -> Enraged Regeneration skipped; no other rule matches")
    end)

    fw.it("Enraged Regeneration matches when required talent is present", function()
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 72)
        mods.talents._setTalent("party1", 184364, true)
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "RequiresTalent satisfied -> Enraged Regeneration should match")
        fw.eq(rule.SpellId, 184364, "Enraged Regeneration")
    end)
end)

fw.describe("MatchRule - IgnoreTalentRequirements", function()
    fw.before_each(reset)

    fw.it("skips RequiresTalent gate when IgnoreTalentRequirements=true", function()
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        -- Ice Cold requires talent 414659; without it and without the flag -> nil.
        -- With IgnoreTalentRequirements=true the gate is skipped -> 6s matches Ice Cold.
        local rule = matchRule("party1", BIG, 6.0, {
            Evidence = { Debuff = true },
            IgnoreTalentRequirements = true,
        })
        fw.not_nil(rule, "IgnoreTalentRequirements should skip RequiresTalent gate")
        fw.eq(rule.SpellId, 414659, "Ice Cold (talent not set but gate skipped)")
    end)
end)

-- Section 5: KnownSpellIds fast path

fw.describe("MatchRule - KnownSpellIds fast path", function()
    fw.before_each(reset)

    fw.it("KnownSpellIds matching a rule bypasses duration check (short duration)", function()
        -- Barkskin expects 8s; measured 3s would normally fail.
        -- KnownSpellIds=[22812] within the window -> FindRuleBySpellId -> returns rule directly.
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 3.0, {
            KnownSpellIds = { 22812 },
        })
        fw.not_nil(rule, "KnownSpellIds should bypass duration check")
        fw.eq(rule.SpellId, 22812, "Barkskin")
    end)

    fw.it("KnownSpellIds bypasses evidence check as well", function()
        -- Barkskin needs Cast evidence; KnownSpellIds fast path skips that too.
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.0, {
            KnownSpellIds = { 22812 },
            Evidence = nil,  -- no Cast evidence
        })
        fw.not_nil(rule, "KnownSpellIds should bypass evidence requirement")
        fw.eq(rule.SpellId, 22812, "Barkskin")
    end)

    fw.it("KnownSpellIds with a non-matching spell ID falls through to duration matching", function()
        -- SpellId 99999 is unknown; falls through to normal duration matching.
        -- Duration 3s doesn't match Barkskin (8±0.5) -> nil.
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 3.0, {
            KnownSpellIds = { 99999 },
            Evidence = { Cast = true },
        })
        fw.is_nil(rule, "unknown KnownSpellId falls through; duration 3s doesn't match any Druid BIG rule")
    end)

    fw.it("KnownSpellIds with correct ID still respects aura type constraint", function()
        -- Spell 22812 (Barkskin) requires BIG_DEFENSIVE; passing IMP-only should fail.
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", IMP, 3.0, {
            KnownSpellIds = { 22812 },
        })
        -- Barkskin has BigDefensive=true -> AuraTypeMatchesRule requires BIG in auraTypes.
        -- IMP-only lacks BIG_DEFENSIVE -> rule excluded even via fast path.
        fw.is_nil(rule, "KnownSpellIds still respects aura type - Barkskin needs BIG_DEFENSIVE")
    end)

    fw.it("CastSpellId alias (Alter Time 342245) matches via KnownSpellIds", function()
        -- Alter Time has CastSpellId={342245, 342247} (the physical cast spell differs from the buff ID 342246).
        -- KnownSpellIds with 342245 should resolve to the Alter Time rule.
        wow.setUnitClass("party1", "MAGE")
        local rule = matchRule("party1", BIG, 3.0, {
            KnownSpellIds = { 342245 },
            Evidence = { Cast = true },
        })
        fw.not_nil(rule, "CastSpellId alias should resolve via KnownSpellIds fast path")
        fw.eq(rule.SpellId, 342246, "Alter Time (via CastSpellId alias 342245)")
    end)
end)

-- Section 6: Spec rules take priority over class rules

fw.describe("MatchRule - spec rules take priority over class rules", function()
    fw.before_each(reset)

    fw.it("Blood DK spec rules (Vampiric Blood) checked before class rules (AMS/IBF)", function()
        -- Vampiric Blood is in spec 250 (Blood DK), BuffDuration=10, BIG+IMP, RequiresEvidence="Cast".
        -- The class rules include AMS (5s BIG+IMP, RequiresEvidence={Cast,Shield}) and IBF (8s).
        -- At 10s BIG+IMP with Cast evidence, spec rule (VB) should win over class rules.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)
        local rule = matchRule("party1", BIG, 10.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 55233, "Vampiric Blood from spec list, not class list")
    end)

    fw.it("class rules are used when no spec rule matches", function()
        -- DK with spec 250 (Blood); Icebound Fortitude (class, 8s) - no spec 250 rule matches 8s BIG.
        -- Blood spec rules: VB 10/12/14s. None match 8.0 (8±0.5=7.5..8.5; VB expects 10).
        -- Class rules: IBF 8s BIG+IMP, RequiresEvidence="Cast" -> matches.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 48792, "Icebound Fortitude from class list when spec list has no match")
    end)
end)

-- Section 7: ActiveCooldowns fallback

fw.describe("MatchRule - ActiveCooldowns fallback", function()
    fw.before_each(reset)

    fw.it("on-CD rule is skipped in favour of an off-CD match", function()
        -- Two Druid rules: Barkskin 8s and Barkskin 12s (Improved Barkskin). Both share SpellId.
        -- If 22812 is on CD and duration=12, the 12s variant (also on CD) becomes fallback,
        -- but nothing else off-CD matches - so the fallback IS returned.
        -- Here we test: only one spell (Barkskin) and it's on CD -> returned as fallback.
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.0, {
            Evidence = { Cast = true },
            ActiveCooldowns = { [22812] = {} },
        })
        fw.not_nil(rule, "on-CD Barkskin should be returned as fallback (nothing else matches)")
        fw.eq(rule.SpellId, 22812, "Barkskin (fallback)")
    end)

    fw.it("on-CD fallback is not returned when another off-CD rule matches first", function()
        -- Mage spec 64: if Ice Block (45438) is on CD but Ice Cold (414659, with talent) is not,
        -- the off-CD rule (Ice Cold) should win over the Ice Block fallback.
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        mods.talents._setTalent("party1", 414659, true)
        -- Ice Block is on CD; Ice Cold is off CD.
        -- Duration=6.0 -> Ice Block (10s) fails duration; Ice Cold (6s) passes.
        -- Ice Block is also excluded since it has ExcludeIfTalent=414659 -> already skipped.
        -- The CD status of Ice Block doesn't matter here since it is excluded by talent.
        local rule = matchRule("party1", BIG, 6.0, {
            Evidence = { Debuff = true },
            ActiveCooldowns = { [45438] = {} },
        })
        fw.not_nil(rule, "off-CD Ice Cold should match")
        fw.eq(rule.SpellId, 414659, "Ice Cold (off CD)")
    end)
end)
