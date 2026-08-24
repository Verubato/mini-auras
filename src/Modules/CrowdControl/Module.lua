---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.Core.Frames
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local unitStatePoller = addon.Core.UnitStatePoller

-- Loaded before this file in TOC order.
local display = addon.Modules.CrowdControl.Display

---@class CrowdControlModule : IModule
local M = {}
addon.Modules.CrowdControl.Module = M
addon.Modules.CrowdControlModule = M

---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local rosterGate
---@type table?
local eventsFrame
---@type Db
local db
local testModeActive = false
---@type UnitStatePollerSubscriber?
local stateSub
-- Scratch for the watched units handed to the unit state poller each refresh.
local stateUnitsScratch = {}
-- Deferred as well as coalesced, because the frame addons rebuild on the same event and the
-- anchors are only worth reading once they have settled.
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

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" or event == "LOADING_SCREEN_DISABLED" then
		-- The screen ending is what makes the frames readable, so this is the pass that re-points
		-- the entries the layout put on frames that turned out to hold nobody.
		QueueRefresh()
	elseif event == "UNIT_PET" then
		-- A pet was summoned or dismissed, so refresh to show or hide the opt-in pet unit frame
		-- containers with it. Only relevant when IncludePetFrame is enabled.
		local petOptions = db.Modules.PetCrowdControl
		if petOptions and petOptions.IncludePetFrame and moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl) then
			QueueRefresh()
		end
	end
end

---@return CrowdControlInstanceOptions?
local function GetOptions()
	return display:GetOptions()
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.CrowdControl) or moduleUtil:IsModuleEnabled(moduleName.PetCrowdControl)
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
	-- Registered by the Refresh gate while either feature is on. UNIT_PET tracks the player's pet
	-- being summoned or dismissed, so the opt-in pet unit frame containers follow it whichever
	-- unit-frame addon owns that frame.
	rosterGate = eventGate:New(eventsFrame,
		{ "GROUP_ROSTER_UPDATE", "UNIT_PET", "LOADING_SCREEN_DISABLED" })

	-- A unit leaving or re-entering the player's visible world has no event, and it decides whether
	-- the engine evaluates the CC filter at all, so the budgets are recomputed when the poller sees
	-- it flip. Registered for the module's lifetime, with the predicate below gating it.
	-- Per token rather than a module refresh, since the icon count is all a flip moves.
	stateSub = unitStatePoller:Register(function()
		return IsEnabled()
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

-- Events stay unregistered while both features are off. The addon-wide Refresh is what brings the
-- module back.
local function OnEnable()
	rosterGate:SetActive(true)
end

local function OnDisable()
	rosterGate:SetActive(false)
	display:Teardown()
end

---@param options CrowdControlInstanceOptions
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
	db = mini:GetSavedVars()

	display:Init()

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		IsEnabled = IsEnabled,
		Setup = Setup,
		OnEnable = OnEnable,
		OnDisable = OnDisable,
		Apply = Apply,
	})

	-- Armed for either feature; the watchers are only for the one that had them before.
	if lifecycle:ArmEarly() and moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
		display:EnsureWatchers()
	end
end
