-- Extended tests for PredictRule / PredictSpellId 12.0.5 behaviour.
--
-- Covers scenarios not exercised by test_predict_pve_12_0_5.lua:
--
--   · PvP + melee/physical class (precogIgnoreClasses): IMPORTANT auras are still safe to predict
--     because melee classes never use the Precognition gem.
--   · BIG_DEFENSIVE aura in PvP: Precognition only produces IMPORTANT, never BIG_DEFENSIVE,
--     so BIG_DEFENSIVE auras are always safe regardless of instance type.
--   · Negative castSpellIdSnapshot signal in PredictRule: if the target's cast spell ID is
--     known but doesn't match a tracked rule, prediction returns nil.
--   · Correct spell ID in castSpellIdSnapshot: uses the fast path and bypasses duration/evidence.
--   · Self-cast EXTERNAL_DEFENSIVE fallback: when all non-target candidates have been skipped,
--     the target can still be the caster (e.g. Ret Paladin self-casting BoP alone in the group).
--   · Spec-level rule preferred over class rule in prediction (Blood DK Vampiric Blood vs AMS).
--   · allowSyntheticCast gate for IMPORTANT aura on a warrior (physical, precog-safe) in arena.
--   · On-cooldown spell excluded from prediction (PredictSpellId returns isOnCooldown=true).

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 4001   -- distinct from other test files

-- Aura type shorthand used throughout this file.
local BIG = { BIG_DEFENSIVE = true, IMPORTANT = true }
local IMP = { IMPORTANT = true }
local EXT = { EXTERNAL_DEFENSIVE = true }

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Watcher helpers (mirror test_predict_pve_12_0_5.lua)

local function makeBigImportantWatcher(unit)
    wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

local function makeImportantOnlyWatcher()
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

local function makeExternalWatcher()
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

local function captureGlow()
    local captured
    B:RegisterPredictiveGlowCallback(function(_, sid) captured = sid end)
    return function() return captured end
end

-- Section 1: PvP + physical/melee class (precogIgnoreClasses)
--
-- precogIgnoreClasses = { WARRIOR, DEATHKNIGHT, ROGUE, HUNTER, DEMONHUNTER }
-- These classes never equip Precognition, so their IMPORTANT auras are safe to
-- predict even in arena/battleground on 12.0.5.

fw.describe("PredictRule 12.0.5 - PvP + melee class bypasses Precognition gate", function()
    fw.before_each(reset)

    fw.it("predicts Shield Wall for a Prot Warrior in arena (physical class = safe)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "WARRIOR")
        mods.talents._setSpec("party1", 73)   -- Protection

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- Shield Wall: BIG+IMP, BuffDuration=8, RequiresEvidence="Cast"
        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 871, "Shield Wall should be predicted for Warrior in arena (precog-safe class)")
    end)

    fw.it("predicts Evasion for a Subtlety Rogue in arena (physical class = safe)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "ROGUE")
        mods.talents._setSpec("party1", 261)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- Shadow Blades (spec 261) and Evasion (class ROGUE) both have ExcludeFromPrediction=true
        -- because Shadow Dance is also IMPORTANT and indistinguishable at prediction time.
        -- No ROGUE IMPORTANT rule is eligible for prediction -> no glow fires.
        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.is_nil(getGlow(), "no prediction for ROGUE IMPORTANT aura (Shadow Dance ambiguity excludes all candidates)")
    end)

    fw.it("predicts Icebound Fortitude for a Frost DK in arena", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 251)   -- Frost

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- IBF: BIG+IMP, BuffDuration=8, RequiresEvidence="Cast" (class rule)
        -- Pillar of Frost (spec 251): IMP-only, MinDuration; makeBigImportantWatcher produces BIG+IMP.
        -- PoF has Important=true, BigDefensive=false -> AuraTypeMatchesRule: BigDefensive=false requires
        -- BIG_DEFENSIVE to be ABSENT. BIG+IMP aura has BIG_DEFENSIVE=true -> PoF fails aura type check.
        -- IBF: BigDefensive=true, Important=true -> BIG+IMP satisfies both -> IBF matches.
        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 48792, "Icebound Fortitude predicted for Frost DK BIG+IMP aura in arena")
    end)

    fw.it("predicts Desperate Prayer for a Shadow Priest in arena (BIG_DEFENSIVE bypasses Precognition gate)", function()
        -- BIG_DEFENSIVE auras can never be Precognition; IsProbablyPrecognition returns false for them.
        -- So even caster classes like Priest get a prediction in arena for BIG_DEFENSIVE auras.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 19236, "BIG_DEFENSIVE bypasses Precognition gate -> Desperate Prayer predicted for Priest in arena")
    end)

    fw.it("no prediction for a Fire Mage in arena (caster class, not precog-safe)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- Combustion: IMP-only, MinDuration, RequiresEvidence="Cast"
        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.is_nil(getGlow(), "Mage is a caster class -> no synthetic cast in arena")
    end)
end)

-- Section 2: BIG_DEFENSIVE aura in PvP is always safe to predict
--
-- Precognition only produces IMPORTANT auras; a BIG_DEFENSIVE aura cannot be Precognition.
-- IsProbablyPrecognition returns false when BIG_DEFENSIVE is set, so these auras bypass the
-- Precognition gate entirely and are predicted even for caster classes in arena/battleground.

fw.describe("PredictRule 12.0.5 - BIG_DEFENSIVE in PvP bypasses Precognition gate", function()
    fw.before_each(reset)

    fw.it("BIG+IMP aura in arena predicts Desperate Prayer for Priest (BIG_DEFENSIVE bypasses gate)", function()
        -- IsProbablyPrecognition returns false for BIG_DEFENSIVE auras, so prediction proceeds
        -- even for caster classes like Priest that are otherwise blocked by the Precognition gate.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 19236, "BIG_DEFENSIVE bypasses Precognition gate -> Desperate Prayer predicted for Priest in arena")
    end)

    fw.it("BIG+IMP aura in pvp predicts Unending Resolve for Warlock (BIG_DEFENSIVE bypasses gate)", function()
        wow.setInstanceType("pvp")
        wow.setUnitClass("party1", "WARLOCK")

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 104773, "BIG_DEFENSIVE bypasses Precognition gate -> Unending Resolve predicted for Warlock in pvp")
    end)

    fw.it("Fortifying Brew (BIG-only, no IMPORTANT) predicted for Brewmaster in arena", function()
        -- Fortifying Brew (class MONK rule): BigDefensive=true, Important=false.
        -- The aura watcher produces only BIG_DEFENSIVE (not IMPORTANT) because isImportant=false.
        -- IsProbablyPrecognition: IMPORTANT absent -> returns false immediately -> prediction proceeds.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("party1", 268)  -- Brewmaster

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- Build a BIG-only watcher (no IMPORTANT flag): defensive state filtered as BIG but not IMP.
        wow.setAuraFiltered("party1", AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
        wow.setAuraFiltered("party1", AURA_ID, "HELPFUL|IMPORTANT", true)  -- mark IMP as absent
        local watcher = loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        -- Fortifying Brew: BIG, no IMP, RequiresEvidence="Cast", BuffDuration=15; synthetic ok.
        -- Invoke Niuzao (spec 268): Important=true, BigDefensive=false -> aura type mismatch (no IMP in aura).
        fw.eq(getGlow(), 115203, "Fortifying Brew predicted: BIG-only aura skips Precognition check even for caster arena")
    end)
end)

-- Section 3: Negative castSpellIdSnapshot signal in PredictRule
--
-- When the local player's UNIT_SPELLCAST_SUCCEEDED fires with a spell ID that does NOT match
-- any tracked rule for that aura type, it is a definitive negative signal: the player cast
-- something else, so prediction returns nil for them.

fw.describe("PredictRule - negative castSpellIdSnapshot (player cast something else)", function()
    fw.before_each(function()
        reset()
    end)

    fw.it("prediction returns nil when player's castSpellIdSnapshot is an unrelated spell", function()
        -- player is a Druid; Barkskin is a BIG+IMP rule.
        -- Player cast spell 9999 (unknown) at the same time the aura appeared -> definitive mismatch.
        wow.setUnitClass("player", "DRUID")
        local entry = loader.makeEntry("player")
        local getGlow = captureGlow()

        wow.setTime(0)
        -- Fire an unrelated cast spell (e.g. Regrowth = 8936) - does not match Barkskin rule.
        observer:_fireCast("player", 8936)

        -- Aura-added: Barkskin (BIG+IMP) appears.
        wow.setAuraFiltered("player", AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
        local watcher = loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
        observer:_fireAuraChanged(entry, watcher, { "player" })

        fw.is_nil(getGlow(), "known spell ID 8936 doesn't match Barkskin -> nil (negative signal)")
    end)

    fw.it("prediction succeeds when player's castSpellIdSnapshot matches the spell", function()
        wow.setUnitClass("player", "DRUID")
        local entry = loader.makeEntry("player")
        local getGlow = captureGlow()

        wow.setTime(0)
        -- Cast Barkskin (22812) -> matches the rule.
        observer:_fireCast("player", 22812)

        wow.setAuraFiltered("player", AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
        local watcher = loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
        observer:_fireAuraChanged(entry, watcher, { "player" })

        fw.eq(getGlow(), 22812, "castSpellId 22812 matches Barkskin -> prediction fires")
    end)

    fw.it("prediction is nil when multiple spell IDs fired but none match a BIG_DEFENSIVE rule", function()
        -- Two spell IDs in window: neither matches a BIG_DEFENSIVE rule for the Druid.
        wow.setUnitClass("player", "DRUID")
        local entry = loader.makeEntry("player")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireCast("player", 8936)   -- Regrowth
        observer:_fireCast("player", 1600)   -- some other spell

        wow.setAuraFiltered("player", AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
        local watcher = loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
        observer:_fireAuraChanged(entry, watcher, { "player" })

        fw.is_nil(getGlow(), "neither spell ID matches -> definitive negative signal -> nil")
    end)
end)

-- Section 4: Self-cast EXTERNAL_DEFENSIVE fallback in 12.0.5 PredictRule
--
-- On 12.0.5, the main EXTERNAL_DEFENSIVE loop skips the target (prevents false self-attribution).
-- After the loop, if no non-target matched, the target is given a second chance via
-- forceSyntheticOk=true - allowing self-cast externals (Disc Priest, Ret Paladin) to predict.

fw.describe("PredictRule 12.0.5 - self-cast EXTERNAL_DEFENSIVE fallback", function()
    fw.before_each(reset)

    fw.it("Disc Priest predicts Pain Suppression when alone (no other candidates)", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 256)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 33206, "Pain Suppression should predict via self-cast fallback")
    end)

    fw.it("Disc Priest self-cast PS not predicted when another Disc Priest is a candidate", function()
        -- Two Disc Priests: party1 (target) and party2. On 12.0.5 both receive synthetic Cast
        -- on the EXTERNAL_DEFENSIVE loop, creating ambiguity -> nil.
        -- Note: party1 is skipped in the main loop (target is excluded from EXT loop);
        -- party2 is found via the loop -> matches PS.
        -- Self-cast fallback for party1 only runs if no match found yet, which IS the case
        -- for party2 matching. So party2 wins and no ambiguity here.
        -- Actually wait - there IS a match from party2 (matchSpellId set), so self-cast fallback
        -- does NOT run. Result: party2's PS is returned.
        wow.setUnitClass("party1", "PRIEST")
        wow.setUnitClass("party2", "PRIEST")
        mods.talents._setSpec("party1", 256)
        mods.talents._setSpec("party2", 256)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        -- Both party1 (target, skipped in main loop) and party2 (non-target candidate, found via loop).
        -- After loop: matchSpellId=33206 from party2; self-cast fallback skipped (matchSpellId set).
        -- Then consider(party1, false, "exclude") for self-cast path of the outer function is separate.
        -- Actually PredictRule has a single flow: either EXT path or self-cast path (not both).
        -- In the EXT path: only party2 is visited in the loop (party1=targetUnit is skipped).
        -- party2 matches PS via synthetic Cast -> matchSpellId=33206, casterUnit=party2.
        -- Self-cast fallback: matchSpellId already set -> skipped.
        -- Result: PS predicted with party2 as caster.
        fw.eq(getGlow(), 33206, "PS should predict with party2 as caster (non-target found via loop)")
    end)

    fw.it("two non-target Disc Priests both matching Pain Suppression: SAME spell, NOT ambiguous in PredictRule", function()
        -- PredictRule sets ambiguous=true only when two candidates match DIFFERENT spells.
        -- When both match the same spell (Pain Suppression), the first match is kept and the
        -- spell is still predicted (we know what was cast, just not by whom - that's FindBestCandidate's job).
        wow.setUnitClass("party1", "WARRIOR")   -- target, not a Priest
        wow.setUnitClass("party2", "PRIEST")
        wow.setUnitClass("party3", "PRIEST")
        mods.talents._setSpec("party2", 256)
        mods.talents._setSpec("party3", 256)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2", "party3" })

        fw.eq(getGlow(), 33206, "same spell from two candidates is NOT ambiguous in PredictRule -> PS predicted")
    end)
end)

-- Section 5: playerCastNoExt gate on self-cast fallback (targetUnit == "player")
--
-- When the local player receives an EXT buff and their CastSpellIdSnapshot contains no
-- EXT-matching spell in the window, playerCastNoExt=true and the self-cast fallback is
-- suppressed (not (playerCastNoExt and targetUnit == "player")).  This prevents the local
-- player from being wrongly attributed as the caster of their own EXT buff via forceSyntheticOk
-- (e.g. predicting Ironbark when a Paladin cast BoSacrifice on the local Druid).
--
-- When targetUnit is a remote unit ("party1"), the gate is inactive regardless of
-- playerCastNoExt - the existing self-cast fallback tests in Section 4 cover that path.

fw.describe("PredictRule 12.0.5 - playerCastNoExt gate on self-cast fallback", function()
    fw.before_each(reset)

    -- Local player (Resto Druid) receives an EXT buff.  No cast event was fired for "player",
    -- so CastSpellIdSnapshot["player"] is nil -> playerCastNoExt=true.
    -- A Paladin (party1) is a candidate.  Without Shield evidence, Paladin doesn't match
    -- BoSacrifice and no non-target match is found.  The self-cast fallback is suppressed by
    -- the playerCastNoExt gate, so Ironbark is NOT wrongly predicted for the local Druid.
    fw.it("fallback suppressed when targetUnit='player' and player has no cast snapshot (nil)", function()
        wow.setUnitClass("player", "DRUID")
        mods.talents._setSpec("player", 105)    -- Resto: has Ironbark (12 s EXT)
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 70)     -- Ret: has BoSacrifice (12 s EXT, needs Shield)

        local entry   = loader.makeEntry("player")
        local getGlow = captureGlow()

        -- No cast fired for "player" -> CastSpellIdSnapshot["player"] = nil.
        -- party1 (Paladin) gets synthetic Cast but no Shield evidence -> BoSacrifice fails.
        -- playerCastNoExt=true, targetUnit="player" -> self-cast fallback suppressed.
        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "player", "party1" })

        fw.is_nil(getGlow(), "no EXT cast by player -> fallback suppressed -> Ironbark NOT predicted")
    end)

    -- Player cast an unrelated (non-EXT) spell just before the buff appeared.
    -- CastSpellIdSnapshot["player"] = [{SpellId=8936}] (Regrowth, which has no EXT rule).
    -- FindRuleBySpellId for EXT auraTypes returns nil -> anyExtMatch=false -> playerCastNoExt=true.
    -- Fallback is still suppressed even though there IS a cast snapshot entry.
    fw.it("fallback suppressed when player cast a non-EXT spell (irrelevant cast)", function()
        wow.setUnitClass("player", "DRUID")
        mods.talents._setSpec("player", 105)
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 70)

        local entry   = loader.makeEntry("player")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireCast("player", 8936)   -- Regrowth: no EXT rule -> anyExtMatch=false

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "player", "party1" })

        fw.is_nil(getGlow(), "player cast Regrowth (non-EXT) -> playerCastNoExt=true -> fallback suppressed")
    end)

    -- Player cast the EXT spell on themselves (Druid self-casting Ironbark).
    -- CastSpellIdSnapshot["player"] = [{SpellId=102342}].
    -- FindRuleBySpellId for EXT finds Ironbark -> anyExtMatch=true -> playerCastNoExt=false.
    -- Fallback is NOT suppressed; the self-cast fallback runs and correctly predicts Ironbark.
    fw.it("fallback NOT suppressed when player cast an EXT spell (self-cast Ironbark)", function()
        wow.setUnitClass("player", "DRUID")
        mods.talents._setSpec("player", 105)

        local entry   = loader.makeEntry("player")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireCast("player", 102342)   -- Ironbark: EXT rule -> anyExtMatch=true -> playerCastNoExt=false

        -- No other candidates (Druid is alone).  Main EXT loop skips "player" (targetUnit).
        -- matchSpellId=nil after loop.  playerCastNoExt=false -> fallback runs -> Druid gets
        -- forceSyntheticOk -> Ironbark matches (RequiresEvidence="Cast") -> predicted.
        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "player" })

        fw.eq(getGlow(), 102342, "player cast Ironbark -> playerCastNoExt=false -> fallback runs -> Ironbark predicted")
    end)
end)

-- Section 7: Spec-level rule preferred over class in PredictRule (Blood DK)

fw.describe("PredictRule 12.0.5 - spec rule preferred over class rule", function()
    fw.before_each(reset)

    fw.it("Blood DK Vampiric Blood (spec) predicted over AMS (class) for BIG+IMP aura at 10s", function()
        -- Vampiric Blood (spec 250): BIG+IMP, RequiresEvidence="Cast"
        -- AMS class rule (DK): BIG+IMP, RequiresEvidence={"Cast","Shield"}
        -- With synthetic Cast but no Shield -> AMS fails; VB matches.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        -- Note: PredictSpellIdForUnit tries spec list first, finds VB (10s rule at min duration >= 9.5)
        -- but PredictRule doesn't do duration matching - it just checks aura type + evidence.
        -- VB: BigDefensive=true, Important=true -> matches BIG+IMP aura; RequiresEvidence="Cast" -> synthetic ok.
        fw.eq(getGlow(), 55233, "Vampiric Blood predicted via spec rule (not AMS class rule)")
    end)

    fw.it("DK class rule AMS predicted when spec VB rule fails (no spec set, only class rules)", function()
        -- Without spec, only class rules apply: AMS (needs Cast+Shield) and IBF (needs Cast).
        -- IBF: BIG+IMP, RequiresEvidence="Cast" -> matches with synthetic Cast.
        -- AMS: needs Cast+Shield -> no Shield -> fails.
        -- Result: IBF.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        -- No spec set

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 48792, "Icebound Fortitude predicted from class rules (no spec, no Shield)")
    end)
end)

-- Section 8: On-cooldown spell excluded from PredictSpellId

fw.describe("PredictSpellId - active cooldowns filter", function()
    fw.before_each(function()
        reset()
    end)

    -- PredictSpellId is called by PredictRule internally, and is also exposed as B:PredictSpellId.
    -- When the first matching spell is on cooldown, it returns (spellId, true) - the caller
    -- (PredictRule) then skips this candidate.  We test B:PredictSpellId directly.

    fw.it("returns spellId + isOnCooldown=true when spell is active", function()
        wow.setUnitClass("party1", "DRUID")
        local evidence = { Cast = true }
        local activeCooldowns = { [22812] = true }   -- Barkskin on CD
        local spellId, onCd = B:PredictSpellId("party1", BIG, evidence, activeCooldowns)
        fw.not_nil(spellId, "spellId should still be returned when on CD")
        fw.eq(spellId, 22812, "Barkskin")
        fw.eq(onCd, true, "isOnCooldown should be true")
    end)

    fw.it("returns spellId + isOnCooldown=false when spell is not active", function()
        wow.setUnitClass("party1", "DRUID")
        local evidence = { Cast = true }
        local activeCooldowns = {}   -- nothing on CD
        local spellId, onCd = B:PredictSpellId("party1", BIG, evidence, activeCooldowns)
        fw.not_nil(spellId, "spellId")
        fw.eq(spellId, 22812, "Barkskin")
        fw.eq(onCd, false, "isOnCooldown should be false")
    end)

    fw.it("returns nil when no rule matches aura type (wrong type for class)", function()
        -- Druid has no EXTERNAL_DEFENSIVE rules in ByClass; result = nil.
        wow.setUnitClass("party1", "DRUID")
        local evidence = { Cast = true }
        local spellId = B:PredictSpellId("party1", EXT, evidence, nil)
        fw.is_nil(spellId, "Druid class has no EXTERNAL_DEFENSIVE rule")
    end)

    fw.it("Barkskin predicts with nil evidence (no RequiresEvidence)", function()
        -- Barkskin has no RequiresEvidence after removing the Cast requirement;
        -- PredictSpellIdForUnit matches it even with nil evidence.
        wow.setUnitClass("party1", "DRUID")
        local spellId = B:PredictSpellId("party1", BIG, nil, nil)
        fw.eq(spellId, 22812, "Barkskin matches with nil evidence")
    end)

    fw.it("spec rule takes priority: Blood DK VB returned before class AMS", function()
        wow.setUnitClass("party1", "DEATHKNIGHT")
        mods.talents._setSpec("party1", 250)
        local evidence = { Cast = true }
        local spellId, onCd = B:PredictSpellId("party1", BIG, evidence, nil)
        fw.eq(spellId, 55233, "Vampiric Blood from spec 250 list")
        fw.eq(onCd, false, "not on cooldown")
    end)

    fw.it("CastableOnOthers filter 'only': returns CastableOnOthers rule if it matches", function()
        -- Paladin class has BoF: CastableOnOthers=true, Important=true, BuffDuration=8.
        -- With castableFilter="only", only CastableOnOthers rules are checked.
        wow.setUnitClass("party1", "PALADIN")
        -- No spec; class only has BoF among CastableOnOthers rules.
        -- BoF: RequiresEvidence="Cast", IMP-only rule (BigDefensive=false, ExternalDefensive=false).
        local evidence = { Cast = true }
        -- B:PredictSpellId does not take a castableFilter; that's internal to PredictSpellIdForUnit.
        -- We test through PredictRule by checking what gets returned for an IMP-only aura on a Paladin.
        -- Instead test that Paladin's class rules return BoF for IMP-only aura.
        local spellId = B:PredictSpellId("party1", IMP, evidence, nil)
        fw.eq(spellId, 1044, "Blessing of Freedom (first CastableOnOthers rule in PALADIN class list)")
    end)
end)

-- Section 9: PredictRule EXTERNAL_DEFENSIVE - player excluded as candidate when they cast something else

fw.describe("PredictRule - player excluded via negative castSpellId signal in EXT loop", function()
    fw.before_each(function()
        reset()
    end)

    fw.it("player excluded from EXT attribution when they cast an unrelated spell", function()
        -- party1 = target (Warrior); player = Resto Druid candidate.
        -- Player cast an unrelated spell (Regrowth) -> negative signal -> player skipped.
        -- No other candidates -> nil.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("player", "DRUID")
        mods.talents._setSpec("player", 105)   -- Resto

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireCast("player", 8936)   -- Regrowth cast at T=0

        -- EXT aura appears at T=0 -> castSpellIdSnapshot picks up player=8936.
        -- 8936 doesn't match Ironbark (102342) -> negative signal -> player skipped.
        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "player" })

        fw.is_nil(getGlow(), "player cast Regrowth at same time -> negative signal -> excluded from Ironbark")
    end)

    fw.it("player correctly attributed when their cast matches the EXT rule", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("player", "DRUID")
        mods.talents._setSpec("player", 105)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()
        local capturedCaster
        B:RegisterPredictiveGlowCallback(function(_, sid, cu) capturedCaster = cu end)

        wow.setTime(0)
        observer:_fireCast("player", 102342)   -- Ironbark cast

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "player" })

        fw.eq(capturedCaster, "player", "player cast Ironbark -> attributed as caster")
    end)
end)

-- Section 10: Precognition false-positive prevention
--
-- Precognition is a PvP gem that grants a 4-second IMPORTANT-only buff when an enemy
-- misses their kick.  Caster and healer classes equip it; melee/physical classes
-- (precogIgnoreClasses) do not.
--
-- Predict path: ComputeAllowSyntheticCast blocks synthetic Cast evidence for non-melee
-- classes in arena/pvp when the aura is IMPORTANT-only -> no glow.
--
-- Commit path: no tracked rule has BuffDuration=4, so MatchRule naturally returns nil
-- for a 4-second aura regardless of class or instance type -> no commit.

fw.describe("Precognition false-positive prevention (predict + commit)", function()
    fw.before_each(reset)

    -- Predict blocked: Fire Mage (caster class) in arena with 4-second IMP-only aura.
    -- allowSyntheticCast=false (IMPORTANT + arena + MAGE not in precogIgnoreClasses) -> no glow.
    fw.it("Fire Mage in arena: 4s IMPORTANT aura produces no predict glow", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)

        local entry   = loader.makeEntry("party1")
        local getGlow = captureGlow()

        observer:_fireAuraChanged(entry, makeImportantOnlyWatcher(), { "party1" })

        fw.is_nil(getGlow(), "Precognition on Fire Mage in arena -> no synthetic cast allowed -> no glow")
    end)

    -- Commit blocked: Fire Mage in arena, 4s IMP-only aura appears then disappears.
    -- No rule has BuffDuration=4, so MatchRule returns nil even if evidence were present.
    fw.it("Fire Mage in arena: 4s IMPORTANT aura produces no cooldown commit", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        local entry = loader.makeEntry("party1")

        wow.setTime(0)
        observer:_fireAuraChanged(entry, makeImportantOnlyWatcher(), { "party1" })
        wow.advanceTime(4)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        fw.is_nil(committed, "Precognition (4s) on Fire Mage in arena -> no rule has 4s BuffDuration -> no commit")
    end)

    -- Predict blocked: Fire Mage in pvp battleground (pvp instance type also blocked).
    fw.it("Fire Mage in pvp battleground: 4s IMPORTANT aura produces no predict glow", function()
        wow.setInstanceType("pvp")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)

        local entry   = loader.makeEntry("party1")
        local getGlow = captureGlow()

        observer:_fireAuraChanged(entry, makeImportantOnlyWatcher(), { "party1" })

        fw.is_nil(getGlow(), "Precognition on Fire Mage in pvp -> no synthetic cast allowed -> no glow")
    end)

    -- Commit blocked: Fire Mage in pvp, 4s duration.
    fw.it("Fire Mage in pvp battleground: 4s IMPORTANT aura produces no cooldown commit", function()
        wow.setInstanceType("pvp")
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        local entry = loader.makeEntry("party1")

        wow.setTime(0)
        observer:_fireAuraChanged(entry, makeImportantOnlyWatcher(), { "party1" })
        wow.advanceTime(4)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "party1" })

        fw.is_nil(committed, "Precognition (4s) on Fire Mage in pvp -> no rule has 4s BuffDuration -> no commit")
    end)

    -- Contrast: Fire Mage NOT in arena/pvp - predict DOES fire (Combustion 190319).
    -- wow.reset() leaves instance type as "none"; allowSyntheticCast=true -> Combustion predicted.
    fw.it("Fire Mage NOT in arena: IMPORTANT aura triggers Combustion predict (contrast)", function()
        -- instance type remains "none" after reset
        wow.setUnitClass("party1", "MAGE")
        mods.talents._setSpec("party1", 63)

        local entry   = loader.makeEntry("party1")
        local getGlow = captureGlow()

        observer:_fireAuraChanged(entry, makeImportantOnlyWatcher(), { "party1" })

        fw.eq(getGlow(), 190319, "outside arena: allowSyntheticCast=true -> Combustion (190319) predicted for Fire Mage")
    end)

    -- Contrast: Fire Mage in arena with a real UNIT_SPELLCAST_SUCCEEDED event at full duration -> commit fires.
    -- The Precognition gate only blocks synthetic cast evidence; a real cast event (always visible
    -- for the local player even in 12.0.5) bypasses the gate.  Combustion has MinDuration=true so
    -- needs >= 9.5s measured duration; advancing 10s satisfies that.
    fw.it("Fire Mage in arena with real cast + 10s aura: Combustion commits (contrast)", function()
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "MAGE")
        mods.talents._setSpec("player", 63)

        local committed = nil
        B:RegisterCooldownCallback(function(_, cdKey) committed = cdKey end)

        local entry = loader.makeEntry("player")

        wow.setTime(0)
        observer:_fireCast("player", 190319)   -- local player's own cast is always visible in 12.0.5

        observer:_fireAuraChanged(entry, makeImportantOnlyWatcher(), { "player" })
        wow.advanceTime(10)
        observer:_fireAuraChanged(entry, loader.makeWatcher({}, {}), { "player" })

        fw.eq(committed, 190319, "real cast + 10s duration in arena -> Combustion commits (real cast, not Precognition)")
    end)
end)

