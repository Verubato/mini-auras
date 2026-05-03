-- Tests for Revival/Restoral vs Grounding Totem disambiguation.
--
-- Mistweaver Monks with the Peaceweaver PvP talent (5395) gain a modified Revival (115310)
-- or Restoral (388615) that applies a 2s IMPORTANT aura to all party members.
-- Grounding Totem (shaman PvP talent) also applies a short IMPORTANT aura to nearby allies.
-- Both are indistinguishable by duration and aura type alone.
--
-- Disambiguation uses the local player's cast snapshot (UNIT_SPELLCAST_SUCCEEDED):
--
--   Monk (local player) as target:
--     * Revival/Restoral in cast snapshot -> IsProbablyRevival=true -> GT guard bypassed ->
--       Revival/Restoral committed via MatchRule fast-path.
--     * No Revival cast in snapshot -> GT guard fires -> suppress (Shaman probably pressed GT).
--
--   Non-Monk target (e.g. Shaman with GT, Warrior):
--     * Revival/Restoral in local player's snapshot -> RevivalGuard suppresses the commit
--       (aura is spillover from the Monk's cast, not the unit's own ability).
--     * No Revival cast in snapshot -> normal matching proceeds (GT commits for Shaman, etc.).
--
-- Spell/talent IDs used:
--   Revival     115310  Mistweaver spec 270, 2s IMPORTANT, RequiresTalent=5395, ExcludeIfTalent=388615
--   Restoral    388615  Mistweaver spec 270, 2s IMPORTANT, RequiresTalent=5395, ExcludeIfTalent=115310
--   Peaceweaver  5395   PvP talent enabling Revival/Restoral tracking
--   Grounding Totem 204336  Shaman class, IMPORTANT, RequiresTalent={3620,3622,715}

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

local function makeTracked(auraTypes, startTime, castSnapshot, evidence, castSpellIdSnapshot)
    return {
        StartTime           = startTime or 1.0,
        AuraTypes           = auraTypes,
        Evidence            = evidence,
        CastSnapshot        = castSnapshot or {},
        CastSpellIdSnapshot = castSpellIdSnapshot or {},
    }
end

-- Sets up arena with the Monk as the local player (party1 aliased) and a GT Shaman as party2.
local function setupMonkAndShaman()
    wow.setInstanceType("arena")
    wow.setUnitGUID("party1", "player")
    wow.setUnitClass("player", "MONK")
    wow.setUnitClass("party1", "MONK")
    mods.talents._setSpec("player", 270)
    mods.talents._setSpec("party1", 270)
    mods.talents._setTalent("player", 5395, true)
    mods.talents._setTalent("party1", 5395, true)
    wow.setUnitClass("party2", "SHAMAN")
    mods.talents._setTalent("party2", 3620, true)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 1: Monk (local player) is the target
--
-- Monk has Peaceweaver; GT Shaman is in the group.  Disambiguation relies on the
-- local player's cast snapshot: Revival/Restoral in the window -> Revival committed;
-- empty snapshot -> GT spillover suppresses the Monk's aura.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Revival vs GT: Monk (local player) as target", function()
    fw.before_each(reset)

    fw.it("Revival committed when Monk pressed Revival and GT Shaman is in group", function()
        setupMonkAndShaman()
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.not_nil(rule, "Revival should be committed, not suppressed as GT spillover")
        fw.eq(rule and rule.SpellId, 115310, "SpellId should be Revival (115310)")
        fw.eq(unit, "party1", "Monk (party1) is the attributed caster")
    end)

    fw.it("Restoral committed when Monk pressed Restoral and GT Shaman is in group", function()
        setupMonkAndShaman()
        -- Set Restoral talent so Revival's ExcludeIfTalent=388615 fires and Restoral is chosen.
        mods.talents._setTalent("player",  388615, true)
        mods.talents._setTalent("party1",  388615, true)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 388615, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.not_nil(rule, "Restoral should be committed, not suppressed as GT spillover")
        fw.eq(rule and rule.SpellId, 388615, "SpellId should be Restoral (388615)")
        fw.eq(unit, "party1", "Monk (party1) is the attributed caster")
    end)

    fw.it("Monk aura suppressed when no Revival cast and GT Shaman is in group", function()
        setupMonkAndShaman()
        -- Empty snapshot: local player cast nothing -> GT spillover suppresses the Monk's aura.
        local entry    = loader.makeEntry("party1")
        local t        = makeTracked(IMP, 1.0, {}, nil, {})
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "GT spillover should suppress the Monk's aura when no Revival was cast")
    end)

    fw.it("Monk without Peaceweaver: GT spillover suppressed normally", function()
        -- Monk without Peaceweaver has no Revival/Restoral -> no Revival exception in GT guard.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party1", 270)
        -- No Peaceweaver set.
        wow.setUnitClass("party2", "SHAMAN")
        mods.talents._setTalent("party2", 3620, true)
        local entry = loader.makeEntry("party1")
        local t     = makeTracked(IMP, 1.0, {}, nil, {})
        local rule  = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Monk without Peaceweaver: GT suppresses the 2s IMPORTANT aura normally")
    end)

    fw.it("GT suppression does not fire when no GT Shaman is in the group", function()
        -- Monk has Peaceweaver but there is no GT Shaman -> GT guard returns false.
        -- With Revival in the snapshot, Revival is committed normally.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party1", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party1", 5395, true)
        -- No Shaman with GT in the group.
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, {})
        fw.not_nil(rule, "Revival should commit when no GT Shaman is in the group")
        fw.eq(rule and rule.SpellId, 115310, "SpellId should be Revival (115310)")
        fw.eq(unit, "party1", "Monk is the attributed caster")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 2: Non-Monk target - Revival spillover suppression (RevivalGuard)
--
-- When the local player (Monk) presses Revival/Restoral, the 2s AoE IMPORTANT buff
-- lands on all party members.  For non-Monk targets this is spillover and must not
-- trigger GT or any other cooldown.  When the Monk did NOT press Revival, the cast
-- snapshot is empty and normal matching proceeds (GT commits for the Shaman, etc.).
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Revival spillover: non-Monk target", function()
    fw.before_each(reset)

    -- party1 = Shaman with GT (target); party2 = Monk (local player, Peaceweaver).
    local function setupShamanTargetMonkCaster()
        wow.setInstanceType("arena")
        wow.setUnitGUID("party2", "player")
        wow.setUnitClass("party1", "SHAMAN")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party2", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party2", 5395, true)
        mods.talents._setTalent("party1", 3620, true)
    end

    fw.it("Shaman aura suppressed as Revival spillover when Monk pressed Revival", function()
        -- Core scenario: Monk presses Revival; party Shaman (who also has GT) receives the
        -- AoE buff.  Without the RevivalGuard this would be falsely committed as GT.
        setupShamanTargetMonkCaster()
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Shaman aura should be suppressed as Revival spillover, not committed as GT")
    end)

    fw.it("Shaman aura suppressed as Revival spillover when Monk pressed Restoral", function()
        setupShamanTargetMonkCaster()
        mods.talents._setTalent("player",  388615, true)
        mods.talents._setTalent("party2",  388615, true)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 388615, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Shaman aura should be suppressed as Restoral spillover")
    end)

    fw.it("Shaman GT commits normally when local Monk did not press Revival", function()
        -- Shaman pressed GT; local Monk cast nothing -> empty snapshot -> GT commits.
        setupShamanTargetMonkCaster()
        local entry = loader.makeEntry("party1")
        local t     = makeTracked(IMP, 1.0, {}, nil, {})
        local rule, unit = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.not_nil(rule, "GT should commit for Shaman when local Monk did not press Revival")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem (204336)")
        fw.eq(unit, "party1", "Shaman (party1) is the attributed caster")
    end)

    fw.it("Warrior aura suppressed as Revival spillover when Monk pressed Revival", function()
        -- Monk presses Revival; Warrior receives the AoE buff. No GT Shaman in the group.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party2", "player")
        wow.setUnitClass("party1", "WARRIOR")
        wow.setUnitClass("player", "MONK")
        wow.setUnitClass("party2", "MONK")
        mods.talents._setSpec("player", 270)
        mods.talents._setSpec("party2", 270)
        mods.talents._setTalent("player", 5395, true)
        mods.talents._setTalent("party2", 5395, true)
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 115310, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "party2" })
        fw.is_nil(rule, "Warrior aura should be suppressed as Revival spillover")
    end)
end)
