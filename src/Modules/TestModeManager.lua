---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local frames = addon.Core.Frames
local instanceOptions = addon.Core.InstanceOptions
local ccModule = addon.Modules.CcModule
local healerCcModule = addon.Modules.HealerCcModule
local portraitModule = addon.Modules.PortraitModule
local alertsModule = addon.Modules.AlertsModule
local nameplateModule = addon.Modules.NameplatesModule
local kickTimerModule = addon.Modules.KickTimerModule
local trinketsModule = addon.Modules.TrinketsModule
---@type Db
local db
local enabled = false

---@class TestModeManager
local M = {}
addon.Modules.TestModeManager = M

function M:IsEnabled()
	return enabled
end

---@param options InstanceOptions?
function M:Enable(options)
	enabled = true
	instanceOptions:SetTestInstanceOptions(options)
end

function M:Disable()
	enabled = false
end

---@param options InstanceOptions?
function M:SetOptions(options)
	instanceOptions:SetTestInstanceOptions(options)
end

function M:Hide()
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
end

function M:Show()
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

	-- CC Module
	local testOptions = instanceOptions:GetTestInstanceOptions()
	if testOptions and testOptions.Enabled then
		ccModule:StartTesting()
	else
		ccModule:StopTesting()
	end

	-- Healer CC Module
	if db.Healer.Enabled then
		healerCcModule:StartTesting()
	else
		healerCcModule:StopTesting()
	end

	-- Portrait Module
	if db.Portrait.Enabled then
		portraitModule:StartTesting()
	else
		portraitModule:StopTesting()
	end

	-- Alerts Module
	if db.Alerts.Enabled then
		alertsModule:StartTesting()
	else
		alertsModule:StopTesting()
	end

	-- Nameplates Module
	local anyNameplateEnabled = db.Nameplates.Friendly.CC.Enabled
		or db.Nameplates.Friendly.Important.Enabled
		or db.Nameplates.Friendly.Combined.Enabled
		or db.Nameplates.Enemy.CC.Enabled
		or db.Nameplates.Enemy.Important.Enabled
		or db.Nameplates.Enemy.Combined.Enabled

	if anyNameplateEnabled then
		nameplateModule:StartTesting()
	else
		nameplateModule:StopTesting()
	end

	-- Kick Timer Module
	if kickTimerModule:IsEnabledForPlayer(db.KickTimer) then
		kickTimerModule:StartTesting()
	else
		kickTimerModule:StopTesting()
	end

	-- Trinkets Module
	if db.Trinkets and db.Trinkets.Enabled then
		trinketsModule:StartTesting()
	else
		trinketsModule:StopTesting()
	end
end

function M:Init()
	db = mini:GetSavedVars()
end

---@class TestSpell
---@field SpellId number
---@field DispelColor table
