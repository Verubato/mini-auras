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
	events:TriggerEvent("PLAYER_ENTERING_WORLD")
end

local function enterWorld()
	env.inInstance = false
	env.instanceType = "none"
	env.arenaOpponents = 0
	env.invalidateWorldState()
	events:TriggerEvent("PLAYER_ENTERING_WORLD")
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
		events:TriggerEvent("PLAYER_ENTERING_WORLD")
		addEnemyPlate("nameplate1")

		assert(tracked("nameplate1"), "a battleground is a plate zone whatever its size")

		removePlate("nameplate1")
	end)

	fw.it("tracks nothing in a dungeon", function()
		env.inInstance = true
		env.instanceType = "party"
		env.invalidateWorldState()
		events:TriggerEvent("PLAYER_ENTERING_WORLD")

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
		events:TriggerEvent("PLAYER_ENTERING_WORLD")

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
		events:TriggerEvent("PLAYER_ENTERING_WORLD")
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
		events:TriggerEvent("PLAYER_ENTERING_WORLD")
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

fw.describe("AlertsModule - preparing the pairs on the way in", function()
	local alertsDisplay = env.addon.Modules.Alerts.Display

	---Records what a loading-screen refresh asked to be prepared.
	local function prewarmsFor(setUp)
		local calls = {}
		local realPrewarm = alertsDisplay.Prewarm

		alertsDisplay.Prewarm = function(self, prefix, count)
			calls[#calls + 1] = { Prefix = prefix, Count = count }
			return realPrewarm(self, prefix, count)
		end

		setUp()
		env.loadingScreenUp = true
		module:Refresh()

		-- Restored before any assert, so a failure cannot leave the spy installed and the
		-- loading screen up for every test after it.
		env.loadingScreenUp = false
		alertsDisplay.Prewarm = realPrewarm

		return calls
	end

	fw.it("prepares the whole arena token set before the opponents are known", function()
		-- The trap this guards: behind the loading screen the client reports no opponents at
		-- all, so preparing "however many are known" prepares nothing, and the first round pays
		-- to build every container while the gates open.
		local calls = prewarmsFor(function()
			env.inInstance = true
			env.instanceType = "arena"
			env.arenaOpponents = 0
			env.invalidateWorldState()
			-- The world load is what clears the opponent high-water mark. Without it an earlier
			-- test's count of three survives, and a regression to preparing "however many are
			-- known" would still prepare three and pass.
			events:TriggerEvent("PLAYER_ENTERING_WORLD")
			assert(not tracked("arena1"), "precondition: no opponent count is known yet")
		end)

		assert(#calls == 1, "one prepare pass, got " .. #calls)
		assert(calls[1].Prefix == "arena" and calls[1].Count == 3,
			"the arena tokens are prepared in full, got "
				.. tostring(calls[1].Prefix) .. " x" .. tostring(calls[1].Count))
	end)

	fw.it("prepares nameplates everywhere else it runs", function()
		local calls = prewarmsFor(enterWorld)

		assert(#calls == 1 and calls[1].Prefix == "nameplate", "the plate set as before")
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
