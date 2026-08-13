---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local units = addon.Utils.Units
local eventGate = addon.Core.EventGate
local duelPoller = addon.Core.DuelPoller
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local sound   = addon.Modules.Alerts.Sound
local display = addon.Modules.Alerts.Display

---@class AlertsModule : IModule
local M = {}
addon.Modules.Alerts.Module = M
addon.Modules.AlertsModule = M

-- Read by the tests, which derive the expected registration count from it.
M.SilentAlertSpellIds = sound.SilentAlertSpellIds

---@type Db
local db
local testModeActive = false
---@type EventGate?
local plateGate
-- Duel detection: no event fires when a friendly unit turns attackable at duel start (or back
-- at duel end), so the shared DuelPoller re-registers plates whose enemy status flips.
-- Baselines are seeded on plate add and cleared on plate remove.
---@type DuelPollerSubscriber
local duelSub
-- Reused enemy-token set for RebuildNameplateDisplays.
local activeTokensScratch = {}

-- Only the sound registrations care: the bars themselves stop drawing on the test-mode flag.
---@param value boolean
local function SetPaused(value)
	sound:SetPaused(value)
end

local function OnMatchStateChanged()
	local matchState = C_PvP.GetActiveMatchState()
	local inPrepRoom = matchState == Enum.PvPMatchState.StartUp

	display:SetInPrepRoom(inPrepRoom)

	-- Prep-room garbage handling: RefreshNameplateDisplays hides the displays while
	-- inPrepRoom is set and re-shows them when the match starts.
	display:RefreshNameplateDisplays()

	if not inPrepRoom then
		return
	end

	display:ClearBars()
end

local function OnNamePlateAdded(unitToken)
	-- Baseline for the duel poll, kept fresh on every (re)registration.
	local isEnemy = duelSub:Seed(unitToken)

	-- Only track enemy nameplates. A charmed unit is out too: mind control hands it to the
	-- other team, its aura list becomes the controller's own buffs, and the containers would
	-- announce and draw those as alerts. The poll routes back here when the charm ends.
	if not isEnemy or units:IsCharmed(unitToken) then
		-- The token now belongs to a non-enemy (recycled plate or duel ending), so its warm
		-- sound registrations are dropped along with the display.
		sound:RemoveToken(unitToken)
		display:ReleaseNameplateDisplay(unitToken)
		return
	end

	-- Configure only the new entry (styling every pooled pair per plate spawn adds up in
	-- busy fights); the chain re-anchor is cheap and covers the row shift.
	display:ApplyOneAndChain(unitToken)
end

local function OnNamePlateRemoved(unitToken)
	duelSub:Clear(unitToken)

	display:ReleaseNameplateDisplay(unitToken)
	display:ChainDisplays()
end

local function ClearNamePlateDisplays()
	display:ReleaseAllNameplateDisplays()
end

local function RebuildNameplateDisplays()
	-- Build a set of currently active enemy unit tokens
	local activeTokens = activeTokensScratch
	wipe(activeTokens)
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken
		if unitToken then
			-- Seed the duel-poll baseline here too: plates that existed before Init/enable
			-- never fire NAME_PLATE_UNIT_ADDED. Charmed units are skipped for the same
			-- reason as the add path.
			if duelSub:Seed(unitToken) and not units:IsCharmed(unitToken) then
				activeTokens[unitToken] = true
			end
		end
	end

	display:SyncActiveTokens(activeTokens)
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

---Arena, battlegrounds, and the open world all track enemy nameplates; nowhere else does.
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
	display:ReleaseAllNameplateDisplays()
	sound:RemoveAllySounds()
	display:ClearBars()
end

local function EnsureFrames()
	if AreNameplatesNeeded(true) then
		RebuildNameplateDisplays()
	else
		ClearNamePlateDisplays()
	end
end

---@param options AlertsModuleOptions
local function ApplyOptions(options)
	display:ApplyBarOptions(options)
end

local function UpdateContent()
	display:RefreshNameplateDisplays()
	sound:Refresh(display:GetActiveTokens())

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
	end

	M:Refresh()
end

local function CreateEvents()
	local eventsFrame = CreateFrame("Frame")
	-- The plate events are gated by Refresh; PVP_MATCH_STATE_CHANGED and
	-- ZONE_CHANGED_NEW_AREA drive that gate so they stay always-registered.
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	-- The enemy-debuff announcements sit on the party tokens, so they follow the roster
	-- rather than the nameplates. Always registered, like the two gate drivers above: the
	-- handler only reconciles those registrations, which is far cheaper than a full Refresh
	-- on every roster event in a battleground.
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	plateGate = eventGate:New(eventsFrame, { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }, {
		-- Plate events maintain the duel baselines; drop them so reactivation reseeds
		-- via RebuildNameplateDisplays instead of trusting stale tokens.
		OnDeactivate = function()
			duelSub:ClearAll()
		end,
	})
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "PVP_MATCH_STATE_CHANGED" then
			OnMatchStateChanged()
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			if IsEnabled() and AreNameplatesNeeded(true) then
				OnNamePlateAdded(unitToken)
			end
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		elseif event == "ZONE_CHANGED_NEW_AREA" then
			M:Refresh()
		elseif event == "GROUP_ROSTER_UPDATE" then
			sound:RefreshAllySounds(true)
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
