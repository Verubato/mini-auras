---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local unitStatePoller = addon.Core.UnitStatePoller

-- Loaded before this file in TOC order.
local sound   = addon.Modules.HealerCrowdControl.Sound
local display = addon.Modules.HealerCrowdControl.Display

---@class HealerCrowdControlModule : IModule
local M = {}
addon.Modules.HealerCrowdControl.Module = M
addon.Modules.HealerCrowdControlModule = M

---@type Db
local db
local testModeActive = false
local previousTestSoundEnabled = false
---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local rosterGate
---@type UnitStatePollerSubscriber?
local stateSub
-- Scratch for the watched healers handed to the unit state poller each refresh.
local stateUnitsScratch = {}
local QueueRefresh = moduleUtil:Coalesced(function()
	M:Refresh()
end)

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		QueueRefresh()
	end
end

---@return HealerCrowdControlModuleOptions?
local function GetOptions()
	return display:GetOptions()
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(ModuleName.HealerCrowdControl)
end

---Hands the poller the healers drawn right now. Re-seeded per refresh: the healer set changes
---with the roster, and a baseline for a healer nobody draws would fire a refresh for nothing.
local function SeedStateBaselines()
	if not stateSub then
		return
	end

	stateSub:ClearAll()

	for _, unit in ipairs(display:CollectWatchedUnits(stateUnitsScratch)) do
		stateSub:Seed(unit)
	end
end

---Live icons are driven by the aura containers; only the fake ones rebuild here.
---@param options HealerCrowdControlModuleOptions
local function UpdateContent(options)
	if not testModeActive then
		return
	end

	display:ShowAnchor()
	display:RefreshTestFrame()

	if previousTestSoundEnabled ~= options.Sound.Enabled and options.Sound.Enabled then
		-- The live sound is engine-side (AddAuraSound), so the preview plays the file directly.
		sound:PlayPreview(options)
	end

	previousTestSoundEnabled = options.Sound.Enabled
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)

	if not active then
		display:ResetIcons()
	end

	M:Refresh()
end

local function Setup()
	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	-- Registered by the Refresh gate while the module is enabled.
	rosterGate = eventGate:New(eventsFrame, { "GROUP_ROSTER_UPDATE" })

	-- A healer leaving or re-entering the player's visible world has no event, and it decides
	-- whether the engine evaluates the CC filter at all, so the budgets are recomputed when the
	-- poller sees it flip. Registered for the module's lifetime, with the predicate below gating it.
	-- Per token rather than a module refresh, since the icon count is all a flip moves.
	stateSub = unitStatePoller:Register(function()
		return IsEnabled()
	end, function(unitToken)
		display:ReapplyUnitGates(unitToken)
	end)
end

-- Events stay unregistered while disabled. The addon-wide Refresh brings the module back, and a
-- respec reaches it through the central spec-change driver.
local function OnEnable()
	rosterGate:SetActive(true)
end

local function OnDisable()
	display:Teardown()
	display:SetAnchorInteractive(false)
	rosterGate:SetActive(false)
end

---@param options HealerCrowdControlModuleOptions
local function Apply(options)
	display:EnsureFrames()
	display:ApplyOptions(options)
	UpdateContent(options)
	SeedStateBaselines()

	-- Owned here rather than by the test-mode toggle, so flipping the module switch while a
	-- test is running shows or hides the drag anchor and its caption with it.
	display:SetAnchorInteractive(testModeActive)
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
	previousTestSoundEnabled = db.Modules.HealerCrowdControl.Sound.Enabled

	sound:Init()
	display:Init()

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		IsEnabled = IsEnabled,
		Setup = Setup,
		OnEnable = OnEnable,
		OnDisable = OnDisable,
		Apply = Apply,
	})
end
