-- Tests that the Classic-only importants fold in on the 1.x client and nowhere else.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
local wow = require("WowApi")

local env = moduleEnv.build()

local COMBUSTION = 11129
local ICE_BARRIER = 11426

---The id lists as the file builds them on a client reporting `buildNumber`.
---@param buildNumber number
---@return table
local function LoadWith(buildNumber)
	local target = { Core = {}, Utils = { WoWEx = env.addon.Utils.WoWEx } }

	wow.setBuildNumber(buildNumber)

	local ok, err = pcall(assert(loadfile("src/Core/Auras/AuraCategoryIds.lua")), "MiniAuras", target)

	wow.setBuildNumber(120100)
	assert(ok, err)

	return target.Core.AuraCategoryIds
end

fw.describe("AuraCategoryIds - the Classic importants", function()
	fw.it("stay out of the retail lists", function()
		local retail = LoadWith(120100)

		assert(retail.ClassicImportant[COMBUSTION] == "MAGE", "the list itself is always there")
		assert(not retail.UnflaggedImportant[COMBUSTION], "but retail does not track it")
		assert(not retail.Unflagged[COMBUSTION], "so the picker never offers it")
		assert(retail.UnflaggedDefensive[ICE_BARRIER], "and a shared id keeps its retail filing")
		assert(retail.DefaultOff[ICE_BARRIER], "off by default included")
	end)

	fw.it("fold into the importants on the 1.x client", function()
		local classic = LoadWith(16001)

		for spellId, class in pairs(classic.ClassicImportant) do
			assert(classic.UnflaggedImportant[spellId], spellId .. " is tracked as important")
			assert(classic.Unflagged[spellId], spellId .. " reaches the picker")
			assert(classic.Classes[spellId] == class, spellId .. " sits under its class")
			assert(not classic.DefaultOff[spellId], spellId .. " ships on")
			assert(not classic.UnflaggedDefensive[spellId], spellId .. " is filed once")
		end
	end)
end)
