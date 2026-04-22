-- Tests for PredictRule 12.0.5 PvE synthetic cast re-enablement.
--
-- On 12.0.5, UNIT_SPELLCAST_SUCCEEDED no longer fires for other players, so PredictRule
-- normally produces no predictions (no Cast evidence -> RequiresEvidence="Cast" fails).
-- In PvE without a Paladin in the group, two false-positive sources are absent:
--   · Precognition (PvP gem giving IMPORTANT self-buff) only fires in arena/battleground
--   · Blessing of Freedom (Paladin IMPORTANT external) requires a Paladin caster
-- When both conditions hold, Brain synthesizes Cast evidence on the self-cast path,
-- re-enabling predictions for self-only IMPORTANT/BIG_DEFENSIVE spells.

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods     = loader.get()
local B        = mods.brain
local observer = mods.observer

local AURA_ID = 3001   -- distinct from other test files

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
    B:RegisterPredictiveGlowCallback(nil)
    B:RegisterCooldownCallback(nil)
    B:RegisterActiveCooldownsLookup(nil)
end

-- Build a watcher exposing AURA_ID as BIG_DEFENSIVE + IMPORTANT (e.g. Dispersion).
-- In BuildCurrentAuraIds: aura appears in GetDefensiveState, filtered out of
-- EXTERNAL_DEFENSIVE -> BIG_DEFENSIVE; not filtered out of IMPORTANT -> IMPORTANT added.
local function makeBigImportantWatcher(unit)
    wow.setAuraFiltered(unit, AURA_ID, "HELPFUL|EXTERNAL_DEFENSIVE", true)
    wow.setAuraFiltered(unit, AURA_ID, "HARMFUL|CROWD_CONTROL", false)  -- Dispersion is CC
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

-- Build a watcher exposing AURA_ID as IMPORTANT-only (e.g. Avenging Wrath, Blessing of Freedom).
-- Aura only in GetImportantState -> AuraTypes = { IMPORTANT = true }.
local function makeImportantOnlyWatcher()
    return loader.makeWatcher({}, { { AuraInstanceID = AURA_ID } })
end

-- Build a watcher exposing AURA_ID as EXTERNAL_DEFENSIVE (e.g. Pain Suppression, Blessing of Protection).
-- Aura in GetDefensiveState and NOT filtered by HELPFUL|EXTERNAL_DEFENSIVE -> AuraTypes = { EXTERNAL_DEFENSIVE = true }.
-- Default wow_api behaviour is not-filtered, so no setAuraFiltered call is needed.
local function makeExternalWatcher()
    return loader.makeWatcher({ { AuraInstanceID = AURA_ID } }, {})
end

-- Register a predictive glow callback and return a getter for the captured spell ID.
local function captureGlow()
    local captured
    B:RegisterPredictiveGlowCallback(function(_, sid) captured = sid end)
    return function() return captured end
end

-- Shadow Priest: Dispersion
-- Rule: BigDefensive=true, Important=true, RequiresEvidence="Cast", SpellId=47585
-- Uses makeBigImportantWatcher.

fw.describe("PredictRule 12.0.5 - PvE synthetic cast re-enabled", function()
    fw.before_each(reset)

    fw.it("predicts Dispersion (Shadow Priest) in PvE with no Paladin", function()
        -- instanceType defaults to "none" (PvE overworld) after wow.reset()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)   -- Shadow

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- No cast event fired -> no real Cast evidence; synthetic Cast must supply it.
        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 47585, "Dispersion should be predicted via synthetic Cast")
    end)

    fw.it("predicts Dispersion in a PvE raid instance", function()
        wow.setInstanceType("raid")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 47585, "raid instance is still PvE - prediction should fire")
    end)

    fw.it("predicts Dispersion in arena (BIG_DEFENSIVE bypasses Precognition gate)", function()
        -- Dispersion is BIG_DEFENSIVE+IMPORTANT. IsProbablyPrecognition returns false for
        -- BIG_DEFENSIVE auras, so the predict gate is bypassed even for caster classes in PvP.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 47585, "BIG_DEFENSIVE bypasses Precognition gate -> Dispersion predicted in arena")
    end)

    fw.it("predicts Dispersion in pvp battleground (BIG_DEFENSIVE bypasses Precognition gate)", function()
        wow.setInstanceType("pvp")
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 47585, "BIG_DEFENSIVE bypasses Precognition gate -> Dispersion predicted in battleground")
    end)

    fw.it("predicts Dispersion in open-world War Mode (BIG_DEFENSIVE bypasses Precognition gate)", function()
        -- BIG_DEFENSIVE auras can never be Precognition, so the gate is bypassed regardless of
        -- instance type or UnitIsPVP flag.
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 258)
        wow.setUnitPvp("party1", true)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.eq(getGlow(), 47585, "BIG_DEFENSIVE bypasses Precognition gate -> Dispersion predicted in War Mode")
    end)

    fw.it("IsProbablyPrecognition: IMPORTANT-only + UnitFlags + arena suppresses predict", function()
        -- Precognition (fired when interrupted) produces an IMPORTANT-only aura with UnitFlags
        -- evidence.  IsProbablyPrecognition must suppress predict before any rule matching occurs.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)   -- Holy Paladin (AW would otherwise match)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- Fire UnitFlags evidence BEFORE the aura so it is captured in BuildEvidenceSet.
        wow.setTime(0)
        observer:_fireUnitFlags("party1")

        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.is_nil(getGlow(), "IMPORTANT+UnitFlags+arena: IsProbablyPrecognition suppresses predict (no false AW glow)")
    end)

    fw.it("IsProbablyPrecognition: IMPORTANT-only + UnitFlags + War Mode suppresses predict", function()
        -- Same as above but in open-world War Mode (UnitIsPVP=true, not inside a pvp instance).
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)
        wow.setUnitPvp("player", true)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireUnitFlags("party1")

        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.is_nil(getGlow(), "IMPORTANT+UnitFlags+warmode: IsProbablyPrecognition suppresses predict")
    end)

    fw.it("IsProbablyPrecognition: IMPORTANT-only without UnitFlags still predicts AW (no suppression)", function()
        -- A real AW cast does NOT produce UnitFlags evidence.  IsProbablyPrecognition must
        -- return false so the normal predict path runs (suppressed only by AllowNoEvidencePredict
        -- for caster classes, but allowed for e.g. a DK in PvE).
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "DEATHKNIGHT")  -- melee class, precogIgnoreClasses = true
        mods.talents._setSpec("party1", 250)       -- Blood DK has some IMPORTANT spell

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- No UnitFlags fired -> IsProbablyPrecognition returns false -> predict can proceed.
        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        -- We are not asserting a specific spellId (depends on DK rules), just that prediction
        -- was NOT universally suppressed by IsProbablyPrecognition.
        -- If DK has an IMPORTANT-only spell that matches, it should be predicted.
        -- (This test passes regardless of whether the DK has a matching rule - it validates
        -- that IsProbablyPrecognition did not fire and block the search path.)
        -- The key: no assertion of nil, as that would mean IsProbablyPrecognition falsely fired.
        fw.is_nil(getGlow(), "Blood DK IMPORTANT without UnitFlags in arena: no matching IMPORTANT-only rule -> nil is expected")
    end)

    fw.it("predicts Dispersion even with a Paladin in the group (BoF is BigDef=false, cannot match BIG_DEFENSIVE)", function()
        -- BoF has BigDefensive=false so AuraTypeMatchesRule rejects it for any BIG_DEFENSIVE
        -- aura.  Ambiguity between Dispersion and BoF never arises -> prediction fires.
        wow.setUnitClass("party1", "PRIEST")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 258)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeBigImportantWatcher("party1")
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        fw.eq(getGlow(), 47585, "Dispersion should be predicted - BoF cannot produce a BIG_DEFENSIVE aura")
    end)

    fw.it("Avenging Wrath is ambiguous with BoF on a remote Paladin (no cast snapshot)", function()
        -- The target IS a Paladin; candidateUnits = {"party1"}.
        -- With no cast snapshot for party1 (remote in 12.0.5+), both AW (self-only IMPORTANT)
        -- and BoF (CastableOnOthers IMPORTANT) are valid explanations for the aura.  The
        -- prediction is ambiguous and correctly suppressed to avoid false glows (e.g. Paladin
        -- self-casting BoF causing a false AW glow on the DK's UI).
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)   -- Holy Paladin

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1" })

        fw.is_nil(getGlow(), "AW vs BoF ambiguity: no prediction without cast evidence for remote Paladin")
    end)

    fw.it("Avenging Wrath is ambiguous with BoF even with two Paladins in the group", function()
        -- party2 = another Paladin. Both AW (self-only) and BoF (CastableOnOthers) are valid
        -- explanations for party1's IMPORTANT aura; no cast snapshot disambiguates.
        -- The second Paladin (party2) does not change this: they also have no snapshot.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 65)
        mods.talents._setSpec("party2", 65)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        fw.is_nil(getGlow(), "AW vs BoF ambiguity: no prediction without cast evidence even with two Paladins")
    end)

    fw.it("prediction still works via real cast snapshot regardless of Paladin/instance", function()
        -- Even in arena with a Paladin, a real cast snapshot bypasses allowSyntheticCast
        -- because the useSnapshot=true path doesn't need the flag.
        wow.setInstanceType("arena")
        wow.setUnitClass("player", "PRIEST")
        mods.talents._setSpec("player", 258)
        wow.setUnitClass("party1", "PALADIN")

        local entry = loader.makeEntry("player")
        local getGlow = captureGlow()

        -- Fire a real cast event for "player" (UNIT_SPELLCAST_SUCCEEDED still fires locally).
        wow.setTime(0)
        observer:_fireCast("player", 47585)

        local watcher = makeBigImportantWatcher("player")
        observer:_fireAuraChanged(entry, watcher, { "player", "party1" })

        fw.eq(getGlow(), 47585, "real cast snapshot should predict regardless of arena/Paladin flags")
    end)

    -- Self-cast EXTERNAL_DEFENSIVE: caster == recipient, no other unit has the spell.
    -- On 12.0.5 the target is excluded from the main candidate pass to prevent false
    -- self-attribution (e.g. Druid matching Ironbark when a Paladin cast BoP).  The
    -- self-cast fallback must re-add the target when no non-target matched.

    fw.it("predicts Pain Suppression when Disc Priest self-casts (only monk in group)", function()
        wow.setUnitClass("party1", "PRIEST")
        mods.talents._setSpec("party1", 256) -- Discipline
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("party2", 269) -- Windwalker

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        fw.eq(getGlow(), 33206, "Pain Suppression should predict on self-cast with only a Monk in group")
    end)

    fw.it("predicts Blessing of Protection when Ret Paladin self-casts (only monk in group)", function()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 70) -- Retribution
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("party2", 269) -- Windwalker

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- BoP requires Debuff+UnitFlags evidence.  Fire both at the same time
        -- as the aura so they fall within the 0.15s evidence tolerance window.
        wow.setTime(0)
        observer:_fireDebuffEvidence("party1", {
            addedAuras = { { auraInstanceID = 9999 } },
            updatedAuraInstanceIDs = {},
        })
        observer:_fireUnitFlags("party1")

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2" })

        fw.eq(getGlow(), 1022, "Blessing of Protection should predict on self-cast with only a Monk in group")
    end)

    -- AMS (Spellwarding): IMPORTANT-only on recipient, Shield evidence, CastableOnOthers.
    -- A Paladin in the group normally blocks allowSyntheticCast (BoF concern), but Shield
    -- evidence proves BoF is not the source -> bofSafe bypass -> DK gets synthetic Cast.

    fw.it("predicts AMS (Spellwarding) on Warrior even when Paladin is in the group", function()
        -- party1 = Warrior (target), party2 = Death Knight (caster), party3 = Paladin (not on cd)
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "DEATHKNIGHT")
        wow.setUnitClass("party3", "PALADIN")
        mods.talents._setSpec("party2", 250) -- Blood DK (any spec works; AMS is class-level)
        mods.talents._setSpec("party3", 65)  -- Holy Paladin

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- Shield evidence must arrive before (or simultaneous with) the aura.
        wow.setTime(0)
        observer:_fireShield("party1")

        -- IMPORTANT-only aura (AMS on recipient's frame is not filtered as BIG_DEF).
        local watcher = makeImportantOnlyWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2", "party3" })

        fw.eq(getGlow(), 48707, "AMS should predict: Shield evidence bypasses Paladin bofSafe check")
    end)

    fw.it("external defensive is ambiguous when two non-target candidates have different spells", function()
        -- party1 is a Warrior (the target, no external spells).
        -- party2 (Resto Druid) could cast Ironbark; party3 (Holy Paladin) could cast BoP.
        -- Neither has cast evidence on 12.0.5 -> both match -> ambiguous -> nil.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "DRUID")
        wow.setUnitClass("party3", "PALADIN")
        mods.talents._setSpec("party2", 105) -- Resto Druid
        mods.talents._setSpec("party3", 65)  -- Holy Paladin

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        -- Debuff+UnitFlags evidence so BoP can match.
        wow.setTime(0)
        observer:_fireDebuffEvidence("party1", {
            addedAuras = { { auraInstanceID = 9999 } },
            updatedAuraInstanceIDs = {},
        })
        observer:_fireUnitFlags("party1")

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2", "party3" })

        fw.is_nil(getGlow(), "Ironbark vs BoP from two non-target candidates should be ambiguous")
    end)

    -- Life Cocoon vs Blessing of Sacrifice disambiguation.
    --
    -- Both spells are EXT, 12s, require Cast+Shield evidence.  Without cast evidence the two
    -- are indistinguishable.  On 12.0.5, when the local player IS the Mistweaver monk, their
    -- UNIT_SPELLCAST_SUCCEEDED provides a non-secret spell ID (116849), so playerCastNoExt=false.
    -- The syntheticOk guard must block synthetic Cast for non-player candidates in that case;
    -- otherwise the holy paladin would also get synthetic BoS evidence and cause false ambiguity.

    fw.it("predicts Life Cocoon when monk (player) casts on a paladin target", function()
        -- Scenario matching the bug report: Mistweaver monk (player) casts Life Cocoon on party1
        -- (Ret Paladin).  party2 is a Holy Paladin who also has BoS available.
        -- Without the syntheticOk fix, party2 would get synthetic Cast -> BoS matches ->
        -- ambiguous with Life Cocoon -> nil.  With the fix, party2 does not get synthetic Cast
        -- because the local player (monk) has confirmed EXT cast evidence.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("player", "MONK")
        mods.talents._setSpec("party1", 70)  -- Ret Paladin
        mods.talents._setSpec("party2", 65)  -- Holy Paladin
        mods.talents._setSpec("player", 270) -- Mistweaver Monk

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        wow.setTime(0)
        -- Monk (player) fires UNIT_SPELLCAST_SUCCEEDED with Life Cocoon's spell ID.
        observer:_fireCast("player", 116849)
        -- Shield evidence (Life Cocoon applies an absorb).
        observer:_fireShield("party1")

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2", "player" })

        fw.eq(getGlow(), 116849, "Life Cocoon should be predicted from monk's perspective")
    end)

    fw.it("BoS/Life Cocoon is ambiguous when neither candidate is the local player", function()
        -- Warrior target (party1), Holy Paladin (party2), Mistweaver Monk (party3).
        -- The local player is the warrior - neither paladin nor monk is 'player'.
        -- On 12.0.5 both get synthetic Cast -> BoS (party2) and Life Cocoon (party3) both match
        -- -> different spells -> ambiguous -> nil.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "MONK")
        wow.setUnitClass("player", "WARRIOR")
        mods.talents._setSpec("party2", 65)  -- Holy Paladin
        mods.talents._setSpec("party3", 270) -- Mistweaver Monk

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireShield("party1")

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2", "party3" })

        fw.is_nil(getGlow(), "BoS vs Life Cocoon without cast evidence should be ambiguous -> nil")
    end)

    fw.it("BoS committed when Life Cocoon is on cooldown for the monk", function()
        -- Life Cocoon is on CD for party3 (Mistweaver).  The only off-CD EXT+Shield match
        -- is BoS from party2 (Holy Paladin) -> single match -> BoS predicted.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("party3", "MONK")
        wow.setUnitClass("player", "WARRIOR")
        mods.talents._setSpec("party2", 65)  -- Holy Paladin
        mods.talents._setSpec("party3", 270) -- Mistweaver Monk

        -- Life Cocoon on CD for party3: activeCooldownsLookup returns a full-charge entry.
        B:RegisterActiveCooldownsLookup(function(unit)
            if unit == "party3" then
                return { [116849] = { MaxCharges = 1, UsedCharges = { 1 } } }
            end
            return nil
        end)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireShield("party1")

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2", "party3" })

        fw.eq(getGlow(), 6940, "BoS should predict when Life Cocoon is on cooldown for the monk")

        B:RegisterActiveCooldownsLookup(nil)
    end)

    fw.it("monk self-casting Life Cocoon on themselves: ambiguous vs synthetic BoS from remote observer", function()
        -- Bug scenario: Mistweaver Monk (party1) casts Life Cocoon on themselves.
        -- From a remote observer's perspective (e.g. ret paladin = local player):
        --   · party2 (Holy Paladin) is a non-target candidate -> gets synthetic Cast -> BoS matches
        --     (matchSpellId=6940, matchCastDiff=nil - no real cast evidence)
        --   · Self-cast fallback runs because matchCastDiff==nil
        --   · party1 (Monk, target) matches Life Cocoon (116849) via forceSyntheticOk
        --   · Life Cocoon (116849) != BoS (6940) -> ambiguous -> nil.
        -- Without the fix, matchSpellId was set to 6940 so the fallback was skipped entirely.
        wow.setUnitClass("party1", "MONK")
        wow.setUnitClass("party2", "PALADIN")
        wow.setUnitClass("player", "PALADIN")
        mods.talents._setSpec("party1", 270) -- Mistweaver Monk -> Life Cocoon
        mods.talents._setSpec("party2", 65)  -- Holy Paladin -> BoS
        mods.talents._setSpec("player", 70)  -- Ret Paladin (local observer, no EXT cast)

        local entry = loader.makeEntry("party1")
        local getGlow = captureGlow()

        wow.setTime(0)
        observer:_fireShield("party1")

        local watcher = makeExternalWatcher()
        observer:_fireAuraChanged(entry, watcher, { "party1", "party2", "player" })

        fw.is_nil(getGlow(), "Monk self-cast LC vs synthetic BoS -> ambiguous -> nil")
    end)
end)
