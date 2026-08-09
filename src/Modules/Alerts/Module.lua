---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local eventGate = addon.Core.EventGate
local duelPoller = addon.Core.DuelPoller
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local units = addon.Utils.Units

-- Loaded before this file in TOC order.
local sound    = addon.Modules.Alerts.Sound
local observer = addon.Modules.Alerts.Observer
local display  = addon.Modules.Alerts.Display

---@class AlertsModule : IModule
local M = {}
addon.Modules.Alerts.Module = M
addon.Modules.AlertsModule = M

-- Read by the tests, which derive the expected registration count from it.
M.SilentAlertSpellIds = sound.SilentAlertSpellIds

-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type Db
local db
local testModeActive = false
local paused = false
local pendingAuraUpdate = false
---@type EventGate?
local plateGate
-- Duel detection: no event fires when a friendly unit turns attackable at duel start (or back
-- at duel end), so the shared DuelPoller re-registers plates whose enemy status flips.
-- Baselines are seeded on plate add and cleared on plate remove.
---@type DuelPollerSubscriber
local duelSub
-- Reused enemy-token set for RebuildNameplateWatchers.
local activeTokensScratch = {}

local function OnAuraDataChanged()
	display:Render(observer:GetWatchers())
end

local function ScheduleAuraDataUpdate()
	if pendingAuraUpdate then
		return
	end
	pendingAuraUpdate = true
	C_Timer.After(0, function()
		pendingAuraUpdate = false
		OnAuraDataChanged()
	end)
end

---@param value boolean
local function SetPaused(value)
	paused = value
	display:SetPaused(value)
	sound:SetPaused(value)
end

local function OnMatchStateChanged()
	local matchState = C_PvP.GetActiveMatchState()
	local inPrepRoom = matchState == Enum.PvPMatchState.StartUp

	display:SetInPrepRoom(inPrepRoom)

	if USE_AURA_CONTAINERS then
		-- Prep-room garbage handling: RefreshNameplateDisplays hides the displays while
		-- inPrepRoom is set and re-shows them when the match starts.
		display:RefreshNameplateDisplays()
	end

	if not inPrepRoom then
		return
	end

	observer:ClearAllState()
	display:ResetBars()
end

local function OnNamePlateAdded(unitToken)
	-- Baseline for the duel poll, kept fresh on every (re)registration.
	local isEnemy = duelSub:Seed(unitToken)

	-- Only track enemy nameplates
	if not isEnemy then
		if USE_AURA_CONTAINERS then
			-- The token now belongs to a non-enemy (recycled plate or duel ending), so its warm
			-- sound registrations are dropped along with the display.
			sound:RemoveToken(unitToken)
			display:ReleaseNameplateDisplay(unitToken)
		end
		return
	end

	if USE_AURA_CONTAINERS then
		-- Configure only the new entry (styling every pooled pair per plate spawn adds up in
		-- busy fights); the chain re-anchor is cheap and covers the row shift.
		display:ApplyOneAndChain(unitToken)
		return
	end

	observer:Create(unitToken, ScheduleAuraDataUpdate)

	-- Initial update
	ScheduleAuraDataUpdate()
end

local function OnNamePlateRemoved(unitToken)
	duelSub:Clear(unitToken)

	if USE_AURA_CONTAINERS then
		display:ReleaseNameplateDisplay(unitToken)
		display:ChainDisplays()
		return
	end

	if observer:Dispose(unitToken) then
		ScheduleAuraDataUpdate()
	end
end

local function ClearNamePlateWatchers()
	if USE_AURA_CONTAINERS then
		display:ReleaseAllNameplateDisplays()
		return
	end

	observer:DisposeAll()
end

local function RebuildNameplateWatchers()
	-- Build a set of currently active enemy unit tokens
	local activeTokens = activeTokensScratch
	wipe(activeTokens)
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken
		if unitToken then
			-- Seed the duel-poll baseline here too: plates that existed before Init/enable
			-- never fire NAME_PLATE_UNIT_ADDED.
			if duelSub:Seed(unitToken) then
				activeTokens[unitToken] = true
			end
		end
	end

	if USE_AURA_CONTAINERS then
		display:SyncActiveTokens(activeTokens)
		return
	end

	observer:PruneTo(activeTokens)

	-- Add watchers for tokens we don't already track
	for unitToken in pairs(activeTokens) do
		if not observer:Get(unitToken) then
			OnNamePlateAdded(unitToken)
		end
	end
end

---@return AlertsModuleOptions?
local function GetOptions()
	-- The bars are built in Init; without them there is nothing to configure.
	if not db or not display:GetContainer() then
		return nil
	end

	return db.Modules.AlertsModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Alerts)
end

---Arena, battlegrounds, and the open world all read enemy nameplate watchers; nowhere else does.
---@param isEnabled boolean
---@return boolean
local function AreNameplatesNeeded(isEnabled)
	local inInstance, instanceType = IsInInstance()

	return isEnabled and (instanceType == "arena" or instanceType == "pvp" or not inInstance)
end

---@param active boolean
local function SetEventsActive(active)
	-- Plate events stay unregistered while inactive; ZONE_CHANGED_NEW_AREA and
	-- PVP_MATCH_STATE_CHANGED stay registered as they drive this gate.
	local nameplatesNeeded = AreNameplatesNeeded(active)

	if plateGate then
		plateGate:SetActive(nameplatesNeeded)
	end
end

local function Teardown()
	observer:DisableAll()

	if USE_AURA_CONTAINERS then
		display:ReleaseAllNameplateDisplays()
	end

	display:ResetBars()
end

local function EnsureFrames()
	if AreNameplatesNeeded(true) then
		RebuildNameplateWatchers()
	else
		ClearNamePlateWatchers()
	end

	-- TEMPORARY: legacy-only re-render. On 12.1 the containers render themselves and the
	-- scheduled Render call no-ops; dies with the 12.0 path.
	if not USE_AURA_CONTAINERS then
		ScheduleAuraDataUpdate()
	end
end

---@param options AlertsModuleOptions
local function ApplyOptions(options)
	-- TEMPORARY: TTS is legacy-only (it needs the spell name at the moment an aura appears,
	-- which is secret on 12.1), so skip the voice/volume cache work there; dies with the 12.0
	-- path.
	if not USE_AURA_CONTAINERS then
		sound:ApplyTTSOptions(options)
	end

	display:ApplyBarOptions(options)
end

local function UpdateContent()
	if USE_AURA_CONTAINERS then
		display:RefreshNameplateDisplays()
		sound:Refresh(display:GetActiveTokens())
	end

	if testModeActive then
		display:RefreshTestAlerts()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)

	if active then
		SetPaused(true)
	else
		display:ClearBars()
		SetPaused(false)
		-- TEMPORARY: legacy-only repopulation from the watchers; the 12.1 containers refresh
		-- themselves when unpaused. Dies with the 12.0 path.
		if not USE_AURA_CONTAINERS then
			ScheduleAuraDataUpdate()
		end
	end

	M:Refresh()
end

---Legacy path: the nameplate aura-refresh hook only matters while something important-related
---is switched on.
local function OnNameplateAuraRefresh()
	if paused then
		return
	end
	if not moduleUtil:IsModuleEnabled(moduleName.Alerts) then
		return
	end
	local options = db.Modules.AlertsModule
	local importantNeeded = (options.Important and options.Important.Enabled)
		or (options.Sound.Important and options.Sound.Important.Enabled)
		or sound:IsImportantTTSEnabled()
	if importantNeeded then
		ScheduleAuraDataUpdate()
	end
end

local function CreateEvents()
	local eventsFrame = CreateFrame("Frame")
	-- The plate events are gated by Refresh; PVP_MATCH_STATE_CHANGED and
	-- ZONE_CHANGED_NEW_AREA drive that gate so they stay always-registered.
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	-- TEMPORARY: the player's spec only matters to the legacy TTS suppression cache, which is
	-- dead on 12.1 along with TTS itself. Dies with the 12.0 path.
	if not USE_AURA_CONTAINERS then
		eventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	end
	plateGate = eventGate:New(eventsFrame, { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }, {
		-- Plate events maintain the duel baselines; drop them so reactivation reseeds
		-- via RebuildNameplateWatchers instead of trusting stale tokens.
		OnDeactivate = function()
			duelSub:ClearAll()
		end,
	})
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "PVP_MATCH_STATE_CHANGED" then
			OnMatchStateChanged()
		elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
			-- Important-TTS suppression depends on the player's spec (Shadow Priest), so refresh it.
			sound:UpdateImportantTTSCache()
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			-- Hook every enemy nameplate's aura refresh so the important bar can react to buff changes.
			-- Legacy only: on 12.1 the containers track their unit themselves.
			if not USE_AURA_CONTAINERS and units:IsEnemy(unitToken) then
				observer:HookAuraFrame(unitToken, OnNameplateAuraRefresh)
			end
			if IsEnabled() and AreNameplatesNeeded(true) then
				OnNamePlateAdded(unitToken)
			end
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		elseif event == "ZONE_CHANGED_NEW_AREA" then
			M:Refresh()
		end
	end)

	-- A duel opponent starts as an untracked friendly plate; when the duel begins the flip
	-- routes through OnNamePlateAdded to build its displays and sound registrations, and when
	-- it ends the same call releases them.
	duelSub = duelPoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.Alerts)
	end, OnNamePlateAdded)
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
	local options = GetOptions()

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		Teardown()
		display:SetAnchorInteractive(false)
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent()

	-- Owned here rather than by the test-mode toggle, so flipping the module switch while a
	-- test is running shows or hides the drag anchors and their captions with it, and the
	-- important bar's draggability tracks the split-mode state ApplyOptions just settled.
	display:SetAnchorInteractive(testModeActive)
end

function M:Init()
	db = mini:GetSavedVars()

	sound:Init()
	display:Init()
	display:CreateFrames()
	CreateEvents()
	ApplyInitialState()
end
