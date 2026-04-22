-- Unit tests for Brain:FindBestCandidate.
--
-- Covers all logical pathways in the function:
--   · No match (unknown class, wrong duration)
--   · Self-cast BIG_DEFENSIVE match
--   · Cast snapshot tiebreaking (most-recent wins)
--   · Cast snapshot outside window -> no Cast evidence -> rule fails
--   · Ambiguity: two external candidates, same rule, no tiebreaker -> nil
--   · bestIsTarget: target + external non-target, same rule -> non-target wins
--   · bestIsTarget + different rules (Ironbark/BoF bug fix) -> ambiguous -> nil
--   · BIG_DEFENSIVE on 12.0.5: candidate loop skipped -> no false ambiguity
--   · EXTERNAL_DEFENSIVE on 12.0.5: candidate loop still runs
--   · 12.0.5 synthetic cast for non-player; "player" gets no synthetic cast
--   · KnownSpellIds fast path bypasses duration check
--   · ActiveCooldowns: on-CD rule returned as fallback only
--   · IgnoreTalentRequirements passes RequiresTalent check
--
-- Rule constants used (from Rules.lua):
--   Barkskin     SpellId 22812   DRUID class, BigDefensive+Important, BuffDuration 8, RequiresEvidence="Cast"
--   Ironbark     SpellId 102342  Resto Druid spec 105, ExternalDefensive, BuffDuration 12, RequiresEvidence="Cast"
--   BoS          SpellId 6940    Holy Paladin spec 65, ExternalDefensive, BuffDuration 12, RequiresEvidence={"Cast","Shield"}
--   Av.Crusader  SpellId 216331  Holy Paladin spec 65, Important, BuffDuration 10, MinDuration, RequiresTalent=216331

local fw     = require("framework")
local wow    = require("wow_api")
local loader = require("loader")

local mods = loader.get()
local B    = mods.brain

-- Must match Brain.lua's castWindow constant (0.15 s).
local castWindow = 0.15

-- Aura-type sets that match specific rule flags.
local EXT = { EXTERNAL_DEFENSIVE = true }                       -- Ironbark, BoF
local BIG = { BIG_DEFENSIVE = true, IMPORTANT = true }          -- Barkskin
local IMP = { IMPORTANT = true }                                -- Avenging Crusader / Wrath, Dispersion

local function reset()
    B._TestReset()
    wow.reset()
    mods.talents._reset()
end

local function makeTracked(auraTypes, startTime, castSnapshot, evidence, castSpellIdSnapshot)
    return {
        StartTime           = startTime or 1.0,
        AuraTypes           = auraTypes,
        Evidence            = evidence,
        CastSnapshot        = castSnapshot or {},
        CastSpellIdSnapshot = castSpellIdSnapshot or {},
    }
end

-- Section 1: Basic matching and no-match cases

fw.describe("FindBestCandidate - no-match cases", function()
    fw.before_each(reset)

    fw.it("returns nil when the target unit has no class set", function()
        -- party1 has no UnitClass entry -> MatchRule returns nil immediately.
        -- (ruleUnit defaults to entry.Unit even on no-match; only rule matters.)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 })
        local rule = B:FindBestCandidate(entry, t, 8.0, {})
        fw.is_nil(rule, "rule")
    end)

    fw.it("returns nil when measured duration does not match any rule", function()
        -- Barkskin expects 8 s; 3 s is too short (tolerance is 0.5 s)
        wow.setUnitClass("party1", "DRUID")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 })
        local rule = B:FindBestCandidate(entry, t, 3.0, {})
        fw.is_nil(rule, "rule")
    end)
end)

-- Section 2: Self-cast BIG_DEFENSIVE (Barkskin)

fw.describe("FindBestCandidate - self-cast BIG_DEFENSIVE", function()
    fw.before_each(reset)

    fw.it("matches Barkskin when target is a Druid with cast snapshot", function()
        wow.setUnitClass("party1", "DRUID")
        local entry = loader.makeEntry("party1")
        -- CastSnapshot at StartTime -> within castWindow
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 })
        local rule, unit = B:FindBestCandidate(entry, t, 8.0, {})
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 22812, "SpellId should be Barkskin")
        fw.eq(unit, "party1", "ruleUnit")
    end)

    fw.it("ignores other candidates for BIG_DEFENSIVE when only target qualifies", function()
        -- party1 = Druid (Barkskin caster), party2 = Warrior (no Barkskin rule)
        -- candidateUnits includes party2 but it should not affect the outcome
        wow.setUnitClass("party1", "DRUID")
        wow.setUnitClass("party2", "WARRIOR")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 })
        local rule, unit = B:FindBestCandidate(entry, t, 8.0, { "party2" })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 22812, "SpellId")
        fw.eq(unit, "party1", "ruleUnit")
    end)
end)

-- Section 3: Cast snapshot tiebreaking
-- Ironbark (spec 105, EXTERNAL_DEFENSIVE, BuffDuration 12, RequiresEvidence="Cast")
-- party1 = Warrior (receives buff, cannot be the caster)
-- party2/party3 = Resto Druid (caster candidates)

fw.describe("FindBestCandidate - cast snapshot tiebreaking", function()
    fw.before_each(function()
        reset()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "DRUID")
        mods.talents._setSpec("party2", 105)   -- Restoration Druid
    end)

    fw.it("single external caster with snapshot wins", function()
        local t = makeTracked(EXT, 5.0, { party2 = 5.0 })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 102342, "Ironbark SpellId")
        fw.eq(unit, "party2", "ruleUnit")
    end)

    fw.it("prefers the candidate with a cast snapshot over one without", function()
        -- party3 has no snapshot (Ironbark requires Cast -> no match for party3)
        wow.setUnitClass("party3", "DRUID")
        mods.talents._setSpec("party3", 105)
        -- Only party2 has snapshot within window
        local t = makeTracked(EXT, 5.0, { party2 = 5.0 })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2", "party3" })
        fw.not_nil(rule, "rule")
        fw.eq(unit, "party2", "party2 has snapshot, party3 does not -> party2 wins")
    end)

    fw.it("picks the candidate with the most recent cast snapshot", function()
        -- party2: snapshot at 4.9 s (0.1 s before aura start - within window)
        -- party3: snapshot at 5.05 s (0.05 s after aura start - also within window, more recent)
        wow.setUnitClass("party3", "DRUID")
        mods.talents._setSpec("party3", 105)
        local t = makeTracked(EXT, 5.0, { party2 = 4.9, party3 = 5.05 })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2", "party3" })
        fw.not_nil(rule, "rule")
        fw.eq(unit, "party3", "party3 has the more recent snapshot")
    end)

end)

-- Section 4: Ambiguity and bestIsTarget

fw.describe("FindBestCandidate - ambiguity and bestIsTarget", function()
    fw.before_each(reset)

    fw.it("target (Druid) + non-target (Druid), same rule -> non-target with newer snapshot wins", function()
        -- party1 (target, Druid spec 105) has an older snapshot; party2 (non-target) has a newer one.
        -- The more-recent-snapshot path (isBetter condition 2) picks party2.
        wow.setUnitClass("party1", "DRUID")
        wow.setUnitClass("party2", "DRUID")
        mods.talents._setSpec("party1", 105)
        mods.talents._setSpec("party2", 105)
        local t = makeTracked(EXT, 5.0, { party1 = 4.9, party2 = 5.05 })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.not_nil(rule, "rule")
        fw.eq(unit, "party2", "party2 has newer snapshot -> wins")
    end)

    fw.it("non-target with newer snapshot wins over target (different rules, snapshot tiebreak)", function()
        -- party2 (Paladin->BoF) has a more recent snapshot than party1 (Druid->Ironbark),
        -- so BoF wins via snapshot recency tiebreaker (isBetter condition 2).
        wow.setUnitClass("party1", "DRUID")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 105)   -- Resto Druid -> Ironbark
        mods.talents._setSpec("party2", 65)    -- Holy Paladin -> BoF
        -- party2 has a more recent snapshot -> snapshot tiebreak (condition 2) picks party2
        local t = makeTracked(EXT, 5.0, { party1 = 4.9, party2 = 5.05 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(loader.makeEntry("party1"), t, 12.0, { "party2" })
        fw.not_nil(rule, "rule")
        fw.eq(rule.SpellId, 6940, "BoS SpellId - newer snapshot wins")
        fw.eq(unit, "party2", "ruleUnit")
    end)
end)

-- Section 5: 12.0.5 mode

fw.describe("FindBestCandidate - 12.0.5 synthetic cast", function()
    fw.before_each(function()
        reset()
    end)

    fw.it("BIG_DEFENSIVE: candidate loop skipped -> two Druids do not create ambiguity", function()
        -- Without the 12.0.5 guard, party2 would also receive synthetic cast and create
        -- a second Barkskin match -> ambiguous -> nil.  With the guard, only the target runs.
        wow.setUnitClass("party1", "DRUID")   -- target + caster
        wow.setUnitClass("party2", "DRUID")   -- second Druid; must NOT be considered
        local entry = loader.makeEntry("party1")
        local t = makeTracked(BIG, 1.0, {})   -- no real snapshots needed; synthetic cast applies
        local rule, unit = B:FindBestCandidate(entry, t, 8.0, { "party2" })
        fw.not_nil(rule, "Barkskin should match party1")
        fw.eq(rule.SpellId, 22812, "SpellId")
        fw.eq(unit, "party1", "ruleUnit should be party1 (candidate loop skipped)")
    end)

    fw.it("EXTERNAL_DEFENSIVE: candidate loop still runs on 12.0.5", function()
        -- isExternal=true so the BIG_DEFENSIVE guard does not apply; party2 is found.
        wow.setUnitClass("party1", "WARRIOR")   -- target, no Ironbark rule
        wow.setUnitClass("party2", "DRUID")
        mods.talents._setSpec("party2", 105)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, {})
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2" })
        fw.not_nil(rule, "Ironbark should be found via candidate loop")
        fw.eq(rule.SpellId, 102342, "SpellId")
        fw.eq(unit, "party2", "ruleUnit")
    end)

    fw.it("EXTERNAL_DEFENSIVE, two Resto Druids, same SpellId -> first candidate wins", function()
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "DRUID")
        wow.setUnitClass("party3", "DRUID")
        mods.talents._setSpec("party2", 105)
        mods.talents._setSpec("party3", 105)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, {})
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2", "party3" })
        -- Both Druids match Ironbark (same SpellId) with no cast tiebreaker.
        -- Same-SpellId: not ambiguous - first candidate (party2) wins.
        fw.not_nil(rule, "two matching Druids, same SpellId -> first candidate wins")
        fw.eq(rule.SpellId, 102342, "SpellId")
        fw.eq(unit, "party2", "ruleUnit")
    end)

    fw.it("bestIsTarget: target (Druid) + external Druid, same Ironbark rule -> non-target wins", function()
        -- party1 (target, Druid spec 105) matches Ironbark first -> bestIsTarget=true
        -- party2 (non-target, Druid spec 105) also matches Ironbark, same rule
        -- -> condition 3 (bestIsTarget=true, candidateRule==rule) fires -> party2 wins
        wow.setUnitClass("party1", "DRUID")
        wow.setUnitClass("party2", "DRUID")
        mods.talents._setSpec("party1", 105)
        mods.talents._setSpec("party2", 105)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, {})
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2" })
        fw.not_nil(rule, "Ironbark should match")
        fw.eq(rule.SpellId, 102342, "SpellId")
        fw.eq(unit, "party2", "non-target should win over target when same rule")
    end)

    fw.it("Ironbark vs BoSac: ambiguous when both candidates only have synthetic evidence", function()
        -- party1 (target, Druid spec 105) could self-match Ironbark
        -- party2 (Paladin spec 65) matches BoS via synthetic Cast (non-target, evaluated first)
        -- On 12.0.5+ bestTime==nil after the non-target loop, so the self-cast fallback runs.
        -- Ironbark (102342) != BoS (6940) -> ambiguous -> nil.
        wow.setUnitClass("party1", "DRUID")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 105)   -- Resto Druid -> Ironbark
        mods.talents._setSpec("party2", 65)    -- Holy Paladin -> BoS
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2" })
        fw.is_nil(rule, "ambiguous: Druid self-cast Ironbark vs Paladin synthetic BoS -> nil")
    end)

    fw.it("player unit does not get synthetic cast -> excluded when no snapshot", function()
        -- On 12.0.5, only non-"player" candidates get synthetic Cast.
        -- "player" has no snapshot -> RequiresEvidence="Cast" fails -> no match -> nil
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("player", "DRUID")
        mods.talents._setSpec("player", 105)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, {})   -- no snapshot for "player"
        local rule = B:FindBestCandidate(entry, t, 12.0, { "player" })
        fw.is_nil(rule, "player with no snapshot should not match on 12.0.5")
    end)

    fw.it("player unit with a cast snapshot matches normally", function()
        -- Real snapshot for "player" within window -> Cast evidence provided -> matches
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("player", "DRUID")
        mods.talents._setSpec("player", 105)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, { player = 5.0 })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "player" })
        fw.not_nil(rule, "player with snapshot should match")
        fw.eq(rule.SpellId, 102342, "Ironbark SpellId")
        fw.eq(unit, "player", "ruleUnit")
    end)
end)

-- Section 6: KnownSpellIds fast path

fw.describe("FindBestCandidate - KnownSpellIds fast path", function()
    fw.before_each(reset)

    fw.it("KnownSpellIds bypasses the duration check", function()
        -- Barkskin expects 8 s; we use 3 s which would normally fail the duration guard.
        -- A KnownSpellId for 22812 within castWindow lets FindRuleBySpellId return the rule directly.
        wow.setUnitClass("party1", "DRUID")
        local entry = loader.makeEntry("party1")
        local castSpellIdSnapshot = { party1 = { { SpellId = 22812, Time = 1.0 } } }
        local t = makeTracked(BIG, 1.0, {}, nil, castSpellIdSnapshot)
        local rule, unit = B:FindBestCandidate(entry, t, 3.0, {})
        fw.not_nil(rule, "KnownSpellIds should bypass duration check and return Barkskin")
        fw.eq(rule.SpellId, 22812, "SpellId")
        fw.eq(unit, "party1", "ruleUnit")
    end)

    fw.it("KnownSpellIds outside cast window falls through to normal duration matching", function()
        -- SpellId snapshot is 4 s old - outside the cast window -> not used as KnownSpellId
        -- Duration 3 s is too short for any Barkskin variant -> nil
        wow.setUnitClass("party1", "DRUID")
        local entry = loader.makeEntry("party1")
        local castSpellIdSnapshot = { party1 = { { SpellId = 22812, Time = -3.0 } } }
        -- StartTime=1.0, snapshot at -3.0 -> |−3.0 − 1.0| = 4.0 > 0.15 -> outside window
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 }, nil, castSpellIdSnapshot)
        -- Even though there's a CastSnapshot (to satisfy RequiresEvidence), the wrong duration
        -- without KnownSpellId should cause a mismatch.
        local rule = B:FindBestCandidate(entry, t, 3.0, {})
        fw.is_nil(rule, "duration mismatch without valid KnownSpellId should return nil")
    end)
end)

-- Section 7: ActiveCooldowns - fallback behaviour

fw.describe("FindBestCandidate - ActiveCooldowns fallback", function()
    fw.before_each(reset)

    fw.it("on-CD rule is returned as fallback when it is the only match", function()
        -- Barkskin (22812) is listed as active cooldown.
        -- MatchRule stores it as fallback (not nil) and returns it at the end if nothing else matches.
        wow.setUnitClass("party1", "DRUID")
        local entry = loader.makeEntry("party1", { [22812] = {} })   -- Barkskin on CD
        local t = makeTracked(BIG, 1.0, { party1 = 1.0 })
        local rule, unit = B:FindBestCandidate(entry, t, 8.0, {})
        fw.not_nil(rule, "on-CD rule should still be returned as fallback")
        fw.eq(rule.SpellId, 22812, "SpellId")
        fw.eq(unit, "party1", "ruleUnit")
    end)
end)

-- Section 8: AMS Spellwarding on ally (CastableOnOthers, 12.0.5)
-- AMS Spellwarding rules: BigDefensive=false, Important=true, CastableOnOthers=true,
-- SpellId=48707, CastSpellId=410358, RequiresEvidence={Cast,Shield}, BuffDuration=5 or 7.

fw.describe("FindBestCandidate - AMS Spellwarding on ally (12.0.5)", function()
    fw.before_each(function()
        reset()
    end)

    fw.it("DK candidate matches CastableOnOthers AMS on non-DK target via synthetic cast", function()
        -- The recipient (party1, Warrior) is not a DK -> target self-match fails.
        -- The caster (party2, DK) gets synthetic Cast + Shield from evidence -> rule matches.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "DEATHKNIGHT")
        local entry = loader.makeEntry("party1")
        -- IMP-only (as seen on the recipient's frame), Shield evidence, dur=6.01 (within 7+0.5 window)
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2" })
        fw.not_nil(rule, "AMS should match via DK candidate")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS")
        fw.eq(unit, "party2", "DK should be the attributed caster")
    end)

    fw.it("DK self-casting AMS: DK is the target, IMP-only aura, synthetic cast", function()
        -- The DK (party1) self-cast AMS via Spellwarding; no other DK in group.
        -- Target self-matches via synthetic cast -> rule returned with ruleUnit=party1.
        wow.setUnitClass("party1", "DEATHKNIGHT")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, {})
        fw.not_nil(rule, "AMS should match for DK self-casting")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS")
    end)

    fw.it("same player appearing as two unit IDs does not cause ambiguity", function()
        -- WoW can expose the same physical player as both "party1" and "raid2" simultaneously.
        -- Without GUID deduplication both receive synthetic Cast, both match AMS -> ambiguous.
        wow.setUnitClass("party1", "WARRIOR")   -- target
        wow.setUnitClass("party2", "DEATHKNIGHT")
        wow.setUnitClass("party3", "DEATHKNIGHT")
        -- party2 and party3 are the same player
        wow.setUnitGUID("party2", "Player-GUID-DK")
        wow.setUnitGUID("party3", "Player-GUID-DK")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2", "party3" })
        fw.not_nil(rule, "AMS should match - duplicate unit IDs deduped by GUID")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS")
    end)

    fw.it("DK + Paladin in group: AMS matches DK, Paladin does not get synthetic cast (BoF has no Shield req)", function()
        -- The presence of a Paladin previously caused ambiguity: both DK (AMS) and Paladin (BoF)
        -- received synthetic Cast, producing different spell IDs -> ambiguous -> nil.
        -- With the Shield-evidence guard, the Paladin is denied synthetic Cast -> only DK matches.
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("party2", "DEATHKNIGHT")
        wow.setUnitClass("party3", "PALADIN")
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 6.01, { "party2", "party3" })
        fw.not_nil(rule, "AMS should match despite Paladin in group")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS, not BoF")
        fw.eq(unit, "party2", "DK should be the attributed caster")
    end)

    fw.it("stale BoF CastSnapshot does not block AMS betterCOO attribution to DK (regression)", function()
        -- Regression: Paladin (player) cast BoF on the DK at T=1.0, then the DK cast AMS on the
        -- Paladin at T=5.0 (4 seconds later). CastSnapshot["player"] = 1.0 was stored when the
        -- aura was applied. Before the fix, BuildCandidateEvidence returned castTime=1.0 (stale),
        -- which set bestTime non-nil and blocked betterCOO from firing for the DK candidate.
        -- The Paladin's BoF (already on CD in ActiveCooldowns) was returned as a fallback instead.
        --
        -- Fix: castTime is only returned when within castWindow (0.15s) of StartTime; stale entries
        -- produce nil, leaving bestTime nil so betterCOO correctly fires for the DK.
        wow.setUnitClass("player",  "PALADIN")
        wow.setUnitClass("party1",  "DEATHKNIGHT")
        mods.talents._setSpec("player", 65)   -- Holy Paladin -> BoF available
        -- BoF is already on cooldown (Paladin cast it on the DK 4 seconds ago)
        local entry = loader.makeEntry("player", { [1044] = {} })
        -- StartTime=5.0; CastSnapshot["player"]=1.0 -> |1.0 - 5.0| = 4.0 > 0.15 -> stale
        local t = makeTracked(IMP, 5.0, { player = 1.0 }, { Shield = true })
        -- dur=7.0 matches the 7s AMS Spellwarding rule
        local rule, unit = B:FindBestCandidate(entry, t, 7.0, { "party1" })
        fw.not_nil(rule, "AMS should be attributed to the DK, not fall back to stale BoF")
        fw.eq(rule and rule.SpellId, 48707, "SpellId should be AMS (48707), not BoF (1044)")
        fw.eq(unit, "party1", "DK (party1) should win via betterCOO, not the Paladin with stale snapshot")
    end)
end)

-- Section 10: EXTERNAL_DEFENSIVE + Shield evidence
-- Blessing of Sacrifice (SpellId 6940, Holy Paladin spec 65):
--   BuffDuration=12, ExternalDefensive=true, RequiresEvidence="Cast".
-- Shield evidence is present (BoS redirects damage, triggering absorb events),
-- but BoS does not require Shield.  The Shield-evidence guard must NOT block
-- synthetic Cast for EXTERNAL_DEFENSIVE auras.

fw.describe("FindBestCandidate - EXTERNAL_DEFENSIVE with incidental Shield evidence", function()
    fw.before_each(function()
        reset()
    end)

    fw.it("Blessing of Sacrifice tracks even when Shield evidence is present", function()
        -- The Shield guard (which prevents BoF from matching AMS) must not apply to
        -- EXTERNAL_DEFENSIVE auras, where BoF cannot match anyway (ExternalDefensive=false).
        wow.setUnitClass("party1", "DEATHKNIGHT")  -- target
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)  -- Holy Paladin (has BoS at spec level)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 1.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 12.01, { "party2" })
        fw.not_nil(rule, "BoS should match despite Shield evidence on an EXTERNAL_DEFENSIVE aura")
        fw.eq(rule and rule.SpellId, 6940, "SpellId should be Blessing of Sacrifice")
        fw.eq(unit, "party2", "Paladin should be the attributed caster")
    end)
end)

-- Section 11: IgnoreTalentRequirements
-- Avenging Crusader (SpellId 216331, spec 65 Holy Paladin):
--   BuffDuration=10, MinDuration=true, RequiresTalent=216331, RequiresEvidence="Cast"
-- Avenging Wrath (SpellId 31884, spec 65 Holy Paladin):
--   BuffDuration=12, MinDuration=true, RequiresEvidence="Cast", ExcludeIfTalent=216331
-- measuredDuration=10: Avenging Wrath needs ≥ 11.5 s (fails); Crusader needs ≥ 9.5 s (passes if talent ok).

fw.describe("FindBestCandidate - IgnoreTalentRequirements", function()
    fw.before_each(function()
        reset()
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)   -- Holy Paladin
    end)

    fw.it("without IgnoreTalentRequirements: RequiresTalent rule skipped -> nil", function()
        -- No talent set -> Avenging Crusader (RequiresTalent=216331) is skipped
        -- Avenging Wrath needs ≥ 11.5 s but we measured 10 -> also fails
        -- -> nil
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, { party1 = 1.0 })
        local rule = B:FindBestCandidate(entry, t, 10.0, {})
        fw.is_nil(rule, "RequiresTalent should block the rule without the talent")
    end)

    fw.it("with IgnoreTalentRequirements=true: RequiresTalent check skipped -> rule matches", function()
        -- Same setup; opts.IgnoreTalentRequirements=true skips the RequiresTalent gate
        -- Avenging Crusader: MinDuration -> 10.0 ≥ 9.5, evidence=Cast -> matches
        local entry = loader.makeEntry("party1")
        local t = makeTracked(IMP, 1.0, { party1 = 1.0 })
        local rule, unit = B:FindBestCandidate(entry, t, 10.0, {}, { IgnoreTalentRequirements = true })
        fw.not_nil(rule, "IgnoreTalentRequirements should allow the rule to match")
        fw.eq(rule.SpellId, 216331, "SpellId should be Avenging Crusader")
        fw.eq(unit, "party1", "ruleUnit")
    end)
end)

-- Section 12: Local player alias (ResolveSnapshotUnit)
-- In a 2v2 arena the local player appears both as "player" and under a raid/party slot (e.g. "raid2").
-- On 12.0.5+, RecordCast stores casts exclusively under "player", so CastSnapshot["raid2"] is nil.
-- Without GUID resolution, "raid2" passes the `candidate ~= "player"` guard and receives synthetic Cast,
-- causing an EXTERNAL_DEFENSIVE rule (e.g. Blessing of Sacrifice) to match even when the local player
-- provably did not cast any EXT spell (no CastSpellIdSnapshot["player"] entry).

fw.describe("FindBestCandidate - local player unit alias excluded from EXT when no cast (12.0.5)", function()
    fw.before_each(function()
        reset()
    end)

    fw.it("Life Cocoon self-cast not confused with BoSac when local Paladin is raid2 with no cast", function()
        -- 2v2 arena scenario:
        --   party1 = Mistweaver Monk (target + actual self-caster of Life Cocoon 116849)
        --   "player" = local Ret/Holy Paladin, also visible as "raid2" in the group frame
        --   The Paladin cast nothing in the detection window.
        -- Expected: Paladin (raid2) is excluded via GUID resolution -> Monk matches LC via self-cast fallback.
        -- Without fix: raid2 receives synthetic Cast -> BoSac (6940) matches -> wrong.
        wow.setUnitClass("party1", "MONK")
        wow.setUnitClass("player",  "PALADIN")
        wow.setUnitClass("raid2",   "PALADIN")
        mods.talents._setSpec("party1", 270)   -- Mistweaver -> Life Cocoon (116849)
        mods.talents._setSpec("player", 65)    -- Holy Paladin -> Blessing of Sacrifice (6940)
        -- "player" and "raid2" are the same physical player.
        wow.setUnitGUID("player", "Player-GUID-PAL")
        wow.setUnitGUID("raid2",  "Player-GUID-PAL")
        local entry = loader.makeEntry("party1")
        -- Shield evidence from LC's absorb; no cast snapshot (Paladin cast nothing this window).
        local t = makeTracked(EXT, 5.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "raid2" })
        fw.not_nil(rule, "Life Cocoon should match (Monk self-cast)")
        fw.eq(rule.SpellId, 116849, "SpellId should be Life Cocoon, not Blessing of Sacrifice")
        fw.eq(unit, "party1", "Monk should be the attributed caster (self-cast fallback)")
    end)

    fw.it("local Monk (player) self-casting Life Cocoon not confused with BoSac from party Paladin", function()
        -- 2v2 arena: local player is Mistweaver Monk ("player"), other player is Paladin ("party1").
        -- Monk casts Life Cocoon (116849) on themselves - entry.Unit = "player".
        -- CastSnapshot["player"] and CastSpellIdSnapshot["player"] both have LC cast.
        -- Without fix: Paladin ("party1") gets synthetic Cast -> BoSac (6940) matches first ->
        --   self-cast fallback condition (not rule) is false -> LC never checked -> BoSac committed.
        -- With fix: playerIsExtCaster=true (player cast 116849 which matches LC rule) ->
        --   Paladin's synthetic Cast blocked -> no non-target match -> self-cast fallback runs -> LC.
        wow.setUnitClass("player",  "MONK")
        wow.setUnitClass("party1",  "PALADIN")
        mods.talents._setSpec("player", 270)   -- Mistweaver -> Life Cocoon (116849)
        mods.talents._setSpec("party1", 65)    -- Holy Paladin -> BoSac (6940)
        local entry = loader.makeEntry("player")
        -- Real cast snapshot for Monk ("player") + spell ID confirming LC cast.
        local castSpellIds = { player = { { SpellId = 116849, Time = 5.0 } } }
        -- Shield evidence from LC's absorb bubble; real cast time under "player".
        local t = makeTracked(EXT, 5.0, { player = 5.0 }, { Shield = true }, castSpellIds)
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party1" })
        fw.not_nil(rule, "Life Cocoon should match (Monk self-cast)")
        fw.eq(rule.SpellId, 116849, "SpellId should be Life Cocoon, not Blessing of Sacrifice")
        fw.eq(unit, "player", "Monk (player) should be the attributed caster (self-cast)")
    end)

    fw.it("local Paladin as raid2 with a real EXT cast still matches BoSac", function()
        -- Same 2v2 setup, but this time the local Paladin (raid2) actually cast BoSac.
        -- CastSnapshot["player"] has the cast time -> GUID resolution picks it up -> BoSac matches.
        wow.setUnitClass("party1", "MONK")
        wow.setUnitClass("player",  "PALADIN")
        wow.setUnitClass("raid2",   "PALADIN")
        mods.talents._setSpec("party1", 270)
        mods.talents._setSpec("player", 65)
        wow.setUnitGUID("player", "Player-GUID-PAL")
        wow.setUnitGUID("raid2",  "Player-GUID-PAL")
        local entry = loader.makeEntry("party1")
        -- Paladin cast BoSac at t=5.0 (within window); snapshot stored under "player".
        -- CastSpellIdSnapshot confirms the spell ID so the fast path fires.
        local castSpellIds = { player = { { SpellId = 6940, Time = 5.0 } } }
        local t = makeTracked(EXT, 5.0, { player = 5.0 }, { Shield = true }, castSpellIds)
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "raid2" })
        fw.not_nil(rule, "Blessing of Sacrifice should match when Paladin has a real cast")
        fw.eq(rule.SpellId, 6940, "SpellId should be Blessing of Sacrifice")
        fw.eq(unit, "raid2", "raid2 (Paladin alias) should be the attributed caster")
    end)
end)

-- Section 13: SelfCastable = false (Blessing of Sacrifice)
-- BoSac (SpellId 6940) is marked SelfCastable=false because Blessing of Sacrifice cannot be
-- targeted at oneself - the damage redirection mechanic requires a separate caster and recipient.
-- Consequence: the EXT self-cast fallback must never attribute BoSac to the target unit.

fw.describe("FindBestCandidate - SelfCastable=false (Blessing of Sacrifice)", function()
    fw.before_each(function()
        reset()
    end)

    fw.it("self-cast fallback does not attribute BoSac to the target Paladin", function()
        -- BoSac appears on a Holy Paladin (party1) with no non-target candidates.
        -- Without SelfCastable=false: target Paladin gets synthetic Cast (isTarget=true) ->
        --   BoSac matches via self-cast fallback -> wrong attribution.
        -- With SelfCastable=false: self-cast is rejected -> nil (correct: caster unknown).
        wow.setUnitClass("party1", "PALADIN")
        mods.talents._setSpec("party1", 65)   -- Holy Paladin -> BoSac
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, {}, { Shield = true })
        local rule = B:FindBestCandidate(entry, t, 12.0, {})
        fw.is_nil(rule, "BoSac cannot be self-cast; target Paladin must not be attributed")
    end)

    fw.it("two Paladins: BoSac on one, other Paladin is attributed (not the recipient)", function()
        -- party1 (Holy Paladin, target) receives BoSac; party2 (Holy Paladin) is the caster.
        -- SelfCastable=false blocks the self-cast fallback for party1.
        -- party2 (non-target, non-player) gets synthetic Cast -> BoSac matches for party2.
        wow.setUnitClass("party1", "PALADIN")
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party1", 65)
        mods.talents._setSpec("party2", 65)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, {}, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2" })
        fw.not_nil(rule, "BoSac should be attributed to the non-target Paladin")
        fw.eq(rule.SpellId, 6940, "SpellId should be BoSac")
        fw.eq(unit, "party2", "party2 (non-target caster) should win, not party1 (recipient)")
    end)

    fw.it("Paladin with real cast snapshot still matches BoSac as non-target caster", function()
        -- Ensure SelfCastable=false does not break the normal non-target attribution path.
        -- party2 (Paladin, non-target) has a real cast snapshot -> BoSac attributed to party2.
        wow.setUnitClass("party1", "WARRIOR")   -- target (recipient)
        wow.setUnitClass("party2", "PALADIN")
        mods.talents._setSpec("party2", 65)
        local entry = loader.makeEntry("party1")
        local t = makeTracked(EXT, 5.0, { party2 = 5.0 }, { Shield = true })
        local rule, unit = B:FindBestCandidate(entry, t, 12.0, { "party2" })
        fw.not_nil(rule, "BoSac should match for non-target Paladin with real cast")
        fw.eq(rule.SpellId, 6940, "SpellId")
        fw.eq(unit, "party2", "ruleUnit should be the non-target caster")
    end)
end)
