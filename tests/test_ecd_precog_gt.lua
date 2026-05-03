-- Tests for Precognition and Grounding Totem suppression on the enemy-cooldown path.
--
-- Grounding Totem (shaman PvP talent) creates a short IMPORTANT aura on nearby allies and
-- enemies.  On the friendly path this is filtered by IsProbablyGroundingTotem (commit) and
-- IsProbablyPrecognition (predict).  On the enemy path EnemyCooldowns applies both guards
-- before calling B:PredictSpellId, and B:FindBestCandidate applies them on the commit side
-- with opts.IgnoreTalentRequirements=true since enemy talent data is unavailable.
--
-- Without these guards a GT aura landing on a Shadow Priest would falsely commit Voidform;
-- on a Warrior it would falsely commit any matching IMPORTANT cooldown.
--
-- Public APIs tested:
--   B:IsProbablyPrecognition(auraTypes, unit, measuredDuration?, evidence?)
--   B:IsProbablyGroundingTotem(auraTypes, unit, candidates, measuredDuration?, evidence?,
--                               castSpellIdSnapshot?, startTime?, ignoreTalentReqs?)
--   B:FindBestCandidate(entry, tracked, duration, candidateUnits, opts)
--     opts.IgnoreTalentRequirements = true  (ECD path: no talent data for enemies)
--
-- Spell/talent IDs referenced:
--   Grounding Totem  204336  SHAMAN ByClass, Important=true, RequiresTalent={3620,3622,715}

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

local function makeTracked(auraTypes, startTime, evidence)
    return {
        StartTime           = startTime or 1.0,
        AuraTypes           = auraTypes,
        Evidence            = evidence,
        CastSnapshot        = {},
        CastSpellIdSnapshot = {},
    }
end

-- opts passed to FindBestCandidate to simulate the enemy-cooldown path.
local ECD_OPTS = { IgnoreTalentRequirements = true }

-- Section 1: IsProbablyPrecognition - direct API, prediction path (nil evidence)
--
-- On the ECD predict path EnemyCooldowns calls B:IsProbablyPrecognition before B:PredictSpellId.
-- Evidence is nil at that point (aura just appeared; the evidence window hasn't closed yet).
-- With nil evidence the function skips the UnitFlags check and uses class + PvP context only.

fw.describe("IsProbablyPrecognition - enemy prediction path suppression", function()
    fw.before_each(reset)

    fw.it("suppresses Shadow Priest in arena with IMPORTANT-only aura and no evidence", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "PRIEST")
        fw.eq(B:IsProbablyPrecognition(IMP, "arena1", nil, nil), true,
            "PRIEST is a caster class - Precognition applies in arena with IMPORTANT-only aura")
    end)

    fw.it("suppresses Enhancement Shaman in arena with IMPORTANT-only aura and no evidence", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "SHAMAN")
        fw.eq(B:IsProbablyPrecognition(IMP, "arena1", nil, nil), true,
            "SHAMAN is a caster class - Precognition applies in arena with IMPORTANT-only aura")
    end)

    fw.it("does not suppress Warrior in arena - Warrior cannot receive Precognition", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "WARRIOR")
        fw.eq(B:IsProbablyPrecognition(IMP, "arena1", nil, nil), false,
            "WARRIOR is exempt from Precognition suppression (precogIgnoreClasses)")
    end)

    fw.it("does not suppress outside PvP - Precognition only fires in arena or pvp", function()
        -- Default wow_api instance type is 'none' (PvE overworld).
        wow.setUnitClass("arena1", "PRIEST")
        fw.eq(B:IsProbablyPrecognition(IMP, "arena1", nil, nil), false,
            "Precognition suppression requires PvP/arena context")
    end)

    fw.it("does not suppress when measured duration exceeds Precognition maximum", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "PRIEST")
        -- Precognition max is 4.0s; 4.6 > 4.0 + 0.5 tolerance.
        fw.eq(B:IsProbablyPrecognition(IMP, "arena1", 4.6, nil), false,
            "Duration beyond Precognition max rules it out on the commit path")
    end)
end)

-- Section 2: IsProbablyGroundingTotem with ignoreTalentReqs=true
--
-- On the enemy path talent data is unavailable, so any SHAMAN unit is treated as potentially
-- having Grounding Totem.  ignoreTalentReqs=true enables this behaviour.

fw.describe("IsProbablyGroundingTotem - enemy path (ignoreTalentReqs=true)", function()
    fw.before_each(reset)

    fw.it("suppresses IMPORTANT aura on Warrior when any enemy Shaman is a candidate", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "WARRIOR")
        wow.setUnitClass("arena2", "SHAMAN")
        fw.eq(B:IsProbablyGroundingTotem(IMP, "arena1", {"arena2"}, nil, nil, nil, 1.0, true), true,
            "GT spillover on melee Warrior should be suppressed when enemy Shaman is a candidate")
    end)

    fw.it("suppresses IMPORTANT aura on Priest when any enemy Shaman is a candidate", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "PRIEST")
        wow.setUnitClass("arena2", "SHAMAN")
        fw.eq(B:IsProbablyGroundingTotem(IMP, "arena1", {"arena2"}, nil, nil, nil, 1.0, true), true,
            "GT spillover on caster Priest should be suppressed when enemy Shaman is a candidate")
    end)

    fw.it("does not suppress when the target IS the Shaman - GT commits for its own caster", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "SHAMAN")
        -- No earlier candidate - tiebreaker does not fire; Shaman is not suppressed.
        fw.eq(B:IsProbablyGroundingTotem(IMP, "arena1", {}, nil, nil, nil, 1.0, true), false,
            "The Shaman's own GT aura must not be suppressed so it can commit (204336)")
    end)

    fw.it("does not suppress when no Shaman candidate is present", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "WARRIOR")
        wow.setUnitClass("arena2", "WARRIOR")
        fw.eq(B:IsProbablyGroundingTotem(IMP, "arena1", {"arena2"}, nil, nil, nil, 1.0, true), false,
            "GT suppression does not fire when no Shaman is in the candidate list")
    end)

    fw.it("does not suppress when measured duration exceeds GT maximum", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "WARRIOR")
        wow.setUnitClass("arena2", "SHAMAN")
        -- GT max is 3.5s; 4.1 > 3.5 + 0.5 tolerance = 4.0.
        fw.eq(B:IsProbablyGroundingTotem(IMP, "arena1", {"arena2"}, 4.1, nil, nil, 1.0, true), false,
            "Duration beyond GT max rules out GT as the source")
    end)

    fw.it("does not suppress outside PvP - GT only applies in arena/pvp", function()
        -- Default wow_api instance type is 'none'.
        wow.setUnitClass("arena1", "WARRIOR")
        wow.setUnitClass("arena2", "SHAMAN")
        fw.eq(B:IsProbablyGroundingTotem(IMP, "arena1", {"arena2"}, nil, nil, nil, 1.0, true), false,
            "GT suppression only fires in PvP/arena context")
    end)
end)

-- Section 3: FindBestCandidate integration - enemy-cooldown commit path
--
-- EnemyCooldowns calls B:FindBestCandidate with opts.IgnoreTalentRequirements=true after a
-- tracked aura ends and its duration is measured.  The GT guard inside searchNonExternal fires
-- with ignoreTalentReqs=true, suppressing false commits on non-Shaman targets.

fw.describe("FindBestCandidate - enemy path GT suppression (IgnoreTalentRequirements=true)", function()
    fw.before_each(reset)

    fw.it("GT aura on enemy Priest returns nil - GT spillover suppresses false Priest cooldown", function()
        -- Core scenario: enemy Shaman uses GT; the IMPORTANT aura lands on the enemy Priest.
        -- Without GT suppression this would falsely commit a Priest cooldown (e.g. Dispersion).
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "PRIEST")
        wow.setUnitClass("arena2", "SHAMAN")
        local entry = loader.makeEntry("arena1")
        local t     = makeTracked(IMP, 1.0, nil)
        local rule  = B:FindBestCandidate(entry, t, 2.0, {"arena2"}, ECD_OPTS)
        fw.is_nil(rule, "GT spillover on Priest should not commit any cooldown")
    end)

    fw.it("GT aura on enemy Warrior returns nil - GT spillover suppresses false Warrior cooldown", function()
        -- Warrior is exempt from Precognition but the GT guard handles melee-class spillover.
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "WARRIOR")
        wow.setUnitClass("arena2", "SHAMAN")
        local entry = loader.makeEntry("arena1")
        local t     = makeTracked(IMP, 1.0, nil)
        local rule  = B:FindBestCandidate(entry, t, 2.0, {"arena2"}, ECD_OPTS)
        fw.is_nil(rule, "GT spillover on Warrior should not commit any cooldown")
    end)

    fw.it("GT commits for enemy Shaman with IgnoreTalentRequirements - no talent data required", function()
        -- The Shaman's own GT aura is not suppressed; RequiresTalent is bypassed via
        -- IgnoreTalentRequirements so GT (204336) matches without talent lookup.
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "SHAMAN")
        local entry      = loader.makeEntry("arena1")
        local t          = makeTracked(IMP, 1.0, nil)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, {}, ECD_OPTS)
        fw.not_nil(rule, "Grounding Totem should commit for the enemy Shaman (no talent data needed)")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem (204336)")
        fw.eq(unit, "arena1", "Enemy Shaman (arena1) is the attributed caster")
    end)

    fw.it("GT aura on Priest suppressed even when there is no GT Shaman talent set", function()
        -- ignoreTalentReqs treats any Shaman class as a potential GT caster regardless of
        -- whether talent data has been loaded, mirroring ECD's runtime behaviour.
        wow.setInstanceType("arena")
        wow.setUnitClass("arena1", "PRIEST")
        wow.setUnitClass("arena2", "SHAMAN")
        -- No mods.talents._setTalent call - enemy talent data is absent.
        local entry = loader.makeEntry("arena1")
        local t     = makeTracked(IMP, 1.0, nil)
        local rule  = B:FindBestCandidate(entry, t, 2.0, {"arena2"}, ECD_OPTS)
        fw.is_nil(rule, "GT suppression works without any talent data when IgnoreTalentRequirements=true")
    end)
end)
