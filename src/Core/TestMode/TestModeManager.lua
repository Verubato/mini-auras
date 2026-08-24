---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local instanceOptions = addon.Core.InstanceOptions
local moduleUtil = addon.Utils.ModuleUtil
local positionEditor = addon.Core.PositionEditor
-- Filled in Init rather than at file scope: capturing the module tables here would tie this
-- file's TOC position to being after every module, and a miss would land as a silent nil in
-- the list rather than an error. Init runs after every module's, so the names all resolve.
local MODULE_NAMES = {
	"CrowdControlModule",
	"HealerCrowdControlModule",
	"PortraitModule",
	"AlertsModule",
	"NameplatesModule",
	"EnemyKickTrackerModule",
	"AllyKickTrackerModule",
	"ImportantAurasModule",
	"FrameAurasModule",
	"PersonalAurasModule",
	"TrinketsModule",
}
---@type IModule[]
local testModules = {}
local active = false

---@class TestModeManager
local M = {}
addon.Core.TestModeManager = M

function M:IsActive()
	return active
end

function M:StopTesting()
	instanceOptions:SetTestIsRaid(nil)

	-- Nothing is draggable once the stand-ins go, so the editor has nothing left to write to.
	positionEditor:Close()

	frames:SetTestFramesShown(false)
	frames:SetTestArenaFramesShown(false)

	for _, module in ipairs(testModules) do
		module:StopTesting()
	end

	-- One sweep instead of per-module clears: display modules only show captions on their test
	-- paths, and everything they showed goes away here.
	moduleUtil:HideAllTestLabels()

	active = false
end

---@param isRaid boolean?
function M:StartTesting(isRaid)
	if active then
		return
	end

	active = true

	instanceOptions:SetTestIsRaid(isRaid)

	-- Stand-ins only where there is nothing real to anchor to, so testing in a group or an arena
	-- shows the icons where they will actually be.
	frames:SetTestFramesShown(not frames:HasVisibleFrames())
	frames:SetTestArenaFramesShown(not frames:HasVisibleArenaFrames())

	for _, module in ipairs(testModules) do
		module:StartTesting()
	end
end

function M:Init()
	for _, name in ipairs(MODULE_NAMES) do
		testModules[#testModules + 1] = assert(addon.Modules[name], "no module " .. name)
	end
end

---@class TestSpell
---@field SpellId number
---@field DispelColor table?
