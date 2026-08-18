-- Alerts module, token source selection. The bars read one AuraContainer per enemy, and which
-- token that container is pointed at decides whether the alerts survive an enemy going out of
-- sight: a nameplate is released the moment the unit is hidden, behind a pillar or out of range,
-- and the display goes with it, while an arena token stays valid for the whole match.
--
-- So inside a 2v2 or 3v3 the module reads arena1..3, and everywhere else - bigger brackets,
-- battlegrounds, the open world - it falls back to nameplates. The failure this guards is silent
-- either way round: arena tokens in a bracket they do not cover means opponents with no alerts at
-- all, and nameplates in a 3v3 means the flicker the change was made to remove.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local alerts = db.Modules.AlertsModule

alerts.Enabled.Always = true
alerts.Icons.Enabled = true
alerts.SplitBars = false
alerts.Important.Enabled = true
-- On so the engine sound registrations exist; they follow the tracked tokens and are the half of
-- a source switch that a released display does not clean up on its own.
alerts.Sound.Important.Enabled = true
alerts.Sound.Defensive.Enabled = true

env.loadModule("src/Modules/Alerts/Sound.lua")
env.loadModule("src/Modules/Alerts/Display.lua")
env.loadModule("src/Modules/Alerts/Module.lua")
local module = env.addon.Modules.AlertsModule
module:Init()
-- Init only builds the lifecycle now; a module sets itself up on the first refresh that
-- finds it enabled, which in the addon is the one PLAYER_ENTERING_WORLD drives.
module:Refresh()

local events = assert(acm.lastFrameForEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS"), "alerts event frame")

---The live (enabled) containers tracking a token. Earlier rebuilds leave parked containers still
---tagged with it, and those are not what the module is drawing from.
local function liveCount(token)
	local count = 0
	for _, container in ipairs(env.containersForUnit(token)) do
		if container._enabled then
			count = count + 1
		end
	end
	return count
end

local function tracked(token)
	return liveCount(token) > 0
end

---Puts the client in an arena with `opponents` enemies and refreshes.
local function enterArena(opponents)
	env.inInstance = true
	env.instanceType = "arena"
	env.arenaOpponents = opponents
	env.invalidateWorldState()
	env.loadWorld(module)
end

local function enterWorld()
	env.inInstance = false
	env.instanceType = "none"
	env.arenaOpponents = 0
	env.invalidateWorldState()
	env.loadWorld(module)
end

local function addEnemyPlate(token)
	env.enemies[token] = true
	env.addPlate(token)
	events:TriggerEvent("NAME_PLATE_UNIT_ADDED", token)
end

local function removePlate(token)
	events:TriggerEvent("NAME_PLATE_UNIT_REMOVED", token)
	env.plates[token] = nil
	env.enemies[token] = nil
end

-- Runs FIRST, and has to: a display pair is kept for the rest of the session once built, so a
-- later test entering an arena would leave the arena pairs standing and "nothing was built yet"
-- could never fail.
fw.describe("AlertsModule - when the arena pairs get built", function()
	local alertsDisplay = env.addon.Modules.Alerts.Display

	fw.it("builds none of them behind the loading screen", function()
		-- A button takes its look once, in initializeFrame, and inside an arena
		-- C_Secrets.ShouldAurasBeSecret never clears - so no restyle ever gets to correct it.
		-- Building a pair before the client will say who it is tracking spends that one chance
		-- on an unknown opponent.
		local prewarmed = {}
		local realPrewarm = alertsDisplay.Prewarm

		alertsDisplay.Prewarm = function(self, prefix, count)
			prewarmed[#prewarmed + 1] = prefix
			return realPrewarm(self, prefix, count)
		end

		env.inInstance = true
		env.instanceType = "arena"
		env.arenaOpponents = 0
		env.invalidateWorldState()
		env.loadWorld(module)

		env.loadingScreenUp = true
		module:Refresh()

		-- Restored before any assert, so a failure cannot leave the spy installed and the
		-- loading screen up for every test after it.
		env.loadingScreenUp = false
		alertsDisplay.Prewarm = realPrewarm

		assert(#env.containersForUnit("arena1") == 0, "no arena pair exists yet")
		for _, prefix in ipairs(prewarmed) do
			assert(prefix ~= "arena", "the arena tokens must not be prepared up front")
		end
	end)

	fw.it("builds them when the client names the opponents", function()
		env.arenaSpecs = { arena1 = 1, arena2 = 2, arena3 = 3 }
		events:TriggerEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
		env.arenaSpecs = {}

		assert(#env.containersForUnit("arena1") > 0, "the pair is built once the specs arrive")
		assert(tracked("arena1"), "and it is live")
	end)
end)

fw.describe("AlertsModule - picking the token source", function()
	fw.it("reads arena tokens in a 3v3", function()
		enterArena(3)

		assert(tracked("arena1") and tracked("arena2") and tracked("arena3"),
			"every opponent is bound to its arena token")
	end)

	fw.it("binds a token whose opponent is nowhere to be seen", function()
		-- The whole point of the source. Nothing has been said about arena3 - no plate, no
		-- roster entry - and its display is up regardless, ready for the moment the client can
		-- answer for it.
		assert(env.plates.arena3 == nil, "precondition: no plate ever existed for it")
		assert(tracked("arena3"), "the display is bound anyway")
	end)

	fw.it("ignores enemy nameplates while the arena tokens are in play", function()
		addEnemyPlate("nameplate1")

		assert(not tracked("nameplate1"), "a plate must not add a second row for the same enemy")

		removePlate("nameplate1")
	end)

	fw.it("reads arena tokens in a 2v2 as well, and only the two", function()
		enterArena(2)

		assert(tracked("arena1") and tracked("arena2"), "both opponents bound")
		assert(not tracked("arena3"), "and no third row for an opponent that is not there")
	end)

	fw.it("falls back to nameplates in a bracket the arena tokens do not cover", function()
		-- The client only hands out arena1..3, so a larger bracket would leave most of the enemy
		-- team with no alerts at all.
		enterArena(10)

		assert(not tracked("arena1"), "the arena tokens are dropped")

		addEnemyPlate("nameplate1")
		assert(tracked("nameplate1"), "and the plates take over")

		removePlate("nameplate1")
	end)

	fw.it("uses nameplates in the open world", function()
		enterWorld()
		addEnemyPlate("nameplate1")

		assert(tracked("nameplate1"), "plates as before")
		assert(not tracked("arena1"), "and nothing on the arena tokens")

		removePlate("nameplate1")
	end)

	fw.it("uses nameplates in a battleground", function()
		env.inInstance = true
		env.instanceType = "pvp"
		env.invalidateWorldState()
		env.loadWorld(module)
		addEnemyPlate("nameplate1")

		assert(tracked("nameplate1"), "a battleground is a plate zone whatever its size")

		removePlate("nameplate1")
	end)

	fw.it("tracks nothing in a dungeon", function()
		env.inInstance = true
		env.instanceType = "party"
		env.invalidateWorldState()
		env.loadWorld(module)

		assert(not tracked("arena1") and not tracked("nameplate1"), "alerts do not run in here")
	end)
end)

fw.describe("AlertsModule - moving between the two sources", function()
	fw.it("releases the plate displays when the arena tokens take over", function()
		enterWorld()
		addEnemyPlate("nameplate1")
		assert(tracked("nameplate1"), "precondition: drawn on a plate")

		enterArena(3)

		assert(not tracked("nameplate1"), "the plate row is parked")
		assert(tracked("arena1"), "and the arena row replaces it")

		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil
	end)

	fw.it("takes the plate sound registrations with them", function()
		-- Releasing a display deliberately leaves its engine sound registrations warm, because a
		-- plate token comes and goes constantly and re-registering ~80 sounds per churn is pure
		-- API traffic. A source switch is the one case where that is wrong: in the arena the
		-- plate token is one of the same three opponents, so every alert would sound twice and
		-- TTS would say the name twice.
		local live = {}
		for _, registration in pairs(env.auraSounds) do
			if registration then
				live[registration.Unit] = true
			end
		end

		assert(live.arena1, "precondition: the arena tokens are registered")
		assert(not live.nameplate1, "the plate registrations went with the source")
	end)

	fw.it("releases the arena displays on the way back out", function()
		enterWorld()

		assert(not tracked("arena1") and not tracked("arena2"), "nothing left bound to arena tokens")
	end)

	fw.it("does not carry a bracket's opponent count into the next zone", function()
		-- A high-water mark over one arena's reports, so a 10-man bracket must not decide the
		-- next match's source. The count itself is not readable from here, so this checks the
		-- behaviour it drives.
		enterArena(10)
		assert(not tracked("arena1"), "precondition: the big bracket used plates")

		enterArena(3)
		assert(tracked("arena1"), "the next arena starts the count over")
	end)

	fw.it("switches to arena tokens when the prep room names the opponents", function()
		-- Zoning in answers nothing: the module opens on nameplates and moves over as soon as
		-- the starting room hands over the opponent specs.
		env.inInstance = true
		env.instanceType = "arena"
		env.arenaOpponents = 0
		env.invalidateWorldState()
		env.loadWorld(module)

		addEnemyPlate("nameplate1")
		assert(tracked("nameplate1"), "no count yet, so plates carry the alerts")

		env.arenaSpecs = { arena1 = 1, arena2 = 2, arena3 = 3 }
		events:TriggerEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
		env.arenaSpecs = {}

		assert(tracked("arena1") and tracked("arena3"), "the arena tokens take over")
		assert(not tracked("nameplate1"), "and the plate row is released")

		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil
	end)

	fw.it("settles the source again when the gates open", function()
		-- A reload mid-match misses the prep specs entirely, so the live opponent list at the
		-- match-state change is the only thing left to learn from.
		env.inInstance = true
		env.instanceType = "arena"
		env.arenaOpponents = 0
		env.invalidateWorldState()
		env.loadWorld(module)
		assert(not tracked("arena1"), "precondition: nothing known yet")

		env.arenaOpponents = 3
		events:TriggerEvent("PVP_MATCH_STATE_CHANGED")

		assert(tracked("arena1"), "the live opponent list moved it over")
	end)

	fw.it("settles the source from the roster after a reload", function()
		-- A reload mid-match misses the prep specs and the gates opening alike. The roster is the
		-- only other thing that fires in an arena, so without it a reloaded match would spend the
		-- rest of its life on nameplates.
		env.inInstance = true
		env.instanceType = "arena"
		env.arenaOpponents = 0
		env.invalidateWorldState()
		env.loadWorld(module)
		assert(not tracked("arena1"), "precondition: nothing known yet")

		env.arenaOpponents = 3
		events:TriggerEvent("GROUP_ROSTER_UPDATE")

		assert(tracked("arena1"), "the roster event moved it over")
	end)

	fw.it("binds the opponents a climbing count adds", function()
		enterArena(2)
		assert(not tracked("arena3"), "precondition: two opponents")

		env.arenaOpponents = 3
		events:TriggerEvent("PVP_MATCH_STATE_CHANGED")

		assert(tracked("arena3"), "the third is bound without a zone change")
	end)
end)

fw.describe("AlertsModule - arena tokens outside the visible world", function()
	local alertsDisplay = env.addon.Modules.Alerts.Display

	-- A buff on an enemy has no working spell-id filter, so the category token carries the group
	-- on its own, and the engine stops evaluating that token for a unit it cannot answer for. The
	-- group then fills with buffs belonging to somebody else - reported in 5.19.0 as the player's
	-- own buffs appearing on the alert bar at the start of every solo shuffle round, where the
	-- teams are re-dealt and the arena tokens are briefly empty. A plate never reaches this state,
	-- which is why nothing guarded it before the arena source existed.

	fw.it("parks the pair while the client has no unit behind the token", function()
		enterArena(3)
		assert(tracked("arena2"), "precondition: bound")

		env.phased.arena2 = true
		acm.tickAll(1)

		assert(not tracked("arena2"), "nothing is drawn from a token the engine cannot filter")
		assert(tracked("arena1"), "and the opponents it can answer for are untouched")

		env.phased.arena2 = nil
		acm.tickAll(1)

		assert(tracked("arena2"), "and it comes back once the unit lands")
	end)

	fw.it("parks it on the opponent event, without waiting for the poll", function()
		-- ARENA_OPPONENT_UPDATE is the only thing that announces an opponent leaving the client's
		-- world. The poll gets there too, but a tick later, and that tick is a bar full of
		-- somebody else's buffs.
		enterArena(3)
		assert(tracked("arena2"), "precondition: bound")

		env.phased.arena2 = true
		events:TriggerEvent("ARENA_OPPONENT_UPDATE", "arena2", "unseen")

		assert(not tracked("arena2"), "parked on the event alone")

		env.phased.arena2 = nil
		events:TriggerEvent("ARENA_OPPONENT_UPDATE", "arena2", "seen")

		assert(tracked("arena2"), "and back on the event alone")
	end)

	fw.it("ignores an opponent past the count it bound", function()
		-- The event names a token the module drops, since a burst of them all say the same thing;
		-- what it reconciles is the bracket it bound, so a 2v2 stays on arena1 and arena2 however
		-- the client numbers the unit it announced.
		enterArena(2)
		assert(not tracked("arena3"), "precondition: outside the bracket")

		events:TriggerEvent("ARENA_OPPONENT_UPDATE", "arena3", "seen")

		assert(not tracked("arena3"), "still nothing bound to it")
	end)

	fw.it("reconciles a burst of them once", function()
		-- Pillar dancing fires this several times a second, and every one of them asks for the
		-- same three-token pass.
		enterArena(3)

		local passes = 0
		local realSync = alertsDisplay.SyncActiveTokens

		alertsDisplay.SyncActiveTokens = function(...)
			passes = passes + 1
			return realSync(...)
		end

		-- The harness runs C_Timer.After callbacks inline, which is the one thing a coalescer
		-- cannot batch under. Held back here so the whole burst lands before the pass it queued.
		local pending = {}
		local realAfter = C_Timer.After

		C_Timer.After = function(_, fn)
			pending[#pending + 1] = fn
		end

		for _ = 1, 5 do
			events:TriggerEvent("ARENA_OPPONENT_UPDATE", "arena1", "unseen")
		end

		C_Timer.After = realAfter

		for index = 1, #pending do
			pending[index]()
		end

		alertsDisplay.SyncActiveTokens = realSync

		assert(passes == 1, "the burst collapsed onto one reconcile, got " .. passes)
	end)

	fw.it("binds none of them on a refresh taken while they are empty", function()
		enterArena(3)

		env.phased.arena1 = true
		env.phased.arena2 = true
		env.phased.arena3 = true
		module:Refresh()

		assert(not tracked("arena1") and not tracked("arena2") and not tracked("arena3"),
			"the whole row stays parked")

		env.phased.arena1 = nil
		env.phased.arena2 = nil
		env.phased.arena3 = nil
		module:Refresh()

		assert(tracked("arena1"), "and binds once the units are there")
	end)

	fw.it("does not force a re-read on an empty token when the teams are re-dealt", function()
		-- The forced re-parse is what plants the garbage: a group that parses with no unit to
		-- check against keeps that answer until the next parse.
		enterArena(3)

		env.phased.arena1 = true
		acm.tickAll(1)

		local before = 0
		for _, container in ipairs(env.containersForUnit("arena1")) do
			before = before + (container._calls.SetUnit or 0)
		end

		events:TriggerEvent("GROUP_ROSTER_UPDATE")

		local after = 0
		for _, container in ipairs(env.containersForUnit("arena1")) do
			after = after + (container._calls.SetUnit or 0)
		end

		assert(after == before, "no re-read is asked of a token with nobody behind it")

		env.phased.arena1 = nil
		acm.tickAll(1)
	end)
end)

fw.describe("AlertsModule - arena tokens changing hands", function()
	---Re-pointing a container at nobody and back is the only change the engine sees when a token
	---keeps its name but changes occupant, so that is what these count.
	local function setUnitCalls(token)
		local calls = 0
		for _, container in ipairs(env.containersForUnit(token)) do
			calls = calls + (container._calls.SetUnit or 0)
		end
		return calls
	end

	fw.it("re-reads every arena token when the teams are re-dealt", function()
		-- Solo shuffle hands arena1 to a different player between rounds. The container is given
		-- the same token string, so nothing re-registers on its own and the last round's auras
		-- would sit on the bar for the whole of the next one. The roster changing with the teams
		-- is what says so.
		enterArena(3)
		assert(tracked("arena1"), "precondition: bound")

		local before = setUnitCalls("arena1") + setUnitCalls("arena3")

		events:TriggerEvent("GROUP_ROSTER_UPDATE")

		assert(setUnitCalls("arena1") + setUnitCalls("arena3") > before,
			"the containers were asked to re-read their units")
	end)

	fw.it("leaves the plate displays alone on a roster change", function()
		-- A battleground fires this constantly, and a plate token never changes hands under a
		-- display the way an arena token does.
		enterWorld()
		addEnemyPlate("nameplate1")

		local before = setUnitCalls("nameplate1")
		events:TriggerEvent("GROUP_ROSTER_UPDATE")

		assert(setUnitCalls("nameplate1") == before, "no re-read is owed on a plate")

		removePlate("nameplate1")
	end)
end)
