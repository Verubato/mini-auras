-- The engine refuses AddAuraSound while the player is in combat inside instanced PvE, so the three
-- modules that register sounds must hold what they already have rather than hand it back at a pull.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db

db.Modules.Alerts.Icons.Enabled = true
db.Modules.Alerts.Sound.Important.Enabled = true
db.Modules.Alerts.Sound.Defensive.Enabled = false
db.Modules.Alerts.TTS.EnemyDebuff.Enabled = false
db.Modules.HealerCrowdControl.Sound.Enabled = true

env.loadModule("src/Modules/PersonalAuras/Sound.lua")
env.loadModule("src/Modules/HealerCrowdControl/Sound.lua")
env.loadModule("src/Modules/Alerts/Sound.lua")
env.loadModule("src/Modules/Alerts/Display.lua")
env.loadModule("src/Modules/Alerts/Module.lua")

local auraSounds = env.addon.Core.AuraSounds
local personalSound = env.addon.Modules.PersonalAuras.Sound
local alertsSound = env.addon.Modules.Alerts.Sound
local alertsDisplay = env.addon.Modules.Alerts.Display
local alertsModule = env.addon.Modules.AlertsModule
local healerSound = env.addon.Modules.HealerCrowdControl.Sound

env.setModuleEnabled("Alerts", true)
env.setModuleEnabled("HealerCrowdControl", true)

healerSound:Init()
alertsModule:Init()
-- Init only builds the lifecycle. A module sets itself up on the first refresh that finds it
-- enabled, which in the addon is the one PLAYER_ENTERING_WORLD drives.
alertsModule:Refresh()

local plateEvents = assert(acm.lastFrameForEvent("NAME_PLATE_UNIT_ADDED"), "alerts nameplate events")

local ICE_BLOCK = 45438
local POLYMORPH = 118

---Moves the player to a kind of place and stales the snapshot the gate reads off.
---@param instanceType string
local function Zone(instanceType)
	env.inInstance = instanceType ~= "none"
	env.instanceType = instanceType
	env.invalidateWorldState()
end

---@param value boolean
local function Combat(value)
	env.inCombat = value
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

---Hands everything back, so a test counts only the registrations it made itself.
local function ClearAll()
	personalSound:Clear()
	healerSound:Clear()
	alertsSound:RemoveAllTokens()
	alertsSound:RemoveAllySounds()
end

---@param token string
local function AddPlate(token)
	env.enemies[token] = true
	env.addPlate(token)
	plateEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", token)
end

---@param token string
local function RemovePlate(token)
	if not env.plates[token] then
		return
	end

	plateEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", token)
	env.plates[token] = nil
	env.enemies[token] = nil
end

---The pass the display drives whenever the alert settings may have moved.
local function SoundRefresh()
	alertsSound:Refresh(alertsDisplay:GetActiveTokens())
end

fw.describe("PersonalAuras sounds - the combat gate", function()
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
	local extended = {
		requests[1],
		{
			GroupId = "gLate",
			Unit = "player",
			Trigger = "Applied",
			File = "Sonar",
			Channel = "Master",
			SpellIds = { ICE_BLOCK },
		},
	}

	---Puts both spells in the engine's hands, out of combat inside a dungeon.
	local function Settled()
		ClearAll()
		Zone("party")
		Combat(false)
		personalSound:Apply(requests)
	end

	fw.it("keeps every handle through a pull inside a dungeon", function()
		Settled()

		local settled = LiveHandles()
		local adds, removes = env.auraSoundAdds, env.auraSoundRemoves

		Combat(true)
		personalSound:Apply(requests)

		assert(settled == 2, "both spells registered out of combat, got " .. settled)
		assert(LiveHandles() == 2, "and both are still held in the pull, got " .. LiveHandles())
		assert(env.auraSoundRemoves == removes, "nothing was handed back")
		assert(env.auraSoundAdds == adds, "and nothing was asked for again")
	end)

	fw.it("finds its keys where the pull left them", function()
		Settled()
		Combat(true)
		personalSound:Apply(requests)

		local adds = env.auraSoundAdds

		Combat(false)
		personalSound:Apply(requests)

		assert(LiveHandles() == 2, "both spells are still there, got " .. LiveHandles())
		assert(env.auraSoundAdds == adds, "and an unchanged request needed nothing new")
	end)

	fw.it("registers a group the pull refused once the pull ends", function()
		Settled()
		Combat(true)
		personalSound:Apply(extended)

		assert(LiveHandles() == 2, "the new group got nothing in the pull, got " .. LiveHandles())

		Combat(false)
		personalSound:Apply(extended)

		assert(LiveHandles() == 3, "and it registers once combat drops, got " .. LiveHandles())
	end)
end)

fw.describe("Alerts sounds - the combat gate", function()
	---Registers one plate's sounds, out of combat inside a raid.
	local function Settled()
		ClearAll()
		RemovePlate("nameplate2")
		Zone("raid")
		Combat(false)
		db.Modules.Alerts.Sound.Channel = "Master"
		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = false
		AddPlate("nameplate1")
		alertsModule:RefreshSounds()
	end

	fw.it("keeps a plate's registrations through a pull inside a raid", function()
		Settled()

		local settled = LiveHandles()
		local removes = env.auraSoundRemoves

		Combat(true)
		SoundRefresh()

		assert(settled > 0, "the plate registered out of combat")
		assert(LiveHandles() == settled, "and it still holds them in the pull, got " .. LiveHandles())
		assert(env.auraSoundRemoves == removes, "nothing was handed back")
	end)

	fw.it("takes a plate that arrived mid-pull once the pull ends", function()
		Settled()

		local before = env.auraSoundAdds

		Combat(true)
		auraSounds:ConsumeSkipped()
		AddPlate("nameplate2")

		assert(env.auraSoundAdds == before, "the engine was never asked during the pull")
		assert(auraSounds:ConsumeSkipped(), "and the plate put the end of the pull on the hook")

		Combat(false)
		alertsModule:RefreshSounds()

		assert(env.auraSoundAdds > before, "the recovery registers the plate the pull refused")
	end)

	fw.it("finds its settings stamp where the pull left it", function()
		Settled()
		Combat(true)
		SoundRefresh()

		local before = env.auraSoundAdds

		Combat(false)
		SoundRefresh()

		assert(env.auraSoundAdds == before, "the stamp never moved, so nothing re-registered")
		assert(LiveHandles() > 0, "and the engine is still holding them")
	end)

	fw.it("holds them through a settings change made mid-pull", function()
		Settled()

		local settled = LiveHandles()
		local removes = env.auraSoundRemoves
		local adds = env.auraSoundAdds

		Combat(true)
		db.Modules.Alerts.Sound.Channel = "SFX"
		SoundRefresh()

		assert(LiveHandles() == settled, "the pull keeps the old sound, got " .. LiveHandles())
		assert(env.auraSoundRemoves == removes, "rather than handing it back for one it cannot replace")

		Combat(false)
		SoundRefresh()

		assert(env.auraSoundAdds > adds, "and the new channel is registered once the pull ends")
	end)

	fw.it("holds the ally announcements through a roster change made mid-pull", function()
		Settled()

		local before = LiveHandles()

		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = true
		alertsSound:RefreshAllySounds()

		local settled = LiveHandles()
		local removes = env.auraSoundRemoves

		-- Forced, as the roster event forces it, which is what would otherwise release them.
		Combat(true)
		alertsSound:RefreshAllySounds(true)

		local held = LiveHandles()

		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = false

		assert(settled > before, "the ally announcements registered out of combat, got " .. settled)
		assert(held == settled, "and the pull keeps them, got " .. held)
		assert(env.auraSoundRemoves == removes, "with nothing handed back")
	end)

	fw.it("takes the roster the forced pass could not, once the pull ends", function()
		Settled()
		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = true
		alertsSound:RefreshAllySounds()

		local settled = LiveHandles()

		-- What the forced pass is made for, and what an unmoved stamp would otherwise swallow.
		Combat(true)
		env.friendlyUnits[#env.friendlyUnits + 1] = "party1"
		alertsSound:RefreshAllySounds(true)

		Combat(false)
		alertsSound:RefreshAllySounds()

		local recovered = LiveHandles()

		env.friendlyUnits[#env.friendlyUnits] = nil
		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = false

		assert(recovered > settled, "the new member is announced too, got " .. recovered)
	end)
end)

fw.describe("HealerCrowdControl sounds - the combat gate", function()
	local healers = { party1 = true }
	local joined = { party1 = true, party2 = true }

	---Registers the one healer, out of combat inside a dungeon.
	local function Settled()
		ClearAll()
		RemovePlate("nameplate1")
		RemovePlate("nameplate2")
		Zone("party")
		Combat(false)
		db.Modules.HealerCrowdControl.Sound.Channel = "Master"
		healerSound:Refresh(healers)
	end

	fw.it("keeps every healer's registrations through a pull inside a dungeon", function()
		Settled()

		local settled = LiveHandles()
		local removes = env.auraSoundRemoves

		Combat(true)
		healerSound:Refresh(healers)

		assert(settled > 0, "the healer registered out of combat")
		assert(LiveHandles() == settled, "and they are still held in the pull, got " .. LiveHandles())
		assert(env.auraSoundRemoves == removes, "nothing was handed back")
	end)

	fw.it("registers a healer who joined mid-pull once the pull ends", function()
		Settled()
		Combat(true)

		local before = env.auraSoundAdds

		healerSound:Refresh(joined)

		assert(env.auraSoundAdds == before, "the new healer got nothing during the pull")

		Combat(false)
		healerSound:Refresh(joined)

		assert(env.auraSoundAdds > before, "and they register once it ends")
	end)

	fw.it("holds them through a sound change made mid-pull", function()
		Settled()

		local settled = LiveHandles()
		local removes = env.auraSoundRemoves
		local adds = env.auraSoundAdds

		Combat(true)
		db.Modules.HealerCrowdControl.Sound.Channel = "SFX"
		healerSound:Refresh(healers)

		assert(LiveHandles() == settled, "the pull keeps the old sound, got " .. LiveHandles())
		assert(env.auraSoundRemoves == removes, "rather than handing it back for one it cannot replace")

		Combat(false)
		healerSound:Refresh(healers)

		assert(env.auraSoundAdds > adds, "and the new channel is registered once the pull ends")
	end)
end)

fw.describe("Aura sounds - what asks for a recovery", function()
	local requests = {
		{
			GroupId = "gAsk",
			Unit = "player",
			Trigger = "Applied",
			File = "Sonar",
			Channel = "Master",
			SpellIds = { ICE_BLOCK },
		},
	}
	local healers = { party1 = true }

	---Runs one consumer's pass inside a dungeon pull and reports whether it put the recovery on
	---the hook.
	---@param body function
	---@return boolean
	local function Asked(body)
		Zone("party")
		Combat(true)
		auraSounds:ConsumeSkipped()

		body()

		local asked = auraSounds:ConsumeSkipped()

		Combat(false)
		Zone("none")

		return asked
	end

	fw.it("asks once a consumer had registrations to make", function()
		ClearAll()

		assert(Asked(function()
			personalSound:Apply(requests)
		end), "the group wanted its sounds")

		assert(Asked(function()
			healerSound:Refresh(healers)
		end), "the healer wanted one")

		assert(Asked(function()
			SoundRefresh()
		end), "and so did the plate")
	end)

	-- A sound switched off mid-pull cannot be handed back either, so the end of the pull has to run
	-- the teardown the gate held.
	fw.it("asks once a consumer has registrations to hand back", function()
		ClearAll()
		Zone("party")
		Combat(false)
		personalSound:Apply(requests)
		healerSound:Refresh(healers)

		local group = Asked(function()
			personalSound:Apply({})
		end)

		db.Modules.HealerCrowdControl.Sound.Enabled = false

		local healer = Asked(function()
			healerSound:Refresh(healers)
		end)

		db.Modules.HealerCrowdControl.Sound.Enabled = true

		Zone("raid")
		Combat(false)
		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = true
		alertsSound:RefreshAllySounds()
		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = false

		local ally = Asked(function()
			alertsSound:RefreshAllySounds()
		end)

		Zone("raid")
		Combat(false)
		alertsSound:RemoveAllySounds()
		AddPlate("nameplate1")
		alertsModule:RefreshSounds()
		env.setModuleEnabled("Alerts", false)

		local alert = Asked(function()
			SoundRefresh()
		end)

		env.setModuleEnabled("Alerts", true)
		RemovePlate("nameplate1")

		assert(group, "the group whose sounds were switched off keeps them all pull")
		assert(healer, "and so does the healer")
		assert(ally, "and so do the ally announcements")
		assert(alert, "and so does the plate")
	end)

	-- The recovery costs a pass over three modules, and the predicate is asked all pull whatever
	-- the player has switched on, so nothing may ask for one on a profile with the sounds off.
	fw.it("stays quiet for a player with nothing to register", function()
		ClearAll()
		db.Modules.Alerts.Sound.Important.Enabled = false
		db.Modules.Alerts.TTS.EnemyDebuff.Enabled = false
		db.Modules.HealerCrowdControl.Sound.Enabled = false

		local group = Asked(function()
			personalSound:Apply({})
		end)
		local healer = Asked(function()
			healerSound:Refresh(healers)
		end)
		local alert = Asked(function()
			SoundRefresh()
		end)

		db.Modules.Alerts.Sound.Important.Enabled = true
		db.Modules.HealerCrowdControl.Sound.Enabled = true

		assert(not group, "no group wanted a sound")
		assert(not healer, "the healer sound is switched off")
		assert(not alert, "and so is every alert sound")
	end)
end)
