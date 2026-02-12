---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local instanceOptions = addon.Core.InstanceOptions
local ccModule = addon.Modules.CcModule
local healerCcModule = addon.Modules.HealerCcModule
local portraitModule = addon.Modules.PortraitModule
local alertsModule = addon.Modules.AlertsModule
local nameplateModule = addon.Modules.NameplatesModule
local kickTimerModule = addon.Modules.KickTimerModule
local trinketsModule = addon.Modules.TrinketsModule
local allyIndicatorModule = addon.Modules.AllyIndicatorModule
local active = false

---@class TestModeManager
local M = {}
addon.Modules.TestModeManager = M

function M:IsActive()
	return active
end

function M:StopTesting()
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
	ccModule:StopTesting()
	healerCcModule:StopTesting()
	portraitModule:StopTesting()
	alertsModule:StopTesting()
	nameplateModule:StopTesting()
	kickTimerModule:StopTesting()
	trinketsModule:StopTesting()
	allyIndicatorModule:StopTesting()

	active = false
end

---@param options InstanceOptions?
function M:StartTesting(options)
	if active then
		return
	end

	active = true

	if not options then
		options = instanceOptions:GetTestInstanceOptions()
	else
		instanceOptions:SetTestInstanceOptions(options)
	end
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

	ccModule:StartTesting()
	healerCcModule:StartTesting()
	portraitModule:StartTesting()
	alertsModule:StartTesting()
	nameplateModule:StartTesting()
	kickTimerModule:StartTesting()
	trinketsModule:StartTesting()
	allyIndicatorModule:StartTesting()
end

function M:Init() end

---@class TestSpell
---@field SpellId number
---@field DispelColor table
