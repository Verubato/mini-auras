---@type string, Addon
local _, addon = ...
local trinketsTracker = addon.Core.TrinketsTracker
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local display = addon.Modules.Trinkets.Display

---@class TrinketsModule : IModule
local M = {}
addon.Modules.Trinkets.Module = M
addon.Modules.TrinketsModule = M

local eventFrame
local enabled = false
local paused = false

local function OnEvent(_, event)
	if paused then
		-- While paused, we still allow anchor rebuild + visibility so people can position frames
		display:RefreshAnchorsOnly()
		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		M:Refresh()
	elseif event == "GROUP_ROSTER_UPDATE" then
		-- for some reason it doesn't work right away
		C_Timer.After(0, function()
			M:Refresh()
		end)
	end
end

-- Trinket cooldown data changes arrive via TrinketsTracker (arena cooldown updates and
-- match-state transitions); this module only re-renders the affected slot.
local function OnTrinketDataChanged(unit)
	if not enabled or paused then
		return
	end

	display:Render(unit)
end

---@return TrinketsModuleOptions?
local function GetOptions()

	return display:GetOptions()
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Trinkets)
end

---Edge-triggered: the roster/world events are the module's only event source, so they are
---created on wake and torn down on sleep.
---@param active boolean
local function SetEventsActive(active)
	if active == enabled then
		return
	end

	enabled = active
	paused = not active

	if active then
		eventFrame = CreateFrame("Frame")
		eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
		eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
		eventFrame:SetScript("OnEvent", OnEvent)
	elseif eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame:SetScript("OnEvent", nil)
		eventFrame = nil
	end
end

---@param active boolean
local function SetTestMode(active)

	display:SetTestMode(active)

	if active then
		paused = true
	else
		display:ClearAll()
		paused = false
	end

	M:Refresh()
end

local function InstallHooks()
	trinketsTracker:RegisterCallback(OnTrinketDataChanged)
end

local function ApplyInitialState()
	M:Refresh()
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	local moduleOptions = GetOptions()

	if not moduleOptions then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		display:Teardown()
		return
	end

	display:EnsureFrames()
	display:ApplyOptions()
	display:UpdateContent()
end

function M:Init()

	display:Init()
	InstallHooks()
	ApplyInitialState()
end
