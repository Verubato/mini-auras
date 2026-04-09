-- Integration tests: one test per trackable spell, exercising the full pipeline:
--
--   Observer collects evidence (cast, shield, debuff, unit-flags)
--   Brain fires aura-added → predictive glow callback (asserts spell identified)
--   Brain fires aura-removed → cooldown callback (asserts spell committed)
--
-- Because C_Timer.After is stubbed synchronous, the deferred backfill and
-- PredictRule run inside the same _fireAuraChanged call, so everything is
-- deterministic with no async concerns.
--
-- Test case fields:
--   unit          string   unit that receives the buff (entry owner)
--   caster        string?  separate caster unit (external defensives only)
--   class         string   WoW class token of `unit`
--   specId        number?  spec ID of `unit`; nil = class-level rule
--   casterClass   string?  class token of `caster`
--   casterSpecId  number?  spec ID of `caster`
--   spellId       number   expected spell ID in prediction and cooldown key
--   buffDuration  number   seconds the aura is "up" before removal
--   -- Aura type wiring (matches rule flags):
--   auraIsDefensive  bool  true  = aura in GetDefensiveState (BIG or EXT)
--                          false = aura in GetImportantState only
--   isExternal    bool     true  = EXTERNAL_DEFENSIVE, false = BIG_DEFENSIVE
--                          (ignored when auraIsDefensive=false)
--   isImportant   bool     whether to add IMPORTANT to the aura types
--   -- Evidence to fire before the aura event (Cast is always fired via _fireCast):
--   evidence      string[] subset of {"Debuff","Shield","UnitFlags"}
--   -- Optional talent setup: list of {unitName, talentId}
--   talents       table?

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 1001

-- Helpers

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterCooldownCallback(nil)
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterPredictiveGlowEndCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

---Build a watcher stub that surfaces AURA_ID under the appropriate state lists,
---and wire up C_UnitAuras.IsAuraFilteredOutByInstanceID so BuildCurrentAuraIds
---classifies the aura correctly.
local function buildWatcher(unit, auraIsDefensive, isExternal, isImportant)
    local defensive, important = {}, {}

    if auraIsDefensive then
        defensive = { { AuraInstanceID = AURA_ID } }
        if not isExternal then
            -- Mark as NOT an external defensive so the code classifies it as BIG_DEFENSIVE.
            wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
        end
        -- For auras that are not Important, also filter out the IMPORTANT flag.
        if not isImportant then
            wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|IMPORTANT", true)
        end
    else
        -- IMPORTANT-only aura: lives only in GetImportantState, never in GetDefensiveState.
        important = { { AuraInstanceID = AURA_ID } }
    end

    return loader.makeWatcher(defensive, important)
end

---Fire non-Cast evidence events.  Cast is always fired separately via _fireCast
---so the spell ID is recorded in lastCastSpellIds (used by PredictRule fast path).
local function fireEvidence(unit, evidenceList)
    for _, ev in ipairs(evidenceList) do
        if ev == "Shield" then
            observer:_fireShield(unit)
        elseif ev == "Debuff" then
            observer:_fireDebuffEvidence(unit, {
                isFullUpdate = false,
                addedAuras   = { { auraInstanceID = 9999 } },
            })
        elseif ev == "UnitFlags" then
            observer:_fireUnitFlags(unit)
        end
    end
end

---Full test runner for one test case.
---Returns nil on pass, error string on failure.
local function runTest(tc)
    reset()

    -- Unit under test (the buffed target).
    wow.setUnitClass(tc.unit, tc.class)
    mods.talents._setSpec(tc.unit, tc.specId)

    -- Separate caster (external defensive).
    local caster = tc.caster or tc.unit
    if tc.caster then
        wow.setUnitClass(tc.caster, tc.casterClass)
        mods.talents._setSpec(tc.caster, tc.casterSpecId)
    end

    -- Talent prerequisites.
    if tc.talents then
        for _, t in ipairs(tc.talents) do
            mods.talents._setTalent(t[1], t[2], true)
        end
    end

    local entry          = loader.makeEntry(tc.unit)
    local candidateUnits = tc.caster and { tc.unit, tc.caster } or { tc.unit }

    -- Capture callbacks.
    local predictedSpellId, predictedCaster
    B:RegisterPredictiveGlowCallback(function(_, sid, casterUnit)
        predictedSpellId = sid
        predictedCaster  = casterUnit
    end)

    local receivedUnit, receivedKey
    B:RegisterCooldownCallback(function(ruleUnit, cdKey)
        receivedUnit = ruleUnit
        receivedKey  = cdKey
    end)

    -- T=0: cast evidence (spell ID recorded for fast path) + other evidence.
    wow.setTime(0)
    observer:_fireCast(caster, tc.spellId)
    fireEvidence(tc.unit, tc.evidence or {})

    -- Aura-added: fires TrackNewAura → deferred backfill (synchronous) → PredictRule.
    local watcher = buildWatcher(tc.unit, tc.auraIsDefensive, tc.isExternal, tc.isImportant)
    observer:_fireAuraChanged(entry, watcher, candidateUnits)

    -- Assert prediction.
    if predictedSpellId ~= tc.spellId then
        return string.format("prediction: got %s, expected %d",
            tostring(predictedSpellId), tc.spellId)
    end
    if tc.caster and predictedCaster ~= tc.caster then
        return string.format("predicted caster: got %s, expected %s",
            tostring(predictedCaster), tc.caster)
    end

    -- Advance time and fire aura-removed: triggers FindBestCandidate → CommitCooldown.
    wow.setTime(tc.buffDuration)
    local emptyWatcher = loader.makeWatcher({}, {})
    observer:_fireAuraChanged(entry, emptyWatcher, candidateUnits)

    -- Assert cooldown.
    if receivedKey ~= tc.spellId then
        return string.format("cooldown key: got %s, expected %d",
            tostring(receivedKey), tc.spellId)
    end
    if tc.caster and receivedUnit ~= tc.caster then
        return string.format("cooldown unit: got %s, expected %s",
            tostring(receivedUnit), tc.caster)
    end
    return nil
end

-- Test case table
-- Each entry is a test case understood by runTest() above.
-- 'evidence' lists only Debuff/Shield/UnitFlags; Cast is always fired automatically.

local cases = {

    -- PALADIN
    {
        desc = "Holy Paladin — Avenging Wrath (31884)",
        unit = "player", class = "PALADIN", specId = 65,
        spellId = 31884, buffDuration = 12,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Holy Paladin — Avenging Crusader (216331) [talent]",
        unit = "player", class = "PALADIN", specId = 65,
        spellId = 216331, buffDuration = 10,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 216331} },
    },
    {
        desc = "Holy Paladin — Divine Shield (642)",
        unit = "player", class = "PALADIN", specId = 65,
        spellId = 642, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {"Debuff", "UnitFlags"},
    },
    {
        desc = "Holy Paladin — Divine Protection (498)",
        unit = "player", class = "PALADIN", specId = 65,
        spellId = 498, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Holy Paladin — Blessing of Protection (1022) cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "player", casterClass = "PALADIN", casterSpecId = 65,
        spellId = 1022, buffDuration = 10,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {"Debuff"},
    },
    {
        desc = "Holy Paladin — Blessing of Spellwarding (204018) [talent] cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "player", casterClass = "PALADIN", casterSpecId = 65,
        spellId = 204018, buffDuration = 10,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {"Debuff"},
        talents = { {"player", 5692} },
    },
    {
        desc = "Holy Paladin — Blessing of Sacrifice (6940) cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "player", casterClass = "PALADIN", casterSpecId = 65,
        spellId = 6940, buffDuration = 12,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {},
    },
    {
        desc = "Prot Paladin — Ardent Defender (31850)",
        unit = "player", class = "PALADIN", specId = 66,
        spellId = 31850, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Prot Paladin — Guardian of Ancient Kings (86659)",
        unit = "player", class = "PALADIN", specId = 66,
        spellId = 86659, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = false,
        evidence = {},
    },
    {
        desc = "Prot Paladin — Sentinel (389539) [talent]",
        unit = "player", class = "PALADIN", specId = 66,
        spellId = 389539, buffDuration = 20,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 389539} },
    },
    {
        desc = "Ret Paladin — Avenging Wrath (31884)",
        unit = "player", class = "PALADIN", specId = 70,
        spellId = 31884, buffDuration = 24,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Ret Paladin — Divine Shield (642)",
        unit = "player", class = "PALADIN", specId = 70,
        spellId = 642, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {"Debuff", "UnitFlags"},
    },
    {
        desc = "Ret Paladin — Divine Protection (403876, requires Shield evidence)",
        unit = "player", class = "PALADIN", specId = 70,
        spellId = 403876, buffDuration = 8,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {"Shield"},
    },

    -- MAGE
    {
        desc = "Fire Mage — Combustion (190319)",
        unit = "player", class = "MAGE", specId = 63,
        spellId = 190319, buffDuration = 10,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Arcane Mage — Arcane Surge (365350)",
        unit = "player", class = "MAGE", specId = 62,
        spellId = 365350, buffDuration = 15,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Mage (class) — Ice Block (45438)",
        unit = "player", class = "MAGE", specId = nil,
        spellId = 45438, buffDuration = 10,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {"Debuff", "UnitFlags"},
    },
    {
        desc = "Mage (class) — Alter Time (342246)",
        unit = "player", class = "MAGE", specId = nil,
        spellId = 342246, buffDuration = 10,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- WARRIOR
    {
        desc = "Arms Warrior — Die by the Sword (118038)",
        unit = "player", class = "WARRIOR", specId = 71,
        spellId = 118038, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Arms Warrior — Avatar (107574) [talent]",
        unit = "player", class = "WARRIOR", specId = 71,
        spellId = 107574, buffDuration = 20,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 107574} },
    },
    {
        desc = "Prot Warrior — Shield Wall (871)",
        unit = "player", class = "WARRIOR", specId = 73,
        spellId = 871, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Fury Warrior — Enraged Regeneration (184364) [talent]",
        unit = "player", class = "WARRIOR", specId = 72,
        spellId = 184364, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 184364} },
    },

    -- DEATH KNIGHT
    {
        desc = "Blood DK — Vampiric Blood (55233)",
        unit = "player", class = "DEATHKNIGHT", specId = 250,
        spellId = 55233, buffDuration = 10,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Frost DK — Pillar of Frost (51271)",
        unit = "player", class = "DEATHKNIGHT", specId = 251,
        spellId = 51271, buffDuration = 12,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "DK (class) — Anti-Magic Shell (48707)",
        unit = "player", class = "DEATHKNIGHT", specId = nil,
        spellId = 48707, buffDuration = 5,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {"Shield"},
    },
    {
        desc = "DK (class) — Icebound Fortitude (48792)",
        unit = "player", class = "DEATHKNIGHT", specId = nil,
        spellId = 48792, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- PRIEST
    {
        desc = "Disc Priest — Pain Suppression (33206) cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "priest1", casterClass = "PRIEST", casterSpecId = 256,
        spellId = 33206, buffDuration = 8,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {},
    },
    {
        desc = "Holy Priest — Guardian Spirit (47788) cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "priest1", casterClass = "PRIEST", casterSpecId = 257,
        spellId = 47788, buffDuration = 10,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {},
    },
    {
        desc = "Holy Priest — Divine Hymn (64843)",
        unit = "player", class = "PRIEST", specId = 257,
        spellId = 64843, buffDuration = 5,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Shadow Priest — Dispersion (47585)",
        unit = "player", class = "PRIEST", specId = 258,
        spellId = 47585, buffDuration = 6,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Shadow Priest — Voidform (228260)",
        unit = "player", class = "PRIEST", specId = 258,
        spellId = 228260, buffDuration = 20,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Priest (class) — Desperate Prayer (19236)",
        unit = "player", class = "PRIEST", specId = nil,
        spellId = 19236, buffDuration = 10,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- DRUID
    {
        desc = "Balance Druid — Incarnation: Chosen of Elune (102560)",
        unit = "player", class = "DRUID", specId = 102,
        spellId = 102560, buffDuration = 20,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Feral Druid — Berserk (106951) [talent]",
        unit = "player", class = "DRUID", specId = 103,
        spellId = 106951, buffDuration = 15,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 106951} },
    },
    {
        desc = "Guardian Druid — Incarnation: Guardian of Ursoc (102558)",
        unit = "player", class = "DRUID", specId = 104,
        spellId = 102558, buffDuration = 30,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Resto Druid — Ironbark (102342) cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "druid1", casterClass = "DRUID", casterSpecId = 105,
        spellId = 102342, buffDuration = 12,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {},
    },
    {
        desc = "Druid (class) — Barkskin (22812)",
        unit = "player", class = "DRUID", specId = nil,
        spellId = 22812, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- MONK
    {
        desc = "Brewmaster Monk — Fortifying Brew (115203)",
        unit = "player", class = "MONK", specId = 268,
        spellId = 115203, buffDuration = 15,
        auraIsDefensive = true, isExternal = false, isImportant = false,
        evidence = {},
    },
    {
        desc = "Brewmaster Monk — Invoke Niuzao (132578)",
        unit = "player", class = "MONK", specId = 268,
        spellId = 132578, buffDuration = 25,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Mistweaver Monk — Life Cocoon (116849) cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "monk1", casterClass = "MONK", casterSpecId = 270,
        spellId = 116849, buffDuration = 12,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {},
    },
    {
        desc = "Monk (class) — Fortifying Brew (115203)",
        unit = "player", class = "MONK", specId = nil,
        spellId = 115203, buffDuration = 15,
        auraIsDefensive = true, isExternal = false, isImportant = false,
        evidence = {},
    },

    -- DEMON HUNTER
    {
        desc = "Havoc DH — Blur (198589)",
        unit = "player", class = "DEMONHUNTER", specId = 577,
        spellId = 198589, buffDuration = 10,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Vengeance DH — Metamorphosis (187827)",
        unit = "player", class = "DEMONHUNTER", specId = 581,
        spellId = 187827, buffDuration = 15,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Vengeance DH — Fiery Brand (204021)",
        unit = "player", class = "DEMONHUNTER", specId = 581,
        spellId = 204021, buffDuration = 12,
        auraIsDefensive = true, isExternal = false, isImportant = false,
        evidence = {},
    },

    -- HUNTER
    {
        desc = "MM Hunter — Trueshot (288613)",
        unit = "player", class = "HUNTER", specId = 254,
        spellId = 288613, buffDuration = 15,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Hunter (class) — Aspect of the Turtle (186265)",
        -- UnitFlags fires when the immunity is applied; unit is a Hunter so we
        -- prime feign-death state to false first to avoid suppression.
        unit = "player", class = "HUNTER", specId = nil,
        spellId = 186265, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {"UnitFlags"},
    },
    {
        desc = "Hunter (class) — Survival of the Fittest (264735)",
        unit = "player", class = "HUNTER", specId = nil,
        spellId = 264735, buffDuration = 6,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- ROGUE
    {
        desc = "Subtlety Rogue — Shadow Blades (121471)",
        unit = "player", class = "ROGUE", specId = 261,
        spellId = 121471, buffDuration = 16,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Rogue (class) — Evasion (5277)",
        unit = "player", class = "ROGUE", specId = nil,
        spellId = 5277, buffDuration = 10,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Rogue (class) — Cloak of Shadows (31224)",
        unit = "player", class = "ROGUE", specId = nil,
        spellId = 31224, buffDuration = 5,
        auraIsDefensive = true, isExternal = false, isImportant = false,
        evidence = {},
    },

    -- EVOKER
    {
        desc = "Devastation Evoker — Dragonrage (375087)",
        unit = "player", class = "EVOKER", specId = 1467,
        spellId = 375087, buffDuration = 18,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Preservation Evoker — Time Dilation (357170) cast on warrior",
        unit = "warrior1", class = "WARRIOR", specId = 73,
        caster = "evoker1", casterClass = "EVOKER", casterSpecId = 1468,
        spellId = 357170, buffDuration = 8,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {},
    },
    {
        desc = "Augmentation Evoker — Obsidian Scales (363916)",
        unit = "player", class = "EVOKER", specId = 1473,
        spellId = 363916, buffDuration = 13.4,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },
    {
        desc = "Evoker (class) — Obsidian Scales (363916)",
        unit = "player", class = "EVOKER", specId = nil,
        spellId = 363916, buffDuration = 12,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- SHAMAN
    {
        desc = "Resto Shaman — Ascendance (114052) [talent]",
        unit = "player", class = "SHAMAN", specId = 264,
        spellId = 114052, buffDuration = 15,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 114052} },
    },
    {
        desc = "Elemental Shaman — Ascendance (114050) [talent]",
        unit = "player", class = "SHAMAN", specId = 262,
        spellId = 114050, buffDuration = 15,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 114050} },
    },
    {
        desc = "Enhancement Shaman — Ascendance (114051) [talent]",
        unit = "player", class = "SHAMAN", specId = 263,
        spellId = 114051, buffDuration = 15,
        auraIsDefensive = false, isExternal = false, isImportant = true,
        evidence = {},
        talents = { {"player", 114051} },
    },
    {
        desc = "Shaman (class) — Astral Shift (108271)",
        unit = "player", class = "SHAMAN", specId = nil,
        spellId = 108271, buffDuration = 12,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- WARLOCK
    {
        desc = "Warlock (class) — Unending Resolve (104773)",
        unit = "player", class = "WARLOCK", specId = nil,
        spellId = 104773, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {},
    },

    -- Paladin (class)
    -- Divine Shield is also in ByClass for any-spec Paladin.
    {
        desc = "Paladin (class, no spec) — Divine Shield (642)",
        unit = "player", class = "PALADIN", specId = nil,
        spellId = 642, buffDuration = 8,
        auraIsDefensive = true, isExternal = false, isImportant = true,
        evidence = {"Debuff", "UnitFlags"},
    },
    {
        desc = "Paladin (class, no spec) — Blessing of Protection (1022)",
        unit = "warrior1", class = "WARRIOR", specId = nil,
        caster = "player", casterClass = "PALADIN", casterSpecId = nil,
        spellId = 1022, buffDuration = 10,
        auraIsDefensive = true, isExternal = true, isImportant = false,
        evidence = {"Debuff"},
    },
}

-- Test runner

fw.describe("Rule integration — prediction and cooldown commit", function()
    for _, tc in ipairs(cases) do
        fw.it(tc.desc, function()
            local err = runTest(tc)
            if err then error(err, 2) end
        end)
    end
end)
