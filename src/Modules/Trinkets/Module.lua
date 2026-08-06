---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx
local trinketsTracker = addon.Core.TrinketsTracker
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local display = addon.Modules.Trinkets.Display

---@class TrinketsModule : IModule
local M = {}
addon.Modules.Trinkets.Module = M
addon.Modules.TrinketsModule = M

-- 12.1 only: on older clients the friendly cooldown tracker renders the trinket slot
-- itself; this standalone module replaces that surviving slice on 12.1 (trinket data is
-- C_PvP-based, not aura-based, so it survives the aura lockdown).
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

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

---Trinket tracking reads the 12.1 trinket API and has no legacy equivalent.
---@return boolean
local function IsSupported()
	return USE_AURA_CONTAINERS
end

---@return TrinketsModuleOptions?
local function GetOptions()
	if not IsSupported() then
		return nil
	end

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
	if not IsSupported() then
		return
	end

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
	if not IsSupported() then
		return
	end

	display:Init()
	InstallHooks()
	ApplyInitialState()
end
