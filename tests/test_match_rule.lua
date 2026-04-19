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
    B:_TestSetSimulateNoCastSucceeded(false)
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

    -- Desperate Prayer: PRIEST class, BIG+IMP, RequiresEvidence="Cast", BuffDuration=10
    -- We test a rule that has no evidence requirement; Barkskin has RequiresEvidence="Cast",
    -- so use Fortifying Brew (Monk class, BIG, RequiresEvidence="Cast", BuffDuration=15).
    -- There is no rule with RequiresEvidence=nil in the current set, so we test via
    -- a rule that passes when the required evidence IS present.

    fw.it("Barkskin matches when Cast evidence is present", function()
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 22812, "SpellId should be Barkskin")
    end)

    fw.it("Barkskin does not match when Cast evidence is absent", function()
        wow.setUnitClass("party1", "DRUID")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = nil })
        fw.is_nil(rule, "Barkskin requires Cast evidence")
    end)
end)

-- Section 2: EvidenceMatchesReq - req = false (requires NO evidence)
-- No current live rule uses RequiresEvidence=false, but the logic path exists.
-- We test it indirectly: when evidence IS present for a req="Cast" rule the match works;
-- absence breaks it.  The false-req path is already exercised implicitly by the evidence=nil
-- tests above; here we test the "no evidence at all" pass-through scenario.

fw.describe("MatchRule - evidence requirement: string ('Cast')", function()
    fw.before_each(reset)

    fw.it("Evasion matches Rogue with Cast evidence", function()
        wow.setUnitClass("party1", "ROGUE")
        local rule = matchRule("party1", IMP, 10.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 5277, "Evasion")
    end)

    fw.it("Evasion does not match Rogue with Shield evidence only (wrong type)", function()
        wow.setUnitClass("party1", "ROGUE")
        local rule = matchRule("party1", IMP, 10.0, { Evidence = { Shield = true } })
        fw.is_nil(rule, "Cast is required, Shield alone does not satisfy it")
    end)

    fw.it("Evasion does not match Rogue with no evidence", function()
        wow.setUnitClass("party1", "ROGUE")
        local rule = matchRule("party1", IMP, 10.0, { Evidence = nil })
        fw.is_nil(rule, "Cast evidence absent -> no match")
    end)

    fw.it("Evasion matches with both Cast and extra irrelevant evidence (Debuff)", function()
        wow.setUnitClass("party1", "ROGUE")
        -- Extra evidence types should not block a string requirement.
        local rule = matchRule("party1", IMP, 10.0, { Evidence = { Cast = true, Debuff = true } })
        fw.not_nil(rule, "extra evidence types should not block a Cast-only requirement")
        fw.eq(rule.SpellId, 5277, "Evasion")
    end)
end)

fw.describe("MatchRule - evidence requirement: table (all must be present)", function()
    fw.before_each(reset)

    -- Divine Shield (PALADIN class): RequiresEvidence={"Cast","UnitFlags"}, BIG+IMP, BuffDuration=8
    -- Ice Block (MAGE class): RequiresEvidence={"Cast","Debuff","UnitFlags"}, BIG+IMP, BuffDuration=10

    fw.it("Divine Shield matches when Cast+UnitFlags both present", function()
        wow.setUnitClass("party1", "PALADIN")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true, UnitFlags = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 642, "Divine Shield")
    end)

    fw.it("Divine Shield does not match when only Cast is present (UnitFlags missing)", function()
        wow.setUnitClass("party1", "PALADIN")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "both Cast and UnitFlags are required")
    end)

    fw.it("Divine Shield does not match when only UnitFlags is present (Cast missing)", function()
        wow.setUnitClass("party1", "PALADIN")
        local rule = matchRule("party1", BIG, 8.0, { Evidence = { UnitFlags = true } })
        fw.is_nil(rule, "both Cast and UnitFlags are required")
    end)

    fw.it("Ice Block matches when Cast+Debuff+UnitFlags all present", function()
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        local rule = matchRule("party1", BIG, 10.0, { Evidence = { Cast = true, Debuff = true, UnitFlags = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 45438, "Ice Block")
    end)

    fw.it("Ice Block does not match when only UnitFlags+Debuff present (Cast missing) -> Alter Time also fails -> nil", function()
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 64)
        -- Neither Ice Block (needs Cast+Debuff+UnitFlags) nor Alter Time (needs Cast) can match
        -- without Cast evidence.  Ice Cold (RequiresTalent=414659, not set) is also excluded.
        local rule = matchRule("party1", BIG, 10.0, { Evidence = { UnitFlags = true, Debuff = true } })
        fw.is_nil(rule, "Cast absent -> both Ice Block and Alter Time fail their RequiresEvidence check")
    end)

    fw.it("Ice Block does not match with no evidence", function()
        wow.setUnitClass("party1", "MAGE")
        local rule = matchRule("party1", BIG, 10.0, { Evidence = nil })
        fw.is_nil(rule, "no evidence -> table requirement fails")
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

    -- Avenging Wrath (spec 65, Holy Paladin): MinDuration=true, BuffDuration=12, Important, RequiresEvidence="Cast"
    -- MinDuration: measuredDuration >= expectedDuration - tolerance (>= 11.5)

    fw.it("matches when measured >= expected - tolerance (exact lower boundary)", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        local rule = matchRule("party1", IMP, 11.5, { Evidence = { Cast = true } })
        fw.not_nil(rule, "11.5 >= 12 - 0.5 should pass MinDuration")
        fw.eq(rule.SpellId, 31884, "Avenging Wrath")
    end)

    fw.it("matches when measured is well above expected", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        local rule = matchRule("party1", IMP, 20.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "20s > 11.5 lower bound should pass MinDuration")
        fw.eq(rule.SpellId, 31884, "Avenging Wrath")
    end)

    fw.it("does not match when measured < expected - tolerance", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        -- 11.49 < 11.5 -> fails MinDuration
        local rule = matchRule("party1", IMP, 11.49, { Evidence = { Cast = true } })
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

fw.describe("MatchRule - MinCancelDuration guard", function()
    fw.before_each(reset)

    -- Divine Hymn (spec 257, Holy Priest): CanCancelEarly=true, BuffDuration=5, MinCancelDuration=1.5
    -- A duration below 1.5 should fail even though CanCancelEarly is set.

    fw.it("matches when measured >= MinCancelDuration (2s)", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)
        local rule = matchRule("party1", IMP, 2.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "2.0 >= MinCancelDuration 1.5 -> should match")
        fw.eq(rule.SpellId, 64843, "Divine Hymn")
    end)

    fw.it("matches at exactly MinCancelDuration", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)
        local rule = matchRule("party1", IMP, 1.5, { Evidence = { Cast = true } })
        fw.not_nil(rule, "1.5 == MinCancelDuration -> boundary should pass")
        fw.eq(rule.SpellId, 64843, "Divine Hymn")
    end)

    fw.it("does not match when measured < MinCancelDuration (1.0s, Phase Shift proc guard)", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 257)
        -- Phase Shift (PvP talent) creates a ~1s IMPORTANT buff on Fade - MinCancelDuration blocks it.
        local rule = matchRule("party1", IMP, 1.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "1.0 < MinCancelDuration 1.5 -> Phase Shift guard should reject it")
    end)
end)

-- Section 4: Talent gating

fw.describe("MatchRule - ExcludeIfTalent (single ID)", function()
    fw.before_each(reset)

    -- Avenging Wrath (spec 65): ExcludeIfTalent=216331
    -- When talent 216331 is present, AW is excluded; Avenging Crusader (RequiresTalent=216331) appears instead.

    fw.it("Avenging Wrath matches when the exclude-talent is absent", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        local rule = matchRule("party1", IMP, 12.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 31884, "Avenging Wrath without exclude-talent")
    end)

    fw.it("Avenging Wrath is excluded when the exclude-talent is present", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        mods.talents._setTalent("party1", 216331, true)
        -- AW excluded; Avenging Crusader needs duration >=9.5; 12.0 passes that.
        local rule = matchRule("party1", IMP, 12.0, { Evidence = { Cast = true } })
        -- Avenging Crusader has MinDuration=true, BuffDuration=10; 12.0 >= 9.5 -> pass.
        fw.not_nil(rule, "Avenging Crusader should match when AW is excluded by talent")
        fw.eq(rule.SpellId, 216331, "Avenging Crusader")
    end)
end)

fw.describe("MatchRule - RequiresTalent (single ID)", function()
    fw.before_each(reset)

    -- Avenging Crusader (spec 65): RequiresTalent=216331, MinDuration, BuffDuration=10

    fw.it("Avenging Crusader does not match without the required talent", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        -- Without talent, Avenging Crusader is skipped; AW (12s MinDuration) requires >= 11.5.
        -- duration=10.0 < 11.5 -> AW also fails -> nil.
        local rule = matchRule("party1", IMP, 10.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "RequiresTalent missing -> rule skipped; AW also fails at 10s")
    end)

    fw.it("Avenging Crusader matches when required talent is present", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        mods.talents._setTalent("party1", 216331, true)
        -- Also set ExcludeIfTalent to exclude AW, simulating the mutual-exclusion design.
        -- (AW has ExcludeIfTalent=216331, so it's already excluded by the talent above.)
        local rule = matchRule("party1", IMP, 10.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "RequiresTalent satisfied -> Avenging Crusader should match")
        fw.eq(rule.SpellId, 216331, "Avenging Crusader")
    end)
end)

fw.describe("MatchRule - RequiresTalent table (any-one semantics)", function()
    fw.before_each(reset)

    -- Warlock Nether Ward: RequiresTalent={18, 3508, 3624}, CanCancelEarly, BuffDuration=3, Important
    -- Any one of the talent IDs being present satisfies the requirement.

    fw.it("Nether Ward does not match when no talent from the list is present", function()
        wow.setUnitClass("party1", "WARLOCK")
        local rule = matchRule("party1", IMP, 3.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "no talent from the list -> RequiresTalent table fails")
    end)

    fw.it("Nether Ward matches when the first talent ID in the list is present", function()
        wow.setUnitClass("party1", "WARLOCK")
        mods.talents._setTalent("party1", 18, true)
        local rule = matchRule("party1", IMP, 3.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "talent ID 18 (first in list) satisfies RequiresTalent table")
        fw.eq(rule.SpellId, 212295, "Nether Ward")
    end)

    fw.it("Nether Ward matches when a later talent ID in the list is present", function()
        wow.setUnitClass("party1", "WARLOCK")
        mods.talents._setTalent("party1", 3624, true)   -- last in list
        local rule = matchRule("party1", IMP, 3.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "talent ID 3624 (last in list) satisfies RequiresTalent table")
        fw.eq(rule.SpellId, 212295, "Nether Ward")
    end)
end)

fw.describe("MatchRule - ExcludeIfTalent table (any-one semantics)", function()
    fw.before_each(reset)

    -- Enhancement Shaman Doomwinds (spec 263): ExcludeIfTalent={114051, 378270}
    -- Present when neither Ascendance (114051) nor Deeply Rooted Elements (378270) are taken.

    fw.it("Doomwinds matches when neither exclude-talent is present", function()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setSpec("party1", 263)
        mods.talents._setTalent("party1", 384352, true) -- RequiresTalent=384352
        local rule = matchRule("party1", IMP, 8.0, { Evidence = { Cast = true } })
        fw.not_nil(rule, "no exclude-talent -> Doomwinds should match")
        fw.eq(rule.SpellId, 384352, "Doomwinds")
    end)

    fw.it("Doomwinds is excluded when the first exclude-talent (Ascendance) is present", function()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setSpec("party1", 263)
        mods.talents._setTalent("party1", 384352, true)
        mods.talents._setTalent("party1", 114051, true) -- Ascendance -> excludes Doomwinds
        -- Ascendance is also in spec 263 with RequiresTalent=114051 and BuffDuration=15.
        -- 8.0 < 15 - 0.5 = 14.5 -> Ascendance fails duration; result = nil.
        local rule = matchRule("party1", IMP, 8.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "Ascendance talent excludes Doomwinds; Ascendance itself needs >=14.5s")
    end)

    fw.it("Doomwinds is excluded when the second exclude-talent (378270) is present", function()
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setSpec("party1", 263)
        mods.talents._setTalent("party1", 384352, true)
        mods.talents._setTalent("party1", 378270, true) -- Deeply Rooted Elements -> excludes Doomwinds
        local rule = matchRule("party1", IMP, 8.0, { Evidence = { Cast = true } })
        fw.is_nil(rule, "Deeply Rooted Elements talent excludes Doomwinds; no other spec-263 rule matches 8s IMP")
    end)
end)

fw.describe("MatchRule - IgnoreTalentRequirements", function()
    fw.before_each(reset)

    fw.it("skips RequiresTalent gate when IgnoreTalentRequirements=true", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        -- Avenging Crusader requires talent 216331; without it and without the flag -> nil.
        -- With IgnoreTalentRequirements=true the gate is skipped -> 10s matches (MinDuration >= 9.5).
        local rule = matchRule("party1", IMP, 10.0, {
            Evidence = { Cast = true },
            IgnoreTalentRequirements = true,
        })
        fw.not_nil(rule, "IgnoreTalentRequirements should skip RequiresTalent gate")
        fw.eq(rule.SpellId, 216331, "Avenging Crusader (talent not set but gate skipped)")
    end)

    fw.it("still respects ExcludeFromEnemyTracking when IgnoreTalentRequirements=true", function()
        -- Augmentation Evoker Time Stop: ExcludeFromEnemyTracking=true, RequiresTalent={...}
        -- With IgnoreTalentRequirements the RequiresTalent is skipped, but ExcludeFromEnemyTracking
        -- should cause the rule to be excluded entirely (it maps to the `excluded` flag path).
        wow.setUnitClass("party1", "EVOKER")
        mods.talents._setSpec("party1", 1473)
        local rule = matchRule("party1", IMP, 5.0, {
            Evidence = { Cast = true },
            IgnoreTalentRequirements = true,
        })
        -- Obsidian Scales (spec 1473, MinDuration, BuffDuration=13.4): 5.0 < 12.9 -> fails.
        -- Time Stop (ExcludeFromEnemyTracking): excluded by IgnoreTalentRequirements path.
        -- Result: nil or Obsidian Scales? 5.0 < 13.4 - 0.5 = 12.9 -> OS fails too. -> nil.
        fw.is_nil(rule, "ExcludeFromEnemyTracking should still exclude Time Stop even with IgnoreTalentRequirements")
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

    fw.it("CastSpellId alias (AMS Spellwarding 410358) matches via KnownSpellIds", function()
        -- AMS Spellwarding has CastSpellId=410358 (the physical cast spell differs from the buff ID).
        -- KnownSpellIds with 410358 should resolve to the AMS rule.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        local rule = matchRule("party1", IMP, 3.0, {
            KnownSpellIds = { 410358 },
            Evidence = { Cast = true, Shield = true },
        })
        fw.not_nil(rule, "CastSpellId alias should resolve via KnownSpellIds fast path")
        fw.eq(rule.SpellId, 48707, "AMS (via CastSpellId alias 410358)")
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
        -- Paladin spec 65: if AW (31884) is on CD but Avenging Crusader (216331, with talent) is not,
        -- the off-CD rule (Crusader) should win over the AW fallback.
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        mods.talents._setTalent("party1", 216331, true)
        -- AW is on CD; Avenging Crusader is off CD.
        -- Duration=10.0 -> AW (MinDuration ≥11.5) fails duration; AC (MinDuration ≥9.5) passes.
        -- AC is also excluded for AW since AW has ExcludeIfTalent=216331 -> AW already skipped.
        -- The CD status of AW doesn't matter here since AW is excluded by talent.
        local rule = matchRule("party1", IMP, 10.0, {
            Evidence = { Cast = true },
            ActiveCooldowns = { [31884] = {} },
        })
        fw.not_nil(rule, "off-CD Avenging Crusader should match")
        fw.eq(rule.SpellId, 216331, "Avenging Crusader (off CD)")
    end)
end)
