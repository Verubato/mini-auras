-- The test preview honouring the "Enable in" flags. Each panel's tabs pick which context the
-- preview stands for, so pressing Test on the Raids/Battlegrounds tab from the open world must
-- draw what a raid or battleground would draw: nothing, when the module is off for both.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local addon = env.addon

env.setModuleEnabled("CrowdControl", true)
env.setModuleEnabled("PetCrowdControl", false)
db.Modules.CrowdControl.Enabled.Always = false

env.addUnitFrame("party1", "CUF_Preview1")
env.addUnitFrame("party2", "CUF_Preview2")

env.loadModule("src/Modules/CrowdControl/Display.lua")
env.loadModule("src/Modules/CrowdControl/Module.lua")

local module = addon.Modules.CrowdControlModule
local testSpells = addon.Core.TestSpells
local instanceOptions = addon.Core.InstanceOptions

module:Init()

-- The preview draws through TestSpells:FillContainer, so a call count is what reached the screen.
local drawn = 0
local originalFill = testSpells.FillContainer

testSpells.FillContainer = function(self, container, spells, startSlot, fillOptions)
	drawn = drawn + 1

	return originalFill(self, container, spells, startSlot, fillOptions)
end

---@param isRaid boolean What the tab the user is on stands for.
---@return number icons drawn
local function Preview(isRaid)
	module:StopTesting()
	instanceOptions:SetTestIsRaid(isRaid)
	drawn = 0
	module:StartTesting()

	return drawn
end

fw.describe("CrowdControlModule - the test preview and the enable flags", function()
	fw.before_each(function()
		module:StopTesting()
		instanceOptions:SetTestIsRaid(nil)

		env.inInstance = false
		env.instanceType = "none"
		env.isRaid = false
		env.invalidateWorldState()

		local enabled = db.Modules.CrowdControl.Enabled
		enabled.World = true
		enabled.Arena = true
		enabled.Dungeons = true
		enabled.Raid = true
		enabled.BattleGrounds = true
	end)

	fw.it("draws both tabs while the module is on everywhere", function()
		assert(Preview(false) > 0, "the world/arena/dungeons tab")
		assert(Preview(true) > 0, "the raids/battlegrounds tab")
	end)

	fw.it("draws nothing on the raid tab while raids are off", function()
		db.Modules.CrowdControl.Enabled.Raid = false

		assert(Preview(true) == 0, "the previewed context is off")
		assert(Preview(false) > 0, "the other tab is untouched")
	end)

	-- A dungeons-only module previewed from the open world: the tab it sits on covers dungeons,
	-- but the player is in the world, and the world is where the preview draws.
	fw.it("never borrows a context the player is not in", function()
		db.Modules.CrowdControl.Enabled.World = false
		db.Modules.CrowdControl.Enabled.Arena = false

		assert(Preview(false) == 0, "dungeons being on does not carry the world")
	end)

	fw.it("keeps the zone's own answer on both tabs", function()
		env.inInstance = true
		env.instanceType = "pvp"
		env.invalidateWorldState()
		db.Modules.CrowdControl.Enabled.BattleGrounds = false

		assert(Preview(false) == 0, "a battleground reads the battleground flag")
		assert(Preview(true) == 0, "whichever tab is up")
	end)
end)
