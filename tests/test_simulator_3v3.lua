-- Rule-driven simulator (3v3): for every rule in Rules.lua, synthesises a 3v3 arena
-- scenario and verifies friendly tracking (full observer pipeline).
--
-- Difference from the 2v2 simulator: for EXT and CastableOnOthers rules a second
-- potential caster (party3) is added alongside the actual caster (party2).  Both are
-- the same class and spec as the rule under test but party3 has no RequiresTalent set,
-- so any talent-gated rule variation is only present on party2.
--
-- This surfaces genuine ambiguities that arise when the observer cannot determine which
-- of two teammates cast an EXT spell (12.0.5+: no UNIT_SPELLCAST_SUCCEEDED for others).
-- In particular:
--   · EXT commit tests are almost universally ambiguous - both candidates receive
--     synthetic Cast evidence with no timing tiebreaker, so FindBestCandidate returns nil.
--   · EXT predict tests pass: same spellId from both candidates -> PredictRule is not
--     ambiguous (same-spellId branch, not the different-spellId ambiguous branch).
--   · Exception: BoSpellwarding (204018) - party3 (no Spellwarding talent) matches BoP
--     (1022) instead, producing a different spellId -> predict also fails.
--   · Exception: Guardian Spirit talent (47788 at 12s) - party3 (no Foreseen Circumstances
--     talent) tries to match the base 10s rule; the 2s duration gap exceeds MatchRule's
--     tolerance, so party3 fails and only party2 matches -> commit passes (shows as XPASS
--     against the xfail marking shared with the base 10s rule).
--
-- Enemy tests are omitted: they test single-unit arena1 identification and are already
-- covered by the 2v2 simulator.
--
-- Per rule the simulator runs up to four tests (friendly only):
--   friendly-predict   predictiveGlowCallback fires with rule.SpellId
--   friendly-commit    cooldownCallback fires with cdKey = rule.SpellId
--   CanCancelEarly@Xs  friendly-commit at short duration
--   CanCancelEarly@Xs  friendly-commit at short duration

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer
local rules    = mods.rules

local SIM_ID = 9001

local specToClass = {
    [65]   = "PALADIN",    [66]  = "PALADIN",    [70]  = "PALADIN",
    [71]   = "WARRIOR",    [72]  = "WARRIOR",    [73]  = "WARRIOR",
    [62]   = "MAGE",       [63]  = "MAGE",       [64]  = "MAGE",
    [253]  = "HUNTER",     [254] = "HUNTER",     [255] = "HUNTER",
    [256]  = "PRIEST",     [257] = "PRIEST",     [258] = "PRIEST",
    [259]  = "ROGUE",      [260] = "ROGUE",      [261] = "ROGUE",
    [250]  = "DEATHKNIGHT",[251] = "DEATHKNIGHT",[252] = "DEATHKNIGHT",
    [262]  = "SHAMAN",     [263] = "SHAMAN",     [264] = "SHAMAN",
    [265]  = "WARLOCK",    [266] = "WARLOCK",    [267] = "WARLOCK",
    [268]  = "MONK",       [269] = "MONK",       [270] = "MONK",
    [577]  = "DEMONHUNTER",[581] = "DEMONHUNTER",[1480]= "DEMONHUNTER",
    [102]  = "DRUID",      [103] = "DRUID",      [104] = "DRUID",  [105] = "DRUID",
    [1467] = "EVOKER",     [1468]= "EVOKER",     [1473]= "EVOKER",
}

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

local function inferAuraTypes(rule)
    local t = {}
    if rule.BigDefensive      == true then t.BIG_DEFENSIVE      = true end
    if rule.ExternalDefensive == true then t.EXTERNAL_DEFENSIVE = true end
    if rule.Important         == true then t.IMPORTANT          = true end
    if rule.CrowdControl      == true then t.CROWD_CONTROL      = true end
    if not t.BIG_DEFENSIVE and not t.EXTERNAL_DEFENSIVE and not t.IMPORTANT then
        t.IMPORTANT = true
    end
    return t
end

local function setRequiredTalent(unit, req)
    if not req then return end
    if type(req) == "table" then
        mods.talents._setTalent(unit, req[1], true)
    else
        mods.talents._setTalent(unit, req, true)
    end
end

local function makePresenceWatcher(unit, auraTypes, id)
    if auraTypes.CROWD_CONTROL then
        wow.setAuraFiltered(unit, id, "HARMFUL|CROWD_CONTROL", false)
        wow.setAuraFiltered(unit, id, "HELPFUL|CROWD_CONTROL", false)
    end
    if auraTypes.BIG_DEFENSIVE then
        wow.setAuraFiltered(unit, id, "HELPFUL|EXTERNAL_DEFENSIVE", true)
        return loader.makeWatcher({ { AuraInstanceID = id } }, { { AuraInstanceID = id } })
    elseif auraTypes.EXTERNAL_DEFENSIVE then
        return loader.makeWatcher({ { AuraInstanceID = id } }, {})
    else
        return loader.makeWatcher({}, { { AuraInstanceID = id } })
    end
end

local function fireNonCastEvidence(rule, unit)
    local req = rule.RequiresEvidence
    if not req then return end
    local list = type(req) == "table" and req or { req }
    for _, r in ipairs(list) do
        if r == "Debuff" then
            observer:_fireDebuffEvidence(unit, {
                isFullUpdate = false,
                addedAuras   = { { auraInstanceID = 9999 } },
            })
        elseif r == "Shield" then
            observer:_fireShield(unit)
        elseif r == "UnitFlags" then
            observer:_fireUnitFlags(unit)
        end
    end
end

local function shortDuration(rule)
    local half = rule.BuffDuration * 0.5
    if rule.MinCancelDuration then
        half = math.max(half, rule.MinCancelDuration + 0.1)
    end
    return math.max(0.5, math.floor(half * 10 + 0.5) / 10)
end

-- Known ambiguities for the 3v3 scenario.
--
-- Most EXT commit cases are NOT ambiguous: when two same-class candidates both match the
-- same rule (same SpellId), FindBestCandidate's same-rule tiebreaker picks the first
-- candidate - identical to PredictRule's same-SpellId path.  Only cases where the two
-- candidates implicate DIFFERENT SpellIds remain genuinely ambiguous.
--
-- BoSpellwarding (204018): the only EXT rule that generates different spellIds from the
-- two candidates.  party3 (no Spellwarding talent) matches BoP (1022) instead, so
-- PredictRule sees two different SpellIds -> ambiguous -> no glow.  FBC likewise sets
-- ambiguous -> no commit.  Both predict and commit are xfail for all three Paladin specs.
--
-- All 2v2 predict-path ambiguities (AW/AC BoF interference etc.) are inherited unchanged:
-- those are non-EXT self-cast rules where party3 is not in the candidate list.
local knownAmbiguities3v3 = {
    bySpec = {
        -- Holy Paladin: all self-only IMPORTANT spells are ambiguous with Blessing of Freedom
        -- (class rule, CastableOnOthers, also IMPORTANT, no RequiresEvidence) for remote targets
        -- in 12.0.5+ (no cast snapshot).  BoSpellwarding is also ambiguous (party3 candidate).
        [65] = {
            [31884]  = { predict = true },
            [216331] = { predict = true },
            [204018] = { predict = true, commit = true },
        },
        -- Protection Paladin: GAoK structurally ambiguous with Ardent Defender; BoSpellwarding same.
        -- AW (31884) and Sentinel (389539) also ambiguous with BoF (IMPORTANT, no evidence).
        [66] = {
            [86659]  = { predict = true, commit = true },
            [31884]  = { predict = true },
            [389539] = { predict = true },
            [204018] = { predict = true, commit = true },
        },
        -- Retribution Paladin: Divine Protection (403876) predict-ambiguous with AW (no duration gate
        -- in predict path); commit correctly resolves via duration check.  BoSpellwarding ambiguous.
        -- AW (31884) also ambiguous with BoF (same IMPORTANT, no evidence) for remote Paladins.
        [70] = {
            [31884]  = { predict = true },
            [403876] = { predict = true },
            [204018] = { predict = true, commit = true },
        },
        -- Subtlety Rogue: Shadow Blades (121471) is excluded from prediction (ExcludeFromPrediction=true)
        -- because Shadow Dance is also IMPORTANT and indistinguishable from Shadow Blades at
        -- detection time (before the aura expires and duration is measured).
        [261] = { [121471] = { predict = true } },
    },
    byClass = {
        -- Blessing of Freedom (1044): CastableOnOthers, no RequiresEvidence.
        -- party2 and party3 (both non-local Paladins) have no UNIT_SPELLCAST_SUCCEEDED -> no snapshot.
        -- The "only_evidence" filter skips RequiresEvidence=nil rules in the evidence-only COO fallback.
        PALADIN = { [1044] = { predict = true } },
        -- Evasion (5277): ExcludeFromPrediction=true because Shadow Dance is also IMPORTANT
        -- and indistinguishable from Evasion at detection time (before duration is measured).
        ROGUE = { [5277] = { predict = true } },
    },
}

local function sortedKeys(t, cmp)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, cmp)
    return keys
end

local function runRuleTests(source, specId, classToken, rule)
    if not rule.SpellId then return end

    local auraTypes = inferAuraTypes(rule)
    local isExt = auraTypes.EXTERNAL_DEFENSIVE == true
    local isCOO = (not isExt) and (rule.CastableOnOthers == true)
    local hasCaster = isExt or isCOO

    local targetUnit = "party1"
    -- party3 is only added for EXTERNAL_DEFENSIVE rules: these are the genuine 3v3 ambiguity
    -- cases where neither the observer nor the system can tell which of two same-class teammates
    -- cast the external buff (no UNIT_SPELLCAST_SUCCEEDED for non-local units in 12.0.5).
    -- CastableOnOthers non-EXT rules (BoF, AMS Spellwarding) keep the 2v2 candidate list to
    -- avoid spellId collisions with co-located self-cast rules sharing the same SpellId.
    local candidates = isExt and { "party1", "party2", "party3" }
                    or hasCaster and { "party1", "party2" }
                    or { "party1" }

    -- Set up friendly units in 12.0.5 mode.
    -- party2: actual caster - correct class, spec, and RequiresTalent.
    -- party3 (EXT only): second potential caster - same class and spec as party2, no
    --   RequiresTalent.  Models a teammate whose talent state is unknown; their presence
    --   creates the 3v3 commit ambiguity for rules that fire no real cast evidence.
    local function setupFriendly()
        if hasCaster then
            wow.setUnitClass("party1", "WARRIOR")
            wow.setUnitClass("party2", classToken)
            if specId then mods.talents._setSpec("party2", specId) end
            setRequiredTalent("party2", rule.RequiresTalent)
        else
            wow.setUnitClass("party1", classToken)
            if specId then mods.talents._setSpec("party1", specId) end
            setRequiredTalent("party1", rule.RequiresTalent)
        end
        if isExt then
            wow.setUnitClass("party3", classToken)
            if specId then mods.talents._setSpec("party3", specId) end
            -- No RequiresTalent for party3: it is the "other" potential caster whose specific
            -- talent variant is unknown, which is the source of BoSpellwarding predict ambiguity
            -- and the general EXT commit ambiguity across all 3v3 scenarios.
        end
    end

    local label = source .. " | " .. tostring(rule.SpellId) .. " | " .. rule.BuffDuration .. "s"

    local ambig = (specId and knownAmbiguities3v3.bySpec[specId] and knownAmbiguities3v3.bySpec[specId][rule.SpellId])
               or (not specId and knownAmbiguities3v3.byClass[classToken] and knownAmbiguities3v3.byClass[classToken][rule.SpellId])
               or {}
    local itPredict = ambig.predict and fw.xfail or fw.it
    local itCommit  = ambig.commit  and fw.xfail or fw.it

    -- Friendly predict: aura appears -> predictiveGlowCallback fires with rule.SpellId.
    -- For EXT rules where two same-class candidates match the same spellId, PredictRule's
    -- same-spellId tiebreaker applies (not the ambiguous branch) -> predict passes.
    itPredict(label .. " | friendly-predict", function()
        setupFriendly()
        local captured = nil
        B:RegisterPredictiveGlowCallback(function(_, sid) captured = sid end)

        wow.setTime(0)
        fireNonCastEvidence(rule, targetUnit)

        local entry   = loader.makeEntry(targetUnit)
        local watcher = makePresenceWatcher(targetUnit, auraTypes, SIM_ID)
        observer:_fireAuraChanged(entry, watcher, candidates)

        fw.eq(captured, rule.SpellId, label)
    end)

    -- Friendly commit: aura removed at full BuffDuration -> cooldownCallback fires.
    -- For EXT/COO rules, both party2 and party3 receive synthetic Cast with no real cast
    -- timestamp -> FindBestCandidate finds two matching candidates with identical evidence
    -- and no tiebreaker -> ambiguous -> returns nil -> cooldownCallback does not fire.
    -- These are marked as xfail in knownAmbiguities3v3.
    itCommit(label .. " | friendly-commit", function()
        setupFriendly()
        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        wow.setTime(0)
        fireNonCastEvidence(rule, targetUnit)

        local entry   = loader.makeEntry(targetUnit)
        local watcher = makePresenceWatcher(targetUnit, auraTypes, SIM_ID)
        observer:_fireAuraChanged(entry, watcher, candidates)

        wow.advanceTime(rule.BuffDuration)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), candidates)

        fw.eq(committed, rule.SpellId, label)
    end)

    -- CanCancelEarly tests at short duration.
    if rule.CanCancelEarly then
        local sd     = shortDuration(rule)
        local slabel = label .. " | CanCancelEarly@" .. sd .. "s"

        itCommit(slabel .. " | friendly-commit", function()
            setupFriendly()
            local committed = nil
            B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

            wow.setTime(0)
            fireNonCastEvidence(rule, targetUnit)

            local entry   = loader.makeEntry(targetUnit)
            local watcher = makePresenceWatcher(targetUnit, auraTypes, SIM_ID)
            observer:_fireAuraChanged(entry, watcher, candidates)

            wow.advanceTime(sd)
            observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), candidates)

            fw.eq(committed, rule.SpellId, slabel)
        end)
    end
end

fw.describe("Rule-driven simulator (3v3) - all rules, friendly only", function()
    fw.before_each(reset)

    for _, specId in ipairs(sortedKeys(rules.BySpec, function(a, b) return a < b end)) do
        local classToken = specToClass[specId]
        if classToken then
            local source = "spec" .. specId .. "/" .. classToken
            for _, rule in ipairs(rules.BySpec[specId]) do
                runRuleTests(source, specId, classToken, rule)
            end
        end
    end

    for _, classToken in ipairs(sortedKeys(rules.ByClass)) do
        local ruleList = rules.ByClass[classToken]
        if #ruleList > 0 then
            local source = "class/" .. classToken
            for _, rule in ipairs(ruleList) do
                runRuleTests(source, nil, classToken, rule)
            end
        end
    end
end)
