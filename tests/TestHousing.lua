-- Drives the whole addon's housing events against the shared mocked client.
--
-- Runs beside TestSmoke.lua at the end of the suite: the shared mock replaces the WoW globals
-- the narrower helpers install.

local fw = require("TestFramework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

local inHousing = false

---Loads the addon with a housing API present. C_Housing is stubbed between the load and the
---login because the addon feature-detects it when it registers its events, which is
---ADDON_LOADED rather than file load.
---@return table context
local function LoadWithHousing()
	local context = harness.Load("MiniAuras")

	_G.C_Housing = {
		IsOnNeighborhoodMap = function()
			return false
		end,
		IsInsideHouseOrPlot = function()
			return inHousing
		end,
	}

	harness.Login(context)

	return context
end

fw.describe("MiniAuras - housing", function()
	local refreshes = 0

	fw.it("ignores a plot event that left the housing state where it was", function()
		inHousing = false

		local context = LoadWithHousing()
		local addon = context.Addon
		local refresh = addon.Refresh

		addon.Refresh = function(self)
			refreshes = refreshes + 1
			return refresh(self)
		end

		-- What a /reload spent outside housing delivers: an exit from a plot nobody was on.
		WowMock.FireEvent("HOUSE_PLOT_EXITED")
		WowMock.RunTimers()

		fw.eq(refreshes, 0, "refreshes after a redundant exit")
	end)

	fw.it("refreshes once when the player actually enters", function()
		inHousing = true

		WowMock.FireEvent("HOUSE_PLOT_ENTERED")
		WowMock.FireEvent("HOUSE_PLOT_ENTERED")
		WowMock.RunTimers()

		fw.eq(refreshes, 1, "refreshes after entering")
	end)

	fw.it("refreshes again on the way out", function()
		inHousing = false

		WowMock.FireEvent("HOUSE_PLOT_EXITED")
		WowMock.RunTimers()

		fw.eq(refreshes, 2, "refreshes after leaving")

		_G.C_Housing = nil
	end)
end)
