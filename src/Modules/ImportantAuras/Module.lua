---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local unitStatePoller = addon.Core.UnitStatePoller

-- Loaded before this file in TOC order.
local display = addon.Modules.ImportantAuras.Display

---@class ImportantAurasModule : IModule
local M = {}
addon.Modules.ImportantAuras.Module = M
addon.Modules.ImportantAurasModule = M

---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local rosterGate
---@type table?
local eventsFrame
local testModeActive = false
---@type UnitStatePollerSubscriber?
local stateSub
-- Scratch for the watched units handed to the unit state poller each refresh.
local stateUnitsScratch = {}
local QueueRefresh = moduleUtil:Coalesced(function()
	M:Refresh()
end)

---Hands the poller the units on screen right now. Re-seeded per refresh rather than tracked per
---frame, because the frames retarget constantly and a baseline for a unit nobody is watching would
---fire a refresh for nothing.
local function SeedStateBaselines()
	if not stateSub then
		return
	end

	stateSub:ClearAll()

	for _, unit in ipairs(display:CollectWatchedUnits(stateUnitsScratch)) do
		stateSub:Seed(unit)
	end
end

local function OnEvent(_, event, unit)
	if event == "GROUP_ROSTER_UPDATE" or event == "LOADING_SCREEN_DISABLED" then
		-- The screen ending is what makes the frames readable: nothing is built while one is up,
		-- so this is the pass that builds what the world-entering pass had to skip.
		QueueRefresh()
	elseif event == "UNIT_FACTION" then
		-- Mind control hands a friendly frame an enemy unit, which decides whether the engine
		-- honours the spell-id filter at all. Filtered hard: this also fires on every PvP flag
		-- change in the open world, and the answer has usually not moved.
		if unit and display:ReapplyUnitGates(unit) then
			M:Refresh()
		end
	end
end

---@return ImportantAurasInstanceOptions?
local function GetOptions()
	return display:GetOptions()
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.ImportantAuras)
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

local function Setup()
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	-- Registered by the Refresh gate while the module is enabled.
	rosterGate = eventGate:New(eventsFrame,
		{ "GROUP_ROSTER_UPDATE", "UNIT_FACTION", "LOADING_SCREEN_DISABLED" })

	-- A duel flips a party member to hostile with no event of its own, and that decides whether the
	-- spell-id filter applies at all, so the budgets have to be recomputed when it happens.
	-- Registered for the module's lifetime, with the predicate below gating it.
	-- Per token rather than a module refresh, since the icon counts are all a flip moves.
	stateSub = unitStatePoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.ImportantAuras)
	end, function(unitToken)
		display:ReapplyUnitGates(unitToken)
	end)

	frames:InstallUnitFrameHooks(eventsFrame, {
		OnSetUnit = function(frame, unit)
			display:OnCufSetUnit(frame, unit)
			-- A watcher born or re-pointed here is unknown to the unit state poller until a refresh
			-- reseeds the baselines; without one, a later visible-world flip goes unnoticed.
			QueueRefresh()
		end,
		OnUpdateVisible = function(frame)
			display:OnCufUpdateVisible(frame)
		end,
		-- Shares the roster queue, so a join that also drives a sort refreshes once.
		OnSorted = QueueRefresh,
		OnVisibilityChanged = function()
			if IsEnabled() then
				display:EnsureWatchers()
				-- Same as OnSetUnit: the watchers just ensured need their baselines seeded.
				QueueRefresh()
			end
		end,
	})
end

-- Events stay unregistered while disabled. The addon-wide Refresh is what brings the module back.
local function OnEnable()
	rosterGate:SetActive(true)
end

local function OnDisable()
	rosterGate:SetActive(false)
	display:Teardown()
end

---@param options ImportantAurasInstanceOptions
local function Apply(options)
	display:EnsureFrames()
	display:ApplyOptions(options)
	UpdateContent()
	SeedStateBaselines()
	-- After the frames on screen have been served: a spare is only worth building for a frame that
	-- is not there yet, and EnsureFrames is what settles how many of those there are.
	display:QueuePrewarm()
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	lifecycle:Refresh()
end

function M:Init()
	display:Init()

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		IsEnabled = IsEnabled,
		Setup = Setup,
		OnEnable = OnEnable,
		OnDisable = OnDisable,
		Apply = Apply,
	})

	-- The hooks armed above have nothing to attach to without the watchers.
	if lifecycle:ArmEarly() then
		display:EnsureWatchers()
	end
end

---@class ImportantAurasModule
---@field Init fun(self: ImportantAurasModule)
---@field Refresh fun(self: ImportantAurasModule)
---@field StartTesting fun(self: ImportantAurasModule)
---@field StopTesting fun(self: ImportantAurasModule)

