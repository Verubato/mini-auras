---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local wowEx = addon.Utils.WoWEx
local eventGate = addon.Core.EventGate
local duelPoller = addon.Core.DuelPoller

-- Loaded before this file in TOC order.
local display = addon.Modules.RaidFrameAuras.Display

---@class RaidFrameAurasModule : IModule
local M = {}
addon.Modules.RaidFrameAuras.Module = M
addon.Modules.RaidFrameAurasModule = M

-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type EventGate?
local rosterGate
---@type table?
local eventsFrame
local testModeActive = false

local function OnFrameSortSorted()
	M:Refresh()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		C_Timer.After(0, function()
			M:Refresh()
		end)
	end
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.RaidFrameAuras)
end

---@param active boolean
local function SetEventsActive(active)
	-- Events stay unregistered while disabled; the addon-wide Refresh (config, world
	-- change, raid flip) re-runs this gate.
	rosterGate:SetActive(active)
end

-- Live auras are pushed in by the watchers/containers, so only the fake ones rebuild here.
local function UpdateContent()
	if testModeActive then
		display:RefreshTestIcons()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)

	if active then
		display:SetPaused(true)
	else
		display:ResetAllContainers()
		display:SetPaused(false)
	end

	M:Refresh()

	-- 12.1: repopulate the kick icons the test-mode reset wiped.
	if not active and USE_AURA_CONTAINERS then
		display:RefreshKickIcons()
	end
end

local function CreateEvents()
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	-- Registered by the Refresh gate while the module is enabled.
	rosterGate = eventGate:New(eventsFrame, { "GROUP_ROSTER_UPDATE" })

	-- A duel flips a party member to hostile with no event of its own, and that decides whether
	-- the spell-id filter applies at all, so the budgets have to be recomputed when it happens.
	-- Registered for the module's lifetime; the predicate below gates it.
	duelPoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.RaidFrameAuras)
	end, function()
		M:Refresh()
	end)
end

local function InstallHooks()
	frames:InstallUnitFrameHooks(eventsFrame, {
		OnSetUnit = function(frame, unit)
			display:OnCufSetUnit(frame, unit)
		end,
		OnUpdateVisible = function(frame)
			display:OnCufUpdateVisible(frame)
		end,
		OnSorted = OnFrameSortSorted,
		OnVisibilityChanged = function()
			if IsEnabled() then
				display:EnsureWatchers()
			end
		end,
	})
end

local function ApplyInitialState()
	if IsEnabled() then
		display:EnsureWatchers()
	end
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	local options = display:GetOptions()

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		display:Teardown()
		return
	end

	display:EnsureFrames()
	display:ApplyOptions(options)
	UpdateContent()
end

function M:Init()
	display:Init()
	CreateEvents()
	InstallHooks()
	ApplyInitialState()
end

---@class RaidFrameAurasModule
---@field Init fun(self: RaidFrameAurasModule)
---@field Refresh fun(self: RaidFrameAurasModule)
---@field StartTesting fun(self: RaidFrameAurasModule)
---@field StopTesting fun(self: RaidFrameAurasModule)

