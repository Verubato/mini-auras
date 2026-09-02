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

fw.describe("MiniAuras - a sound registration the pull refused", function()
	local auraSounds = addon.Core.AuraSounds
	local db = addon.Framework:GetSavedVars()
	local reconciles = 0

	-- Derived rather than listed, so a module that grows a sound recovery is counted here without
	-- anyone having to remember this test.
	local soundModules = {}

	for _, module in pairs(addon.Modules) do
		if type(module) == "table" and type(module.RefreshSounds) == "function" then
			soundModules[#soundModules + 1] = module
		end
	end

	assert(#soundModules > 0, "some module redoes its sound registrations")

	for _, module in ipairs(soundModules) do
		local realRefreshSounds = module.RefreshSounds

		module.RefreshSounds = function(self)
			reconciles = reconciles + 1

			return realRefreshSounds(self)
		end
	end

	---Ends a pull and reports what it cost in sound reconciles and in full refreshes.
	---@return number reconciles
	---@return number refreshes
	local function EndOfPull()
		local before = reconciles
		local refreshed = Cost("PLAYER_REGEN_ENABLED")

		return reconciles - before, refreshed
	end

	fw.it("reconciles every sound module when combat ends", function()
		-- Whatever the events above left on the record, so only this pull is measured.
		EndOfPull()
		auraSounds:NoteSkipped()

		local reconciled, refreshed = EndOfPull()

		fw.eq(reconciled, #soundModules, "each sound module redoes its own registrations")
		fw.eq(refreshed, 0, "and none of it costs a full refresh")
	end)

	fw.it("costs nothing when the pull refused none", function()
		local reconciled, refreshed = EndOfPull()

		fw.eq(reconciled, 0, "sound modules asked for a pull with nothing to redo")
		fw.eq(refreshed, 0, "and no full refresh either")
	end)

	-- The recovery reaches every one of them whatever the player runs, so it has to be safe on a
	-- module whose lifecycle never set anything up.
	fw.it("does nothing while every sound module is switched off", function()
		local alerts = db.Modules.Alerts.Enabled
		local healers = db.Modules.HealerCrowdControl.Enabled
		local savedGroups = db.Modules.PersonalAuras.Groups
		local wasAlerts = { Always = alerts.Always, World = alerts.World }
		local wasHealers = { Always = healers.Always, World = healers.World }

		alerts.Always, alerts.World = false, false
		healers.Always, healers.World = false, false
		-- No module-wide switch on personal auras; no groups is what switches them off.
		db.Modules.PersonalAuras.Groups = {}
		addon:Refresh()

		local printed = #WowMock.State.Prints

		auraSounds:NoteSkipped()

		local reconciled, refreshed = EndOfPull()

		alerts.Always, alerts.World = wasAlerts.Always, wasAlerts.World
		healers.Always, healers.World = wasHealers.Always, wasHealers.World
		db.Modules.PersonalAuras.Groups = savedGroups
		addon:Refresh()

		fw.eq(reconciled, #soundModules, "each module is still asked")
		fw.eq(refreshed, 0, "without a full refresh")
		fw.eq(#WowMock.State.Prints, printed, "and none of them said anything")
	end)
end)
