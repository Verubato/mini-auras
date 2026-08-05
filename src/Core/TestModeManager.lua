---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local instanceOptions = addon.Core.InstanceOptions
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
	"AurasModule",
	"PrecogModule",
	"TrinketsModule",
	"FriendlyCooldownTrackerModule",
	"EnemyCooldownTrackerModule",
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

	-- Hide test party frames
	local testPartyFrames = frames:GetTestFrames()
	if testPartyFrames then
		for _, frame in ipairs(testPartyFrames) do
			frame:Hide()
		end
	end

	local testFramesContainer = frames:GetTestFrameContainer()
	if testFramesContainer then
		testFramesContainer:Hide()
	end

	-- Stop all module test modes
	for _, module in ipairs(testModules) do
		module:StopTesting()
	end

	active = false
end

---@param isRaid boolean?
function M:StartTesting(isRaid)
	if active then
		return
	end

	active = true

	instanceOptions:SetTestIsRaid(isRaid)

	-- Show test party frames if no real frames are visible
	local realFrames = frames:GetAll(true, false) -- Get only real frames
	local hasVisibleRealFrames = false

	for _, frame in ipairs(realFrames) do
		if frame:IsVisible() then
			hasVisibleRealFrames = true
			break
		end
	end

	if not hasVisibleRealFrames then
		-- Show test party frames
		local testPartyFrames = frames:GetTestFrames()
		if testPartyFrames then
			for _, frame in ipairs(testPartyFrames) do
				frame:Show()
			end
		end

		local testFramesContainer = frames:GetTestFrameContainer()
		if testFramesContainer then
			testFramesContainer:Show()
		end
	end

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
