-- On 12.1 GetArenaOpponentSpec answers with a secret number, so the facade must never ask it.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

_G.GetArenaOpponentSpec = function()
	error("GetArenaOpponentSpec must not be called")
end

local addon = {
	Core = {
		Inspector = {
			GetUnitSpecId = function()
				return nil
			end,
		},
	},
}

assert(loadfile("src/Core/Inspect/InspectorFacade.lua"))("MiniAuras", addon)

local facade = addon.Core.InspectorFacade

fw.describe("InspectorFacade - arena units", function()
	fw.it("does not read arena opponent specs", function()
		assert(facade:GetUnitSpecId("arena1") == nil, "an arena unit has no spec to report")
	end)
end)
