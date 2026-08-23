-- The raid frame auras preview. Test mode draws its own fake icons rather than waiting for real
-- auras, so a category with no test spells behind it is invisible in the preview no matter what
-- its option says: the bug this guards is Show Important reading as broken because ticking it
-- changed nothing on screen.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("ImportantAurasModule", true)

env.addUnitFrame("party1", "CUF_Test")

env.loadModule("src/Modules/ImportantAuras/Display.lua")
env.loadModule("src/Modules/ImportantAuras/Module.lua")

local module = env.addon.Modules.ImportantAurasModule
local testSpells = env.addon.Core.TestSpells
local options = db.Modules.ImportantAurasModule.Default

module:Init()

---The preview draws through TestSpells:FillContainer, once per category, with the slot budget
---the distribution gave it. Recording the calls says which categories reached the screen and
---how many icons each was allowed, which is exactly what the options control.
local drawn = {}
local originalFill = testSpells.FillContainer

testSpells.FillContainer = function(self, container, spells, startSlot, fillOptions)
	drawn[spells] = (drawn[spells] or 0) + (fillOptions.Count or #spells)

	return originalFill(self, container, spells, startSlot, fillOptions)
end

---@return table<table, number> icons drawn, keyed by the spell list they came from
local function Preview()
	module:StopTesting()

	for key in pairs(drawn) do
		drawn[key] = nil
	end

	module:StartTesting()

	return drawn
end

fw.describe("ImportantAurasModule - the test mode preview", function()
	fw.before_each(function()
		options.ShowCC = false
		options.ShowKicks = false
		options.ShowDefensives = true
		options.ShowImportant = true
		options.Icons.MaxIcons = 3
	end)

	fw.it("previews an important buff while the option is on", function()
		local icons = Preview()

		assert((icons[testSpells.Important] or 0) > 0, "Show Important must put an icon on screen")
		assert((icons[testSpells.Defensive] or 0) > 0, "and the defensives keep theirs")
	end)

	fw.it("drops the important icons when the option goes off", function()
		options.ShowImportant = false

		local icons = Preview()

		assert((icons[testSpells.Important] or 0) == 0, "nothing left of the category")
		assert((icons[testSpells.Defensive] or 0) > 0, "the other category is untouched")
	end)

	fw.it("gives every enabled category a slot when they cannot all fit", function()
		options.ShowCC = true

		local icons = Preview()

		assert((icons[testSpells.CrowdControl] or 0) > 0, "crowd control")
		assert((icons[testSpells.Defensive] or 0) > 0, "defensive")
		assert((icons[testSpells.Important] or 0) > 0, "important")
	end)
end)
