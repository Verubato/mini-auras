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
        -- Shaman also received a concurrent IMPORTANT aura (GT AoE event) -> count=1 -> confirmed.
        -- hasMatchingEarlyCancelRule: Revival has no CanCancelEarly -> not found -> GT suppresses.
        B._TestSetImportantAuraStart("party2", 1.0)
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

    fw.it("local Shaman (GT talent, no GT cast) receives Revival spillover: suppressed, not committed as GT", function()
        -- Regression: local player is a GT Shaman.  Remote Monk presses Revival.
        -- The 2s IMPORTANT aura on the Shaman is Revival spillover; their GT rule (CanCancelEarly,
        -- 3.5s max, duration fits) must NOT lift Revival suppression when the cast snapshot
        -- proves they did not press GT.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "SHAMAN")
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("player", 3620, true)
        mods.talents._setTalent("party1", 3620, true)
        wow.setUnitClass("party2", "MONK")
        mods.talents._setTalent("party2", 5395, true)
        local entry = loader.makeEntry("party1")
        local t     = makeTracked(IMP, 1.0, {}, nil, {})  -- empty snapshot: shaman cast nothing
        local rule  = B:FindBestCandidate(entry, t, 1.96, { "party2" })
        fw.is_nil(rule, "Revival spillover on local Shaman must be suppressed; GT rule must not commit without a GT cast")
    end)

    fw.it("local Shaman who pressed GT is NOT suppressed by Revival spillover", function()
        -- Shaman pressed GT (204336 in snapshot) at the same time Monk presses Revival.
        -- GT rule in TargetExplainsOwnAura must lift Revival suppression so GT can commit.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player", "SHAMAN")
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("player", 3620, true)
        mods.talents._setTalent("party1", 3620, true)
        wow.setUnitClass("party2", "MONK")
        mods.talents._setTalent("party2", 5395, true)
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 1.0 } } }
        local entry = loader.makeEntry("party1")
        local t     = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule, unit = B:FindBestCandidate(entry, t, 1.96, { "party2" })
        fw.not_nil(rule, "Shaman who pressed GT should commit GT even when Monk also pressed Revival")
        fw.eq(rule and rule.SpellId, 204336, "SpellId should be Grounding Totem (204336)")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 3: Local shaman presses GT with a Peaceweaver Monk in the group
--
-- When the LOCAL PLAYER (shaman) presses GT, the Monk receives GT spillover.
-- Without the localCasterConfirmed guard, IsMonkRevivalAura would return true for any
-- remote Peaceweaver Monk with a short aura, causing the GT check to return false and
-- the Monk's aura to be committed as Revival (115310) instead of being suppressed.
--
-- The fix: if the local player's cast snapshot contains the caster ability (GT=204336),
-- localCasterConfirmed=true → IsMonkRevivalAura is bypassed → GT candidate detection runs
-- → Monk's aura is suppressed as GT spillover.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Local shaman presses GT: remote Peaceweaver Monk suppressed as GT spillover", function()
    fw.before_each(reset)

    -- player = Shaman with GT; party1 = Peaceweaver Monk (remote).
    local function setupShamanCasterMonkTarget()
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "monk-guid")
        wow.setUnitClass("player", "SHAMAN")
        wow.setUnitClass("party1", "MONK")
        mods.talents._setSpec("party1", 270)            -- Mistweaver (Revival is BySpec[270])
        mods.talents._setTalent("player", 3620, true)   -- GT talent
        mods.talents._setTalent("party1", 5395, true)   -- Peaceweaver
    end

    fw.it("Monk aura suppressed as GT spillover when local shaman has GT cast in snapshot", function()
        -- Regression: without localCasterConfirmed, IsMonkRevivalAura returned true for
        -- the remote Monk (duration<=2.5s), causing GT check to return false and the Monk's
        -- 1.57s aura to be committed as Revival (115310).
        setupShamanCasterMonkTarget()
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 1.57, { "player" })
        fw.is_nil(rule, "Monk's 1.57s aura must be suppressed as GT spillover, not committed as Revival")
    end)

    fw.it("Monk aura committed as Revival when local shaman has no GT cast (Monk pressed Revival)", function()
        -- Without a GT cast in the snapshot, localCasterConfirmed=false → IsMonkRevivalAura
        -- runs → remote Monk+Peaceweaver → return true → GT returns false → Revival commits.
        setupShamanCasterMonkTarget()
        local entry = loader.makeEntry("party1")
        local t     = makeTracked(IMP, 1.0, {}, nil, {})
        local rule  = B:FindBestCandidate(entry, t, 1.57, { "player" })
        fw.not_nil(rule, "Monk's aura should commit as Revival when shaman has no GT cast")
        fw.eq(rule and rule.SpellId, 115310, "SpellId should be Revival (115310)")
    end)

    fw.it("Monk aura suppressed even when aura duration is at Peaceweaver boundary (2.0s)", function()
        -- Duration exactly at Revival's expected value. The localCasterConfirmed path bypasses
        -- IsMonkRevivalAura entirely, so the duration gate inside it is irrelevant.
        setupShamanCasterMonkTarget()
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 1.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 2.0, { "player" })
        fw.is_nil(rule, "Monk's 2.0s aura must be suppressed as GT spillover when shaman pressed GT")
    end)

    fw.it("Monk aura not suppressed when GT cast is outside the cast window", function()
        -- GT cast at t=10 but aura at t=1 -> outside castWindow -> localCasterConfirmed=false
        -- -> IsMonkRevivalAura runs -> remote Monk -> return true -> GT returns false -> Revival.
        setupShamanCasterMonkTarget()
        local entry    = loader.makeEntry("party1")
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 10.0 } } }
        local t        = makeTracked(IMP, 1.0, {}, nil, castSnap)
        local rule = B:FindBestCandidate(entry, t, 1.57, { "player" })
        fw.not_nil(rule, "Monk's aura should commit as Revival when GT cast is outside the window")
        fw.eq(rule and rule.SpellId, 115310, "SpellId should be Revival (115310)")
    end)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Section 4: Local player as GT Shaman candidate - negative cast evidence
--
-- (Previously Section 3)
--
-- UNIT_SPELLCAST_SUCCEEDED always fires for the local player in 12.0.5+.
-- When the local player is the only shaman with GT and their snapshot has no GT cast,
-- FilterLocalPlayerCandidates removes them before IsProbablyGroundingTotem is called,
-- so suppression does not fire.
-- ─────────────────────────────────────────────────────────────────────────────

fw.describe("Local player as GT Shaman: negative cast evidence bypasses suppression", function()
    fw.before_each(reset)

    fw.it("GT does not fire when local player (only GT shaman) has no GT cast in snapshot", function()
        -- party1 = local player (Shaman with GT); targetUnit = "party2" (Hunter).
        -- Empty snapshot -> FilterLocalPlayerCandidates removes party1 -> no GT shaman candidate.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player",  "SHAMAN")
        wow.setUnitClass("party1",  "SHAMAN")
        mods.talents._setTalent("player",  3620, true)
        mods.talents._setTalent("party1",  3620, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1" }, {}, IMP, 1.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party2", filtered, 2.0, nil, {}, 1.0, false)
        fw.eq(result, false, "GT suppression must not fire when local player provably did not press GT")
    end)

    fw.it("GT fires when local player (only GT shaman) has GT cast in snapshot", function()
        -- Same setup but local player's snapshot contains GT cast (SpellId 204336).
        -- FilterLocalPlayerCandidates finds the matching rule -> party1 stays in candidates.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player",  "SHAMAN")
        wow.setUnitClass("party1",  "SHAMAN")
        mods.talents._setTalent("player",  3620, true)
        mods.talents._setTalent("party1",  3620, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        local castSnap = { ["player"] = { { SpellId = 204336, Time = 1.0 } } }
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1" }, castSnap, IMP, 1.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party2", filtered, 2.0, nil, castSnap, 1.0, false)
        fw.eq(result, true, "GT suppression must fire when local player provably pressed GT")
    end)

    fw.it("GT fires when a remote shaman (not local player) is the only candidate", function()
        -- party1 = remote Shaman with GT (not the local player).
        -- No local player alias in candidates -> filter is a no-op -> GT suppression fires normally.
        wow.setInstanceType("arena")
        wow.setUnitClass("party1", "SHAMAN")
        mods.talents._setTalent("party1", 3620, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1" }, {}, IMP, 1.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party2", filtered, 2.0, nil, {}, 1.0, false)
        fw.eq(result, true, "GT suppression must fire when a remote shaman is the candidate")
    end)

    fw.it("GT fires when a second shaman pressed GT even if local player did not", function()
        -- party1 = local player (Shaman, no GT cast); party3 = remote Shaman with GT.
        -- Filter removes party1 (no cast); party3 stays -> suppression still fires.
        wow.setInstanceType("arena")
        wow.setUnitGUID("party1", "player")
        wow.setUnitClass("player",  "SHAMAN")
        wow.setUnitClass("party1",  "SHAMAN")
        mods.talents._setTalent("player",  3620, true)
        mods.talents._setTalent("party1",  3620, true)
        wow.setUnitClass("party3", "SHAMAN")
        mods.talents._setTalent("party3", 3620, true)
        wow.setUnitClass("party2", "HUNTER")
        B._TestSetImportantAuraStart("party1", 1.0)
        B._TestSetImportantAuraStart("party3", 1.0)
        local filtered = B._TestFilterLocalPlayerCandidates({ "party1", "party3" }, {}, IMP, 1.0)
        local result = B:IsProbablyGroundingTotem(IMP, "party2", filtered, 2.0, nil, {}, 1.0, false)
        fw.eq(result, true, "GT suppression fires because party3 (remote shaman) pressed GT")
    end)
end)
