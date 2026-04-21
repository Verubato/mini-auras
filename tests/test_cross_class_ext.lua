-- Cross-class EXTERNAL_DEFENSIVE collision and disambiguation tests.
-- All tests use 12.0.5 mode (simulateNoCastSucceeded=true).
--
-- On 12.0.5, every non-local candidate receives synthetic Cast evidence, so any two
-- different-class candidates whose EXT rules share the same BuffDuration can become
-- ambiguous.  These tests verify disambiguation via evidence type, active cooldowns
-- (predict path only), real cast snapshots, and SelfCastable constraints.
--
-- Spell constants:
--   Ironbark         102342  Resto Druid (spec 105), 12s EXT, RequiresEvidence="Cast"
--   Blessing of Sacrifice  6940  Holy Paladin (spec 65), 12s EXT, RequiresEvidence={"Cast","Shield"}, SelfCastable=false
--   Guardian Spirit   47788  Holy Priest (spec 257), 10s EXT (base), RequiresEvidence="Cast"
--   Blessing of Protection  1022  Paladin specs, 10s EXT, RequiresEvidence={"Cast","Debuff","UnitFlags"}
--   Blessing of Spellwarding  204018  Paladin specs (talent 5692), 10s EXT, RequiresEvidence={"Cast","Debuff","UnitFlags"}, CastSpellId=1022
--   Pain Suppression  33206  Disc Priest (spec 256), 8s EXT, RequiresEvidence="Cast", MaxCharges=2
--   Time Dilation    357170  Preservation Evoker (spec 1468), 8s EXT, RequiresEvidence="Cast", MaxCharges=2
--
-- Note on CD-based disambiguation in the commit path:
--   MatchRule returns on-CD rules as a "fallback" (rather than nil) so that attribution
--   still fires when the tracker thinks a spell is on CD but it was just used.  In 12.0.5
--   cross-class scenarios this fallback can cause false ambiguity at commit time when both
--   classes match different SpellIds (e.g. Ironbark fallback + BoS both seen -> ambiguous).
--   Evidence-type discrimination (absent Shield / absent Debuff) is reliable for commit.
--   CD-based disambiguation is therefore tested on the predict path only, where PredictRule
--   explicitly skips on-CD candidates.

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 4001  -- distinct from all other test files

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

local function makeExtWatcher()
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

local function makeEmptyWatcher()
    return loader.makeWatcher({}, {})
end

local function captureGlow()
    local captured
    B:RegisterPredictiveGlowCallback(function(_, sid) captured = sid end)
    return function() return captured end
end

local function captureCommit()
    local captured
    B:RegisterCooldownCallback(function(_, cdKey) captured = cdKey end)
    return function() return captured end
end

local function fireShield(unit)
    observer:_fireShield(unit)
end

local function fireDebuff(unit)
    observer:_fireDebuffEvidence(unit, {
        addedAuras             = { { auraInstanceID = 9999 } },
        updatedAuraInstanceIDs = {},
    })
    observer:_fireUnitFlags(unit)
end

-- Spell ID constants
local IRONBARK_ID        = 102342
local BOS_ID             = 6940
local GS_ID              = 47788
local BOP_ID             = 1022
local BOSP_ID            = 204018
local PS_ID              = 33206
local TIME_DILATION_ID   = 357170
local SPELLWARDING_TALENT = 5692

-- ---------------------------------------------------------------------------
-- Section 1: Ironbark (Resto Druid, 12s, Cast) vs Blessing of Sacrifice (Holy Paladin, 12s, Cast+Shield)
--
-- Without Shield evidence: BoS (Cast+Shield) fails -> only Ironbark (Cast only) matches.
-- With Shield evidence: both match -> ambiguous.
-- CD-based predict disambiguation: on-CD candidate skipped by PredictRule.
-- ---------------------------------------------------------------------------

fw.describe("Cross-class EXT: Ironbark vs Blessing of Sacrifice", function()
    fw.before_each(function()
        reset()
        -- party1 = Warrior (target), party2 = Holy Paladin, party3 = Resto Druid.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "DRUID")
        wow.setUnitClass("player",  "WARRIOR")
        mods.talents._setSpec("party2", 65)   -- Holy Paladin -> Blessing of Sacrifice
        mods.talents._setSpec("party3", 105)  -- Resto Druid  -> Ironbark
    end)

    -- Evidence discrimination: absent Shield eliminates BoS, leaving only Ironbark.

    fw.it("no Shield evidence -> Ironbark predicted unambiguously (BoS needs Shield)", function()
        local getGlow = captureGlow()
        wow.setTime(0)
        -- No _fireShield: BoS (Cast+Shield) cannot match -> only Ironbark (Cast only) remains.
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "party3" })
        fw.eq(getGlow(), IRONBARK_ID, "Ironbark should predict when Shield evidence is absent")
    end)

    fw.it("no Shield evidence -> Ironbark committed unambiguously", function()
        local getCommit = captureCommit()
        wow.setTime(0)
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "party3" })
        wow.advanceTime(12)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "party2", "party3" })
        fw.eq(getCommit(), IRONBARK_ID, "Ironbark should commit when Shield evidence is absent")
    end)

    fw.it("Shield evidence -> ambiguous: no prediction, no commit", function()
        local getGlow   = captureGlow()
        local getCommit = captureCommit()
        wow.setTime(0)
        fireShield("party1")
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "party3" })
        fw.is_nil(getGlow(), "predict should be nil: Ironbark (Cast) + BoS (Cast+Shield) both match")
        wow.advanceTime(12)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "party2", "party3" })
        fw.is_nil(getCommit(), "commit should be nil: different SpellIds -> ambiguous")
    end)

    -- CD-based predict disambiguation (predict path only; see note at top of file).

    fw.it("Shield + Ironbark on CD -> BoS predicted (Druid skipped by PredictRule)", function()
        -- Ironbark on CD for party3: PredictRule's consider() returns early for on-CD candidates.
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party3" then return { [IRONBARK_ID] = { MaxCharges = 1, UsedCharges = { 1 } } } end
        end)
        local getGlow = captureGlow()
        wow.setTime(0)
        fireShield("party1")
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "party2", "party3" })
        fw.eq(getGlow(), BOS_ID, "BoS should predict when Ironbark is on cooldown for the Druid")
    end)

    fw.it("Shield + BoS on CD -> Ironbark predicted (Paladin skipped by PredictRule)", function()
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party2" then return { [BOS_ID] = { MaxCharges = 1, UsedCharges = { 1 } } } end
        end)
        local getGlow = captureGlow()
        wow.setTime(0)
        fireShield("party1")
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "party2", "party3" })
        fw.eq(getGlow(), IRONBARK_ID, "Ironbark should predict when BoS is on cooldown for the Paladin")
    end)
end)

-- ---------------------------------------------------------------------------
-- Section 2: Guardian Spirit (Holy Priest, 10s, Cast) vs Blessing of Protection (Paladin, 10s, Cast+Debuff+UnitFlags)
--
-- Without Debuff+UnitFlags evidence: BoP fails -> only Guardian Spirit (Cast only) matches.
-- With Debuff+UnitFlags evidence: both match -> ambiguous.
-- CD-based predict: GS on CD -> BoP predicted.
-- ---------------------------------------------------------------------------

fw.describe("Cross-class EXT: Guardian Spirit vs Blessing of Protection", function()
    fw.before_each(function()
        reset()
        -- party1 = Warrior (target), party2 = Holy Paladin (BoP), party3 = Holy Priest (GS).
        -- Neither has ExcludeIfTalent active: party2 has no Spellwarding talent (5692),
        -- party3 has no Foreseen Circumstances talent (440738) -> Guardian Spirit is base 10s.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "PRIEST")
        wow.setUnitClass("player",  "WARRIOR")
        mods.talents._setSpec("party2", 65)   -- Holy Paladin -> Blessing of Protection
        mods.talents._setSpec("party3", 257)  -- Holy Priest  -> Guardian Spirit (base 10s)
    end)

    fw.it("no Debuff evidence -> Guardian Spirit predicted unambiguously (BoP needs Debuff)", function()
        local getGlow = captureGlow()
        wow.setTime(0)
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "party3" })
        fw.eq(getGlow(), GS_ID, "Guardian Spirit should predict when Debuff evidence is absent")
    end)

    fw.it("no Debuff evidence -> Guardian Spirit committed unambiguously", function()
        local getCommit = captureCommit()
        wow.setTime(0)
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "party3" })
        wow.advanceTime(10)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "party2", "party3" })
        fw.eq(getCommit(), GS_ID, "Guardian Spirit should commit when Debuff evidence is absent")
    end)

    fw.it("Debuff evidence -> ambiguous: no prediction, no commit", function()
        local getGlow   = captureGlow()
        local getCommit = captureCommit()
        wow.setTime(0)
        fireDebuff("party1")
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "party3" })
        fw.is_nil(getGlow(), "predict nil: GS (Cast) + BoP (Cast+Debuff+UnitFlags) both match")
        wow.advanceTime(10)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "party2", "party3" })
        fw.is_nil(getCommit(), "commit nil: different SpellIds -> ambiguous")
    end)

    fw.it("Debuff + Guardian Spirit on CD -> BoP predicted (Priest skipped by PredictRule)", function()
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party3" then return { [GS_ID] = { MaxCharges = 1, UsedCharges = { 1 } } } end
        end)
        local getGlow = captureGlow()
        wow.setTime(0)
        fireDebuff("party1")
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "party2", "party3" })
        fw.eq(getGlow(), BOP_ID, "BoP should predict when Guardian Spirit is on cooldown for the Priest")
    end)
end)

-- ---------------------------------------------------------------------------
-- Section 3: Pain Suppression (Disc Priest, 8s, Cast) vs Time Dilation (Preservation Evoker, 8s, Cast)
--
-- Both require only Cast evidence with no distinguishing evidence type.  On 12.0.5 both always
-- match -> always ambiguous when both candidates are present.  Only CD-based predict disambiguation
-- can resolve the case.
-- ---------------------------------------------------------------------------

fw.describe("Cross-class EXT: Pain Suppression vs Time Dilation", function()
    fw.before_each(function()
        reset()
        -- party1 = Warrior (target), party2 = Disc Priest (PS), party3 = Preservation Evoker (TD).
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PRIEST")
        wow.setUnitClass("party3", "EVOKER")
        wow.setUnitClass("player",  "WARRIOR")
        mods.talents._setSpec("party2", 256)   -- Discipline Priest -> Pain Suppression
        mods.talents._setSpec("party3", 1468)  -- Preservation Evoker -> Time Dilation
    end)

    fw.it("both present -> always ambiguous (no evidence type discriminates)", function()
        -- Both PS (Cast only) and Time Dilation (Cast only) match on 12.0.5.
        -- There is no Shield or Debuff requirement to use as a tiebreaker.
        local getGlow   = captureGlow()
        local getCommit = captureCommit()
        wow.setTime(0)
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "party3" })
        fw.is_nil(getGlow(), "predict nil: PS and Time Dilation both match -> ambiguous")
        wow.advanceTime(8)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "party2", "party3" })
        fw.is_nil(getCommit(), "commit nil: different SpellIds -> ambiguous")
    end)

    fw.it("Pain Suppression on CD -> Time Dilation predicted", function()
        -- PS has MaxCharges=2; use both charges to mark it fully on CD.
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party2" then return { [PS_ID] = { MaxCharges = 2, UsedCharges = { 1, 2 } } } end
        end)
        local getGlow = captureGlow()
        wow.setTime(0)
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "party2", "party3" })
        fw.eq(getGlow(), TIME_DILATION_ID, "Time Dilation should predict when Pain Suppression is fully on cooldown")
    end)

    fw.it("Time Dilation on CD -> Pain Suppression predicted", function()
        -- Time Dilation has MaxCharges=2; use both.
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party3" then return { [TIME_DILATION_ID] = { MaxCharges = 2, UsedCharges = { 1, 2 } } } end
        end)
        local getGlow = captureGlow()
        wow.setTime(0)
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "party2", "party3" })
        fw.eq(getGlow(), PS_ID, "Pain Suppression should predict when Time Dilation is fully on cooldown")
    end)
end)

-- ---------------------------------------------------------------------------
-- Section 4: Blessing of Spellwarding CastSpellId pipeline
--
-- When a Prot Paladin with Spellwarding talented casts BoP (spellId=1022),
-- UNIT_SPELLCAST_SUCCEEDED fires with 1022.  FindRuleBySpellId resolves this via
-- CastSpellId=1022 on the BoSpellwarding rule and attributes 204018, not 1022.
-- ---------------------------------------------------------------------------

fw.describe("Cross-class EXT: Blessing of Spellwarding CastSpellId pipeline", function()
    fw.before_each(function()
        reset()
        -- Local player = Prot Paladin with Spellwarding talented; party1 = Warrior (target).
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("player",  "PALADIN")
        mods.talents._setSpec("player", 66)                    -- Protection Paladin
        mods.talents._setTalent("player", SPELLWARDING_TALENT, true)  -- Blessing of Spellwarding unlocked
    end)

    fw.it("player casts BoP (1022) -> BoSpellwarding (204018) predicted, not BoP", function()
        -- Spellwarding ExcludeIfTalent blocks BoP(1022); CastSpellId=1022 on BoSpellwarding
        -- makes FindRuleBySpellId return 204018 for the cast event.
        -- BoSpellwarding also requires Debuff+UnitFlags (Forbearance + immunity applied to target).
        local getGlow = captureGlow()
        wow.setTime(0)
        observer:_fireCast("player", BOP_ID)          -- UNIT_SPELLCAST_SUCCEEDED with BoP spellId
        fireDebuff("party1")                           -- Forbearance applied to target
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "player" })
        fw.eq(getGlow(), BOSP_ID, "BoSpellwarding (204018) should be predicted when Spellwarding is talented")
    end)

    fw.it("player casts BoP (1022) -> BoSpellwarding (204018) committed, not BoP", function()
        local getCommit = captureCommit()
        wow.setTime(0)
        observer:_fireCast("player", BOP_ID)
        fireDebuff("party1")
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "player" })
        wow.advanceTime(10)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "player" })
        fw.eq(getCommit(), BOSP_ID, "BoSpellwarding (204018) should be committed when Spellwarding is talented")
    end)
end)

-- ---------------------------------------------------------------------------
-- Section 5: Local player casts Ironbark -> playerCastNoExt=false suppresses synthetic BoS
--
-- When the local player (Resto Druid) fires a cast event for Ironbark, playerCastNoExt
-- becomes false and the syntheticOk guard blocks synthetic Cast for the Paladin candidate.
-- Even with Shield evidence present (which would normally allow BoS to match), the Paladin
-- receives no synthetic Cast -> BoS fails -> only Ironbark matches -> unambiguous.
-- At commit time, the real cast tiebreaker (player's castTime vs Paladin's nil bestTime) also
-- resolves in Ironbark's favour independently of the syntheticOk suppression.
-- ---------------------------------------------------------------------------

fw.describe("Cross-class EXT: player cast suppresses synthetic BoS for Paladin", function()
    fw.before_each(function()
        reset()
        -- player = Resto Druid, party1 = Warrior (target), party2 = Holy Paladin.
        -- Shield evidence is present (would make BoS matchable if Paladin had synthetic Cast).
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("player",  "DRUID")
        mods.talents._setSpec("party2", 65)   -- Holy Paladin -> BoS
        mods.talents._setSpec("player", 105)  -- Resto Druid  -> Ironbark
    end)

    fw.it("player casts Ironbark -> predicted unambiguously despite Shield evidence", function()
        -- With Shield evidence alone and no cast: both Ironbark and BoS would match -> ambiguous.
        -- With player's real Ironbark cast: playerCastNoExt=false -> Paladin's syntheticOk=false
        -- -> BoS fails -> only Ironbark predicted.
        local getGlow = captureGlow()
        wow.setTime(0)
        observer:_fireCast("player", IRONBARK_ID)
        fireShield("party1")
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "party2", "player" })
        fw.eq(getGlow(), IRONBARK_ID, "Ironbark should predict: player cast suppresses synthetic BoS for Paladin")
    end)

    fw.it("player casts Ironbark -> committed unambiguously via real cast tiebreaker", function()
        -- At commit time: player's real castTime wins over Paladin's synthetic nil bestTime.
        local getCommit = captureCommit()
        wow.setTime(0)
        observer:_fireCast("player", IRONBARK_ID)
        fireShield("party1")
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2", "player" })
        wow.advanceTime(12)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "party2", "player" })
        fw.eq(getCommit(), IRONBARK_ID, "Ironbark should commit: real cast timestamp beats Paladin's synthetic evidence")
    end)
end)

-- ---------------------------------------------------------------------------
-- Section 6: Paladin as both target and candidate (SelfCastable=false)
--
-- Blessing of Sacrifice has SelfCastable=false: a Paladin cannot be attributed as
-- self-casting BoS onto themselves.  When the target IS a Paladin, the self-cast
-- fallback in both PredictRule and FindBestCandidate is blocked for the target -> the
-- non-target Paladin candidate wins cleanly without ambiguity.
-- ---------------------------------------------------------------------------

fw.describe("Cross-class EXT: Paladin target blocked from self-attributing BoS (SelfCastable=false)", function()
    fw.before_each(function()
        reset()
        -- party1 = Holy Paladin (target of BoS), party2 = Holy Paladin (non-target candidate).
        -- Both have the same spec so both would match BoS if not for SelfCastable=false on party1.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("player",  "WARRIOR")
        mods.talents._setSpec("party1", 65)
        mods.talents._setSpec("party2", 65)
    end)

    fw.it("BoS predicted to non-target Paladin: target's self-cast fallback blocked", function()
        -- party2 matches BoS via synthetic Cast+Shield (matchSpellId=6940, matchCastDiff=nil).
        -- Self-cast fallback runs (matchCastDiff=nil) but party1's SelfCastable=false -> blocked.
        -- matchSpellId stays 6940, no ambiguity -> predict fires.
        local getGlow = captureGlow()
        wow.setTime(0)
        fireShield("party1")
        observer:_fireAuraChanged(loader.makeEntry("party1"), makeExtWatcher(), { "party1", "party2" })
        fw.eq(getGlow(), BOS_ID, "BoS predicted to party2: target Paladin cannot self-attribute (SelfCastable=false)")
    end)

    fw.it("BoS committed to non-target Paladin: target's self-cast fallback blocked", function()
        local getCommit = captureCommit()
        wow.setTime(0)
        fireShield("party1")
        local entry = loader.makeEntry("party1")
        observer:_fireAuraChanged(entry, makeExtWatcher(), { "party1", "party2" })
        wow.advanceTime(12)
        observer:_fireAuraChanged(entry, makeEmptyWatcher(), { "party1", "party2" })
        fw.eq(getCommit(), BOS_ID, "BoS committed to party2: target Paladin cannot self-attribute (SelfCastable=false)")
    end)
end)
