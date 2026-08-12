---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local eventGate = addon.Core.EventGate
local duelPoller = addon.Core.DuelPoller

-- Loaded before this file in TOC order.
local display = addon.Modules.RaidFrameAuras.Display

---@class RaidFrameAurasModule : IModule
local M = {}
addon.Modules.RaidFrameAuras.Module = M
addon.Modules.RaidFrameAurasModule = M

---@type EventGate?
local rosterGate
---@type table?
local eventsFrame
local testModeActive = false
---@type DuelPollerSubscriber?
local duelSub
-- Scratch for the watched units handed to the duel poller each refresh.
local duelUnitsScratch = {}

---Hands the poller the units on screen right now. Re-seeded per refresh rather than tracked
---per frame: the frames retarget constantly (sorting, roster changes), and a baseline for a unit
---nobody is watching would fire a refresh for nothing.
local function SeedDuelBaselines()
	if not duelSub then
		return
	end

	duelSub:ClearAll()

	for _, unit in ipairs(display:CollectWatchedUnits(duelUnitsScratch)) do
		duelSub:Seed(unit)
	end
end

local function OnFrameSortSorted()
	M:Refresh()
end

local function OnEvent(_, event, unit)
	if event == "GROUP_ROSTER_UPDATE" then
		C_Timer.After(0, function()
			M:Refresh()
		end)
	elseif event == "UNIT_FACTION" then
		-- Mind control hands a friendly frame an enemy unit, which decides whether the engine
		-- honours the spell-id filter at all. Filtered hard: this also fires on every PvP flag
		-- change in the open world, and the answer has usually not moved.
		if unit and display:OnUnitFactionChanged(unit) then
			M:Refresh()
		end
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

-- Live auras are pushed in by the aura containers, so only the fake ones rebuild here.
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

	-- Repopulate the kick icons the test-mode reset wiped.
	if not active then
		display:RefreshKickIcons()
	end
end

local function CreateEvents()
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	-- Registered by the Refresh gate while the module is enabled.
	rosterGate = eventGate:New(eventsFrame, { "GROUP_ROSTER_UPDATE", "UNIT_FACTION" })

	-- A duel flips a party member to hostile with no event of its own, and that decides whether
	-- the spell-id filter applies at all, so the budgets have to be recomputed when it happens.
	-- Registered for the module's lifetime; the predicate below gates it.
	duelSub = duelPoller:Register(function()
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
	SeedDuelBaselines()
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

