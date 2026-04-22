-- Rule-driven simulator: for every rule in Rules.lua, synthesises a minimal valid
-- scenario and verifies both friendly tracking (full observer pipeline) and enemy
-- tracking (direct FindBestCandidate).  CanCancelEarly rules are also tested at
-- half their BuffDuration to cover the early-cancel path.
--
-- Per rule, the simulator runs up to five tests:
--   friendly-predict   predictiveGlowCallback fires with rule.SpellId
--   friendly-commit    cooldownCallback fires with cdKey = rule.SpellId
--   enemy-commit       FindBestCandidate returns the rule (IgnoreTalentRequirements=true)
--   CanCancelEarly@Xs  friendly-commit at short duration
--   CanCancelEarly@Xs  enemy-commit at short duration
-- ExcludeFromEnemyTracking rules skip the two enemy tests.
--
-- Both friendly and enemy tests run in 12.0.5 mode (simulateNoCastSucceeded=true).
-- This means no real cast snapshots exist; Cast evidence is synthetic.  Some rules
-- produce genuine ambiguities in this mode (e.g. Paladin AW vs class BoF, or two
-- rules sharing an aura type where duration alone doesn't disambiguate) - those
-- tests will fail and should be reviewed to confirm the ambiguity is expected.
-- RequiresTalent talents are set for both friendly and enemy tests so that sibling
-- rules' ExcludeIfTalent gates fire and the correct rule is returned.

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer
local rules    = mods.rules

-- Aura instance ID reused across simulator tests (reset() clears _auraFiltered).
local SIM_ID = 9001

-- Spec -> class-token mapping (from Rules.lua header comments).
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

-- Derive the minimal aura-type table from a rule's flags.
local function inferAuraTypes(rule)
    local t = {}
    if rule.BigDefensive      == true then t.BIG_DEFENSIVE      = true end
    if rule.ExternalDefensive == true then t.EXTERNAL_DEFENSIVE = true end
    if rule.Important         == true then t.IMPORTANT          = true end
    if rule.CrowdControl      == true then t.CROWD_CONTROL      = true end
    -- Fallback: if no explicit true flag, treat as IMPORTANT.
    if not t.BIG_DEFENSIVE and not t.EXTERNAL_DEFENSIVE and not t.IMPORTANT then
        t.IMPORTANT = true
    end
    return t
end

-- Apply a required talent (or the first of a table of alternatives) to 'unit'.
local function setRequiredTalent(unit, req)
    if not req then return end
    if type(req) == "table" then
        mods.talents._setTalent(unit, req[1], true)
    else
        mods.talents._setTalent(unit, req, true)
    end
end

-- Build a watcher that presents one aura with the given type on 'unit'.
-- BIG: aura in both GetDefensiveState (EXT-filtered out) and GetImportantState.
-- EXT: aura in GetDefensiveState with no EXT filter -> classified as EXTERNAL_DEFENSIVE.
-- IMP: aura only in GetImportantState.
-- CROWD_CONTROL: sets HARMFUL|CROWD_CONTROL to not-filtered (present as CC).
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

-- Fire non-Cast evidence events required by a rule on the given unit.
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
            -- UnitIsFeignDeath defaults to false -> records UnitFlags (not FeignDeath).
            observer:_fireUnitFlags(unit)
        end
    end
end

-- Build the non-Cast evidence table for a rule's tracked object (enemy tests).
local function buildNonCastEvidence(rule)
    local ev = {}
    local req = rule.RequiresEvidence
    if req then
        local list = type(req) == "table" and req or { req }
        for _, r in ipairs(list) do
            if r ~= "Cast" then ev[r] = true end
        end
    end
    return next(ev) ~= nil and ev or nil
end

-- Short duration for CanCancelEarly tests: half of BuffDuration, at least MinCancelDuration+0.1.
local function shortDuration(rule)
    local half = rule.BuffDuration * 0.5
    if rule.MinCancelDuration then
        half = math.max(half, rule.MinCancelDuration + 0.1)
    end
    return math.max(0.5, math.floor(half * 10 + 0.5) / 10)
end

-- Known 12.0.5 ambiguities: rules where friendly-predict or friendly-commit cannot be
-- resolved without real cast snapshots.  Tests listed here use fw.xfail so they are
-- counted as passes; if the ambiguity is ever resolved they will XPASS (visible signal).
--
-- Format: knownAmbiguities.bySpec[specId][spellId] = { predict=true, commit=true }
--         knownAmbiguities.byClass[classToken][spellId] = { predict=true, commit=true }
local knownAmbiguities = {
    bySpec = {
        -- Holy Paladin: all self-only IMPORTANT spells are ambiguous with Blessing of Freedom
        -- (class rule, CastableOnOthers, also IMPORTANT, no RequiresEvidence) for remote targets
        -- in 12.0.5+ (no cast snapshot to disambiguate).  Predict is suppressed; commit still
        -- works because MatchRule discriminates by duration.
        --   AW (31884): ambiguous with BoF (both IMPORTANT, no evidence requirement).
        --   Avenging Crusader (216331): same; talent makes it mutually exclusive with AW but
        --   BoF still matches alongside it.
        [65] = { [31884] = { predict = true }, [216331] = { predict = true } },
        -- Prot Paladin: Guardian of Ancient Kings (86659) is structurally ambiguous with
        -- Ardent Defender (both BIG+IMP+8s, Ardent Defender listed first in spec66 rules).
        -- PredictRule returns Ardent Defender; FindBestCandidate sees two different SpellIds
        -- -> ambiguous -> nil.  Unresolvable without duration or talent data at detection time.
        -- AW (31884) and Sentinel (389539) are also ambiguous with BoF (IMPORTANT, no evidence).
        [66] = { [86659] = { predict = true, commit = true }, [31884] = { predict = true }, [389539] = { predict = true } },
        -- Ret Paladin: Divine Protection (403876) is IMPORTANT+Shield, but Avenging Wrath (31884)
        -- is also IMPORTANT with no evidence requirement and is listed first in spec70 rules.
        -- PredictSpellIdForUnit has no duration gate, so AW always wins the predict pass;
        -- MatchRule's duration check correctly rejects AW at commit time (24s != 8s).
        -- AW (31884) is also ambiguous with BoF (same IMPORTANT, no evidence) for remote Paladins.
        [70] = { [403876] = { predict = true }, [31884] = { predict = true } },
    },
    byClass = {
        -- Blessing of Freedom (1044): CastableOnOthers, no RequiresEvidence.
        -- In 12.0.5 the Paladin caster (party2) has no UNIT_SPELLCAST_SUCCEEDED -> no snapshot.
        -- The evidence-only COO fallback ("only_evidence" filter) skips rules with RequiresEvidence=nil,
        -- so BoF cannot be predicted without a cast snapshot from the local player.
        PALADIN = { [1044] = { predict = true } },
    },
}

-- Sorted-keys helper for deterministic iteration.
local function sortedKeys(t, cmp)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, cmp)
    return keys
end

-- Generate all tests for a single rule entry.
--   source:     label fragment, e.g. "spec65/PALADIN"
--   specId:     number or nil (nil for ByClass rules)
--   classToken: e.g. "PALADIN"
--   rule:       rule table from Rules.lua
local function runRuleTests(source, specId, classToken, rule)
    if not rule.SpellId then return end

    local auraTypes = inferAuraTypes(rule)
    local isExt = auraTypes.EXTERNAL_DEFENSIVE == true
    -- CastableOnOthers (non-EXT): caster is party2, target is party1 (WARRIOR).
    local isCOO = (not isExt) and (rule.CastableOnOthers == true)
    local hasCaster = isExt or isCOO

    local targetUnit = "party1"
    local candidates = hasCaster and { "party1", "party2" } or { "party1" }

    -- Set up friendly units and talents in 12.0.5 mode (synthetic Cast, no snapshots).
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
    end

    -- Set up enemy unit, talents, and 12.0.5 mode.
    -- Setting RequiresTalent activates any sibling rule's ExcludeIfTalent gate, so
    -- the correct (RequiresTalent) rule wins rather than the sibling matching first.
    local function setupEnemy()
        wow.setUnitClass("arena1", classToken)
        if specId then mods.talents._setSpec("arena1", specId) end
        setRequiredTalent("arena1", rule.RequiresTalent)
    end

    local label = source .. " | " .. tostring(rule.SpellId) .. " | " .. rule.BuffDuration .. "s"

    -- Resolve known-ambiguity flags for this rule.
    local ambig = (specId and knownAmbiguities.bySpec[specId] and knownAmbiguities.bySpec[specId][rule.SpellId])
               or (not specId and knownAmbiguities.byClass[classToken] and knownAmbiguities.byClass[classToken][rule.SpellId])
               or {}
    local itPredict = ambig.predict and fw.xfail or fw.it
    local itCommit  = ambig.commit  and fw.xfail or fw.it

    -- Friendly predict: aura appears -> predictiveGlowCallback fires with rule.SpellId.
    -- In 12.0.5 mode Cast is synthetic; known ambiguous cases use fw.xfail.
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

    -- Enemy commit: direct FindBestCandidate; target gets synthetic Cast (12.0.5 mode).
    if not rule.ExcludeFromEnemyTracking then
        fw.it(label .. " | enemy-commit", function()
            setupEnemy()

            local entry   = loader.makeEntry("arena1")
            local tracked = {
                StartTime           = 1.0,
                AuraTypes           = auraTypes,
                Evidence            = buildNonCastEvidence(rule),
                CastSnapshot        = {},
                CastSpellIdSnapshot = {},
            }

            local matched = B:FindBestCandidate(
                entry, tracked, rule.BuffDuration, {}, { IgnoreTalentRequirements = true }
            )
            fw.not_nil(matched, label .. " enemy got nil")
            if matched then
                fw.eq(matched.SpellId, rule.SpellId, label .. " enemy SpellId")
            end
        end)
    end

    -- CanCancelEarly short-duration tests.
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

        if not rule.ExcludeFromEnemyTracking then
            fw.it(slabel .. " | enemy-commit", function()
                setupEnemy()

                local entry   = loader.makeEntry("arena1")
                local tracked = {
                    StartTime           = 1.0,
                    AuraTypes           = auraTypes,
                    Evidence            = buildNonCastEvidence(rule),
                    CastSnapshot        = {},
                    CastSpellIdSnapshot = {},
                }

                local matched = B:FindBestCandidate(
                    entry, tracked, sd, {}, { IgnoreTalentRequirements = true }
                )
                fw.not_nil(matched, slabel .. " enemy got nil")
                if matched then
                    fw.eq(matched.SpellId, rule.SpellId, slabel .. " enemy SpellId")
                end
            end)
        end
    end
end

-- Run all simulator tests inside one describe block so before_each(reset) applies uniformly.
fw.describe("Rule-driven simulator (2v2) - all rules, friendly + enemy", function()
    fw.before_each(reset)

    -- BySpec rules: sorted by spec ID for deterministic output.
    for _, specId in ipairs(sortedKeys(rules.BySpec, function(a, b) return a < b end)) do
        local classToken = specToClass[specId]
        if classToken then
            local source = "spec" .. specId .. "/" .. classToken
            for _, rule in ipairs(rules.BySpec[specId]) do
                runRuleTests(source, specId, classToken, rule)
            end
        end
    end

    -- ByClass rules: sorted alphabetically by class token.
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
