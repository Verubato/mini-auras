-- Enemy-specific matching and prediction tests.
--
-- EnemyCooldowns tracking differs from FriendlyCooldowns in three key ways:
--   1. UNIT_SPELLCAST_SUCCEEDED fires without a spell ID for enemies (secret value);
--      RecordCast is called with spellId=nil, so lastCastSpellIds stays empty.
--   2. candidateUnits is never passed by the ECD observer - EXT attribution is impossible
--      unless the target is both caster and recipient (self-cast fallback on 12.0.5).
--   3. IgnoreTalentRequirements=true is always passed to Brain because enemy talent data is
--      never available.  This bypasses RequiresTalent gates, but NOT ExcludeIfTalent.
--
-- Covered here:
--   · ExcludeIfTalent is NOT bypassed by IgnoreTalentRequirements (semantic boundary)
--   · ExcludeIfTalent is effectively inactive for real enemies (no talent data loaded)
--   · Empty candidateUnits: EXT aura -> nil pre-12.0.5; self-cast fallback on 12.0.5
--   · UnitFlags evidence for enemy Hunter -> AotT detection via direct API
--   · FeignDeath suppresses UnitFlags -> AotT not matched
--   · Observer pipeline: UnitFlags and FeignDeath recording for enemy units

local fw       = require("framework")
local wow      = require("wow_api")
local loader   = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local BIG = { BIG_DEFENSIVE = true, IMPORTANT = true }
local IMP = { IMPORTANT = true }
local EXT = { EXTERNAL_DEFENSIVE = true }

local function reset()
    B._TestReset()
    B:_TestSetSimulateNoCastSucceeded(false)
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

local function makeTracked(auraTypes, startTime, castSnapshot, evidence)
    return {
        StartTime           = startTime,
        AuraTypes           = auraTypes,
        Evidence            = evidence,
        CastSnapshot        = castSnapshot or {},
        CastSpellIdSnapshot = {},
    }
end

-- Section 1: ExcludeIfTalent is NOT bypassed by IgnoreTalentRequirements
--
-- IgnoreTalentRequirements=true only skips the RequiresTalent check; the ExcludeIfTalent check
-- still runs.  This is verified using Prot Paladin (spec 66):
--   AW  (31884): ExcludeIfTalent=389539, listed FIRST in the spec rule list.
--   Sentinel (389539): RequiresTalent=389539, listed SECOND.
-- With talent 389539 active and IgnoreTalentRequirements=true:
--   · AW is excluded (ExcludeIfTalent not bypassed) -> Sentinel considered next.
--   · Sentinel's RequiresTalent is bypassed -> Sentinel matches.
-- If IgnoreTalentRequirements had bypassed ExcludeIfTalent, AW (first in list) would win.

fw.describe("Enemy MatchRule - IgnoreTalentRequirements does NOT bypass ExcludeIfTalent", function()
    fw.before_each(reset)

    fw.it("ExcludeIfTalent talent active + IgnoreTalentRequirements=true -> AW excluded, Sentinel wins", function()
        -- Talent 389539 (Sentinel) is active, which excludes AW (ExcludeIfTalent=389539).
        -- IgnoreTalentRequirements=true bypasses Sentinel's RequiresTalent=389539.
        -- AW is still excluded -> Sentinel wins.
        wow.setUnitClass("arena1", "PALADIN")
        mods.talents._setSpec("arena1", 66)
        mods.talents._setTalent("arena1", 389539, true)

        local rule = B:MatchRule("arena1", IMP, 25.0, {
            Evidence = { Cast = true },
            IgnoreTalentRequirements = true,
        })
        fw.not_nil(rule, "Sentinel should match")
        fw.eq(rule.SpellId, 389539,
            "Sentinel (389539), not AW (31884) - ExcludeIfTalent not bypassed by IgnoreTalentRequirements")
    end)

    fw.it("same talent, WITHOUT IgnoreTalentRequirements -> Sentinel still matches (talent present)", function()
        wow.setUnitClass("arena1", "PALADIN")
        mods.talents._setSpec("arena1", 66)
        mods.talents._setTalent("arena1", 389539, true)

        local rule = B:MatchRule("arena1", IMP, 25.0, {
            Evidence = { Cast = true },
        })
        fw.not_nil(rule)
        fw.eq(rule.SpellId, 389539, "Sentinel matches normally when talent is present")
    end)

    fw.it("no talent data (real enemy scenario) -> ExcludeIfTalent inactive -> AW matches first", function()
        -- For real enemies, UnitHasTalent always returns false (no talent data loaded).
        -- AW's ExcludeIfTalent=389539 never fires -> AW is returned first (precedes Sentinel in list).
        wow.setUnitClass("arena1", "PALADIN")
        mods.talents._setSpec("arena1", 66)
        -- talent 389539 NOT set -> UnitHasTalent returns false -> ExcludeIfTalent inactive

        local rule = B:MatchRule("arena1", IMP, 25.0, {
            Evidence = { Cast = true },
            IgnoreTalentRequirements = true,
        })
        fw.not_nil(rule)
        fw.eq(rule.SpellId, 31884,
            "AW matches when no talent data is loaded (ExcludeIfTalent never fires for real enemies)")
    end)
end)

-- Section 2: AW vs AC duration ambiguity for enemy Paladins
--
-- Because enemy talent data is absent, neither ExcludeIfTalent (AW) nor RequiresTalent (AC)
-- fires for enemies.  Duration is the only distinguisher:
--   AW: MinDuration=true, BuffDuration=12 -> matches at measuredDuration ≥ 11.5
--   AC: MinDuration=true, BuffDuration=10 -> matches at measuredDuration ≥ 9.5
-- Brain resolves ambiguity by spec rule order: AW precedes AC in spec 65's list.

fw.describe("Enemy MatchRule - Holy Paladin AW vs AC without talent data", function()
    fw.before_each(reset)

    fw.it("10s aura -> AW fails MinDuration (10 < 11.5) -> AC matches via IgnoreTalentRequirements", function()
        wow.setUnitClass("arena1", "PALADIN")
        mods.talents._setSpec("arena1", 65)

        local rule = B:MatchRule("arena1", IMP, 10.0, {
            Evidence = { Cast = true },
            IgnoreTalentRequirements = true,
        })
        fw.not_nil(rule)
        fw.eq(rule.SpellId, 216331, "10s -> only AC passes MinDuration (≥ 9.5)")
    end)

    fw.it("12s aura -> AW passes MinDuration first (listed before AC) -> AW returned", function()
        wow.setUnitClass("arena1", "PALADIN")
        mods.talents._setSpec("arena1", 65)

        local rule = B:MatchRule("arena1", IMP, 12.0, {
            Evidence = { Cast = true },
            IgnoreTalentRequirements = true,
        })
        fw.not_nil(rule)
        fw.eq(rule.SpellId, 31884, "12s -> AW is listed first and passes MinDuration (≥ 11.5)")
    end)
end)

-- Section 3: Empty candidateUnits for EXTERNAL_DEFENSIVE auras
--
-- ECD's FireAuraChanged never passes candidateUnits, so FindBestCandidate's EXT candidate
-- loop is empty.  Pre-12.0.5: no attribution (nil).  12.0.5: self-cast fallback fires,
-- allowing the target to be attributed as caster of their own EXT defensive.

fw.describe("Enemy FindBestCandidate - empty candidateUnits for EXT auras", function()
    fw.before_each(reset)

    fw.it("pre-12.0.5: EXT aura with no candidateUnits -> nil (no attribution possible)", function()
        wow.setUnitClass("arena2", "DRUID")
        local entry = loader.makeEntry("arena2")
        -- No Cast evidence, no candidates -> nothing matches.
        local tracked = makeTracked(EXT, 1.0, {})
        local rule = B:FindBestCandidate(entry, tracked, 10.0, {}, { IgnoreTalentRequirements = true })
        fw.is_nil(rule, "EXT aura with empty candidateUnits on pre-12.0.5 -> nil")
    end)

    fw.it("12.0.5: EXT aura self-cast fallback -> Disc Priest Pain Suppression on self", function()
        -- On 12.0.5, when no non-target candidates match, the self-cast fallback gives the
        -- target synthetic Cast evidence and tries again.  Disc Priest spec 256 has Pain
        -- Suppression (SpellId=33206, EXT, BuffDuration=8, RequiresEvidence="Cast").
        B:_TestSetSimulateNoCastSucceeded(true)
        wow.setUnitClass("arena2", "PRIEST")
        mods.talents._setSpec("arena2", 256)
        local entry = loader.makeEntry("arena2")
        -- No cast snapshot (ECD has no spell IDs) - synthetic Cast comes from the fallback.
        local tracked = makeTracked(EXT, 1.0, {})
        local rule, unit = B:FindBestCandidate(entry, tracked, 8.0, {}, { IgnoreTalentRequirements = true })
        fw.not_nil(rule, "Self-cast EXT fallback on 12.0.5 -> Pain Suppression matches")
        fw.eq(rule.SpellId, 33206, "Pain Suppression (33206)")
        fw.eq(unit, "arena2", "ruleUnit is the Disc Priest themselves (self-cast)")
    end)

    fw.it("non-EXT (BIG) aura: only target is checked, empty candidateUnits is fine", function()
        -- BIG_DEFENSIVE auras are always self-cast; only entry.Unit is considered.
        -- Empty candidateUnits is irrelevant for BIG auras.
        B:_TestSetSimulateNoCastSucceeded(true)
        wow.setUnitClass("arena1", "DRUID")
        local entry = loader.makeEntry("arena1")
        -- Synthetic Cast is granted to non-player candidates on 12.0.5.
        local tracked = makeTracked(BIG, 1.0, {})
        local rule, unit = B:FindBestCandidate(entry, tracked, 8.0, {}, { IgnoreTalentRequirements = true })
        fw.not_nil(rule, "BIG aura with empty candidateUnits -> only target matched")
        fw.eq(rule.SpellId, 22812, "Barkskin (22812)")
        fw.eq(unit, "arena1")
    end)
end)

-- Section 4: UnitFlags evidence for enemy Hunter -> AotT detection
--
-- ECD registers UNIT_FLAGS for enemy units (RecordUnitFlagsChange runs just like for friendly).
-- Aspect of the Turtle (SpellId=186265, BIG+IMP, CanCancelEarly, RequiresEvidence={Cast,UnitFlags})
-- matches when both Cast and UnitFlags evidence are present at aura removal time.

fw.describe("Enemy FindBestCandidate - UnitFlags evidence enables AotT detection", function()
    fw.before_each(reset)

    fw.it("Cast + UnitFlags evidence -> AotT matches", function()
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        -- CastSnapshot: arena1 cast at T=1.0 (same as StartTime).
        -- Evidence: Cast+UnitFlags both recorded at aura start.
        local tracked = makeTracked(BIG, 1.0, { ["arena1"] = 1.0 }, { Cast = true, UnitFlags = true })
        local rule, unit = B:FindBestCandidate(entry, tracked, 5.0, {}, { IgnoreTalentRequirements = true })
        fw.not_nil(rule, "AotT should match with Cast+UnitFlags evidence")
        fw.eq(rule.SpellId, 186265, "Aspect of the Turtle (186265)")
        fw.eq(unit, "arena1", "ruleUnit is the enemy Hunter")
    end)

    fw.it("Cast only (no UnitFlags) -> AotT does NOT match", function()
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        local tracked = makeTracked(BIG, 1.0, { ["arena1"] = 1.0 }, { Cast = true })
        local rule = B:FindBestCandidate(entry, tracked, 5.0, {}, { IgnoreTalentRequirements = true })
        fw.is_nil(rule, "AotT requires UnitFlags - Cast alone is not sufficient")
    end)

    fw.it("UnitFlags only (no Cast) -> AotT does NOT match", function()
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        -- No cast snapshot (no Cast evidence), only UnitFlags.
        local tracked = makeTracked(BIG, 1.0, {}, { UnitFlags = true })
        local rule = B:FindBestCandidate(entry, tracked, 5.0, {}, { IgnoreTalentRequirements = true })
        fw.is_nil(rule, "AotT requires Cast - UnitFlags alone is not sufficient")
    end)
end)

-- Section 5: FeignDeath suppresses UnitFlags for enemy Hunter
--
-- When UnitIsFeignDeath returns true for a Hunter during UNIT_FLAGS, RecordUnitFlagsChange
-- records FeignDeath evidence and does NOT set UnitFlags.  AotT requires UnitFlags, so it
-- fails when the flags change was caused by feign death rather than an immune effect.
-- This is the same logic as the friendly FeignDeath tests but exercised for enemy units.

fw.describe("Enemy FindBestCandidate - FeignDeath suppresses UnitFlags", function()
    fw.before_each(reset)

    fw.it("FeignDeath evidence present, UnitFlags absent -> AotT does NOT match", function()
        wow.setUnitClass("arena1", "HUNTER")
        local entry = loader.makeEntry("arena1")
        -- FeignDeath was recorded (not UnitFlags) at aura detection.
        local tracked = makeTracked(BIG, 1.0, { ["arena1"] = 1.0 }, { Cast = true, FeignDeath = true })
        local rule = B:FindBestCandidate(entry, tracked, 5.0, {}, { IgnoreTalentRequirements = true })
        fw.is_nil(rule, "FeignDeath instead of UnitFlags -> AotT does not match")
    end)
end)

-- Section 6: Observer pipeline - UnitFlags and FeignDeath recording for enemy units
--
-- Verifies that the full observer event chain (UNIT_FLAGS -> RecordUnitFlagsChange ->
-- evidence -> aura removal -> FindBestCandidate) works correctly for enemy units.

local AURA_ID = 8001  -- distinct from other test files

fw.describe("Enemy observer pipeline - UnitFlags and FeignDeath evidence recording", function()
    fw.before_each(reset)

    local function setupEnemyHunterAndWatcher(unit, auraId)
        local entry = loader.makeEntry(unit)
        -- Mark the aura as BIG (not EXT, not IMPORTANT-filtered) so BuildCurrentAuraIds
        -- classifies it as BIG_DEFENSIVE + IMPORTANT.
        wow.setAuraFiltered(unit, auraId, "HELPFUL|EXTERNAL_DEFENSIVE", true)  -- BIG, not EXT
        -- IMPORTANT filter not set -> aura IS important (not filtered = visible).
        local watcher = loader.makeWatcher(
            { { AuraInstanceID = auraId } },
            { { AuraInstanceID = auraId } }
        )
        return entry, watcher
    end

    fw.it("not feigning: UnitFlags recorded -> AotT cooldown committed on aura removal", function()
        wow.setUnitClass("arena1", "HUNTER")
        wow.setFeignDeath("arena1", false)  -- not feigning

        local entry, watcher = setupEnemyHunterAndWatcher("arena1", AURA_ID)
        local gotCdKey = nil
        B:RegisterCooldownCallback(function(ruleUnit, cdKey) gotCdKey = cdKey end)

        wow.setTime(0)
        observer:_fireUnitFlags("arena1")  -- RecordUnitFlagsChange: not feigning -> lastUnitFlagsTime=0
        observer:_fireCast("arena1")       -- RecordCast(unit, nil): lastCastTime=0, no spell ID

        -- Aura appears at T=0.
        observer:_fireAuraChanged(entry, watcher, { "arena1" })

        -- Aura removed at T=5 -> AotT: CanCancelEarly, 5 <= 8.5 -> ok. {Cast,UnitFlags} both present.
        wow.setTime(5)
        local watcherEmpty = loader.makeWatcher({}, {})
        observer:_fireAuraChanged(entry, watcherEmpty, { "arena1" })

        fw.eq(gotCdKey, 186265, "not feigning -> UnitFlags recorded -> AotT matched -> cooldown committed")
    end)

    fw.it("feigning: FeignDeath suppresses UnitFlags -> AotT NOT committed", function()
        wow.setUnitClass("arena1", "HUNTER")
        wow.setFeignDeath("arena1", true)  -- feigning at moment UNIT_FLAGS fires

        local entry, watcher = setupEnemyHunterAndWatcher("arena1", AURA_ID + 1)
        local gotCdKey = nil
        B:RegisterCooldownCallback(function(ruleUnit, cdKey) gotCdKey = cdKey end)

        wow.setTime(0)
        -- Hunter is feigning -> RecordUnitFlagsChange records FeignDeath, NOT UnitFlags.
        observer:_fireUnitFlags("arena1")
        observer:_fireCast("arena1")

        observer:_fireAuraChanged(entry, watcher, { "arena1" })

        wow.setTime(5)
        local watcherEmpty = loader.makeWatcher({}, {})
        observer:_fireAuraChanged(entry, watcherEmpty, { "arena1" })

        -- AotT requires {Cast, UnitFlags} - UnitFlags was suppressed by FeignDeath -> no match.
        fw.is_nil(gotCdKey, "feigning -> FeignDeath suppresses UnitFlags -> AotT not matched -> no cooldown")
    end)
end)
