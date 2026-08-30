-- The events the addon's own file listens for, driven against the shared mocked client. Two of
-- them only record what the modules read back later, and the other two refresh the lot.

local fw = require("TestFramework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

local context = harness.Run("MiniAuras")
local addon = context.Addon

local refreshes = 0
local realRefresh = addon.Refresh

addon.Refresh = function(self)
	refreshes = refreshes + 1

	return realRefresh(self)
end

---Fires one event at the addon and reports what it cost in full refreshes.
---@param event string
---@param ... any
---@return number
local function Cost(event, ...)
	local before = refreshes

	WowMock.FireEvent(event, ...)
	WowMock.RunTimers()

	return refreshes - before
end

fw.describe("MiniAuras - the loading screen", function()
	fw.it("takes a screen it was never told about as up", function()
		-- Nothing announces the screen the addon loaded behind, so the modules that build only
		-- while one is up would otherwise never get their free window.
		fw.truthy(addon:IsLoadingScreenUp(), "a session with no screen event yet")
	end)

	fw.it("clears when the screen lifts", function()
		WowMock.FireEvent("LOADING_SCREEN_DISABLED")

		fw.falsy(addon:IsLoadingScreenUp(), "the world is on screen now")
	end)

	fw.it("puts it back up on the way to the next zone", function()
		WowMock.FireEvent("LOADING_SCREEN_ENABLED")

		fw.truthy(addon:IsLoadingScreenUp(), "another zone is loading")

		WowMock.FireEvent("LOADING_SCREEN_DISABLED")
	end)
end)

fw.describe("MiniAuras - the roster and the player's spec", function()
	fw.it("refreshes when the group turns into a raid", function()
		WowMock.State.InRaid = true

		fw.eq(Cost("GROUP_ROSTER_UPDATE"), 1, "refreshes for the flip")
	end)

	fw.it("ignores a roster message that left it a raid", function()
		WowMock.State.InRaid = true
		-- The flip already happened, so only the message after this one is measured.
		Cost("GROUP_ROSTER_UPDATE")

		-- One of these arrives per member joining, and every module's gate is re-read on a refresh.
		fw.eq(Cost("GROUP_ROSTER_UPDATE"), 0, "refreshes for a roster that did not flip")
	end)

	fw.it("refreshes again on the way back out of a raid", function()
		WowMock.State.InRaid = true
		Cost("GROUP_ROSTER_UPDATE")

		WowMock.State.InRaid = false

		fw.eq(Cost("GROUP_ROSTER_UPDATE"), 1, "refreshes for the flip back")
	end)

	fw.it("refreshes on the player's own respec", function()
		fw.eq(Cost("PLAYER_SPECIALIZATION_CHANGED", "player"), 1, "refreshes for the player")
	end)

	fw.it("ignores somebody else's", function()
		fw.eq(Cost("PLAYER_SPECIALIZATION_CHANGED", "party1"), 0, "refreshes for a group member")
	end)
end)
