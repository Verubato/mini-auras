---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local scheduler = addon.Scheduler
local headerManager = addon.HeaderManager
local testModeManager = addon.TestModeManager
local healerManager = addon.HealerCcManager
local portraitManager = addon.PortraitManager
local eventsFrame
local db

local function IsFriendlyCuf(frame)
	if frame:IsForbidden() then
		return false
	end

	local name = frame:GetName()
	if not name then
		return false
	end

	return string.find(name, "CompactParty") ~= nil or string.find(name, "CompactRaid") ~= nil
end

local function OnCufUpdateVisible(frame)
	local headers = headerManager:GetHeaders()
	local header = headers[frame]

	if not header then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		local instanceOptions = headerManager:GetCurrentInstanceOptions()

		if not instanceOptions then
			return
		end

		headerManager:ShowHideHeader(header, frame, false, instanceOptions)
	end)
end

local function OnCufSetUnit(frame, unit)
	if not frame or not IsFriendlyCuf(frame) then
		return
	end

	if not unit then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		headerManager:EnsureHeader(frame, unit)
	end)
end

local function NotifyChanges()
	if db.NotifiedChanges then
		return
	end

	db.NotifiedChanges = true

	mini:ShowDialog({
		Title = "MiniCC - What's New?",
		Text = "'Healer in CC' feature is now available!'",
	})
end

local function OnFrameSortSorted()
	addon:Refresh()
end

local function OnEvent(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		if testModeManager:IsEnabled() then
			testModeManager:Disable()
			addon:Refresh()
		end
	end

	if event == "PLAYER_ENTERING_WORLD" then
		NotifyChanges()
		addon:Refresh()
	end

	if event == "GROUP_ROSTER_UPDATE" then
		addon:Refresh()
	end
end

local function OnAddonLoaded()
	addon.Config:Init()
	addon.Scheduler:Init()
	addon.Frames:Init()

	headerManager:Init()
	healerManager:Init()
	testModeManager:Init()
	portraitManager:Init()

	headerManager:RefreshInstanceOptions()
	headerManager:EnsureHeaders()
	healerManager:Refresh()

	db = mini:GetSavedVars()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

	if CompactUnitFrame_SetUnit then
		hooksecurefunc("CompactUnitFrame_SetUnit", OnCufSetUnit)
	end

	if CompactUnitFrame_UpdateVisible then
		hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
	end

	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(OnFrameSortSorted)
	end

	healerManager:Refresh()
end

function addon:Refresh()
	if InCombatLockdown() then
		scheduler:RunWhenCombatEnds(function()
			addon:Refresh()
		end, "Refresh")
		return
	end

	headerManager:RefreshInstanceOptions()
	headerManager:EnsureHeaders()
	healerManager:Refresh()
	headerManager:Refresh()

	if testModeManager:IsEnabled() then
		testModeManager:Show()
	else
		testModeManager:Hide()
	end
end

---@param options InstanceOptions?
function addon:ToggleTest(options)
	if testModeManager:IsEnabled() then
		testModeManager:Disable()
	else
		testModeManager:Enable(options)
	end

	addon:Refresh()

	if InCombatLockdown() then
		mini:Notify("Can't test during combat, we'll test once combat drops.")
	end
end

---@param options InstanceOptions?
function addon:TestOptions(options)
	testModeManager:SetOptions(options)

	if testModeManager:IsEnabled() then
		addon:Refresh()
	end
end

mini:WaitForAddonLoad(OnAddonLoaded)

---@class Addon
---@field Framework MiniFramework
---@field Capabilities Capabilities
---@field Config Config
---@field Frames FramesUtil
---@field Scheduler SchedulerUtil
---@field Units UnitUtil
---@field CcHeader CcHeader
---@field UnitAuraWatcher UnitAuraWatcher
---@field TestModeManager TestModeManager
---@field HeaderManager HeaderManager
---@field CcManager CcManager
---@field PortraitManager PortraitManager
---@field HealerCcManager HealerCcManager
---@field Refresh fun(self: table)
---@field ToggleTest fun(self: table, options: InstanceOptions)
---@field TestOptions fun(self: table, options: InstanceOptions)
---@field TestHealer fun(self: table)
