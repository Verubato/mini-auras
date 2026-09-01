-- The engine refuses AddAuraSound in a dungeon or a raid, so the three modules that register
-- sounds must hold nothing there and take everything again on the way out.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db

env.loadModule("src/Modules/PersonalAuras/Sound.lua")
env.loadModule("src/Modules/Alerts/Sound.lua")
env.loadModule("src/Modules/HealerCrowdControl/Sound.lua")

local personalSound = env.addon.Modules.PersonalAuras.Sound
local alertsSound = env.addon.Modules.Alerts.Sound
local healerSound = env.addon.Modules.HealerCrowdControl.Sound

alertsSound:Init()
healerSound:Init()

env.setModuleEnabled("Alerts", true)
env.setModuleEnabled("HealerCrowdControl", true)

db.Modules.Alerts.Sound.Important.Enabled = true
db.Modules.Alerts.Sound.Defensive.Enabled = false
db.Modules.HealerCrowdControl.Sound.Enabled = true

local ICE_BLOCK = 45438
local POLYMORPH = 118

---Moves the player to a kind of place and stales the snapshot the gate reads off.
---@param instanceType string
local function Zone(instanceType)
	env.inInstance = instanceType ~= "none"
	env.instanceType = instanceType
	env.invalidateWorldState()
end

---How many registrations the engine is holding right now.
---@return number
local function LiveHandles()
	local count = 0

	for _ in pairs(env.auraSounds) do
		count = count + 1
	end

	return count
end

fw.describe("PersonalAuras sounds - the PvE gate", function()
	local requests = {
		{
			GroupId = "gGate",
			Unit = "player",
			Trigger = "Applied",
			File = "Sonar",
			Channel = "Master",
			SpellIds = { ICE_BLOCK, POLYMORPH },
		},
	}

	fw.it("hands back every handle on the way into a dungeon", function()
		Zone("none")
		personalSound:Apply(requests)

		local outdoors = LiveHandles()

		Zone("party")
		personalSound:Apply(requests)

		assert(outdoors == 2, "both spells registered outdoors, got " .. outdoors)
		assert(LiveHandles() == 0, "and nothing is held in the dungeon, got " .. LiveHandles())
	end)

	fw.it("registers the whole key again on the way out", function()
		local before = env.auraSoundAdds

		Zone("none")
		personalSound:Apply(requests)

		assert(LiveHandles() == 2, "both spells are back, got " .. LiveHandles())
		assert(env.auraSoundAdds == before + 2, "and both were asked for again")

		personalSound:Clear()
	end)
end)

fw.describe("Alerts sounds - the PvE gate", function()
	local tokens = { nameplate1 = true }

	env.enemies.nameplate1 = true

	fw.it("hands back every token's registrations on the way into a raid", function()
		Zone("none")
		alertsSound:Refresh(tokens)

		local outdoors = LiveHandles()

		Zone("raid")
		alertsSound:Refresh(tokens)

		assert(outdoors > 0, "the token registered outdoors")
		assert(LiveHandles() == 0, "and nothing is held in the raid, got " .. LiveHandles())
	end)

	fw.it("leaves no record of a plate that arrived inside", function()
		local before = env.auraSoundAdds

		alertsSound:RegisterToken("nameplate2")

		assert(env.auraSoundAdds == before, "the engine was never asked inside")

		-- No refresh in between, so only the missing record can let the token register.
		Zone("none")
		alertsSound:RegisterToken("nameplate2")

		assert(env.auraSoundAdds > before, "and the token registers once the engine will take it")

		alertsSound:RemoveToken("nameplate2")
	end)

	fw.it("registers the token again on the way out, despite the settings stamp", function()
		local before = env.auraSoundAdds

		Zone("none")
		alertsSound:Refresh(tokens)

		assert(env.auraSoundAdds > before, "the stamp moved with the zone, so the token re-registered")
		assert(LiveHandles() > 0, "and the engine is holding them again")

		alertsSound:RemoveAllTokens()
		alertsSound:RemoveAllySounds()
	end)
end)

fw.describe("HealerCrowdControl sounds - the PvE gate", function()
	local healers = { party1 = true }

	fw.it("hands back every healer's registrations on the way into a dungeon", function()
		Zone("none")
		healerSound:Refresh(healers)

		local outdoors = LiveHandles()

		Zone("party")
		healerSound:Refresh(healers)

		assert(outdoors > 0, "the healer registered outdoors")
		assert(LiveHandles() == 0, "and nothing is held in the dungeon, got " .. LiveHandles())
	end)

	fw.it("registers the healer again on the way out, despite the settings stamp", function()
		local before = env.auraSoundAdds

		Zone("none")
		healerSound:Refresh(healers)

		assert(env.auraSoundAdds > before, "the healer was registered again")
		assert(LiveHandles() > 0, "and the engine is holding them again")

		healerSound:Clear()
	end)
end)
