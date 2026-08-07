---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local units = addon.Utils.Units
local kickTracker = addon.Core.KickTracker
local eventGate = addon.Core.EventGate
local duelPoller = addon.Core.DuelPoller
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local observer = addon.Modules.Nameplates.Observer
local display  = addon.Modules.Nameplates.Display

---@class NameplatesModule : IModule
local M = {}
addon.Modules.Nameplates.Module = M
addon.Modules.NameplatesModule = M

-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type Db
local db
---@type table
local nmModule
local testModeActive = false
---@type EventGate?
local plateGate
-- Duel detection: no event fires when a friendly unit turns attackable at duel start (or back
-- at duel end), so the shared DuelPoller re-registers plates whose enemy status flips
-- (GetUnitOptions switches between Friendly and Enemy for the same token). Baselines are
-- seeded on plate add and cleared on plate remove.
---@type DuelPollerSubscriber
local duelSub

-- Mode toggles as of the last refresh. A change in any of them means the tracked plates were
-- built against the wrong options and have to be rebuilt.
local previousFriendlyEnabled = {
	Bar1 = false,
	Bar2 = false,
}
local previousEnemyEnabled = {
	Bar1 = false,
	Bar2 = false,
}
local previousPetEnabled = {
	Friendly = false,
	Enemy = false,
}
local previousModuleEnabled = { Always = false, Arena = false, BattleGrounds = false, PvE = false }
local previousImportantNeeded = false

local function GetCCSortOptions()
	if db.CCNativeOrder then
		return Enum.UnitAuraSortRule.Default, Enum.UnitAuraSortDirection.Normal
	end
	return Enum.UnitAuraSortRule.Unsorted, Enum.UnitAuraSortDirection.Reverse
end

local function OnAuraDataChanged(unitToken)
	display:RenderUnit(unitToken, observer:Get(unitToken))
end

local function OnNamePlateRemoved(unitToken)
	-- Clear before the early return: friendly plates have a poll baseline but no anchor data.
	duelSub:Clear(unitToken)

	if not display:GetData(unitToken) then
		return
	end

	display:Untrack(unitToken)
	observer:Dispose(unitToken)
	kickTracker:Unwatch(unitToken)
end

local function OnNamePlateAdded(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	if not nameplate then
		return
	end

	-- Baseline for the duel poll, kept fresh on every (re)registration. RebuildContainers routes
	-- through here too, so plates that existed before Init/enable are also seeded.
	duelSub:Seed(unitToken)

	-- Legacy only: the hook feeds watcher-driven re-renders. On 12.1 the containers track
	-- their unit themselves and the hook body would no-op against the empty watcher table,
	-- so installing it just bills us for a dead closure on every Blizzard aura refresh.
	if not USE_AURA_CONTAINERS then
		observer:HookAuraFrame(nameplate, function(unit)
			if display:ImportantNeeded() and display:GetData(unit) and observer:Get(unit) then
				OnAuraDataChanged(unit)
			end
		end)
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	if not moduleEnabled then
		-- 12.1: an already-tracked token may still hold pooled displays from before the
		-- module/option flip; release them instead of leaving them tracking until the
		-- plate despawns.
		if USE_AURA_CONTAINERS then
			display:Release(unitToken)
		end
		return
	end

	-- Check if we should ignore pets
	local unitOptions = display:GetUnitOptions(unitToken)
	if unitOptions.IgnorePets and units:IsPetOrMinion(unitToken) then
		if USE_AURA_CONTAINERS then
			display:Release(unitToken)
		end
		return
	end

	-- BUGFIX (duels): Previously this returned early if no containers were created for
	-- the current options table (e.g. friendly player with Friendly.* all disabled).
	-- That meant the plate was never tracked and no watcher listened to UNIT_AURA, so when
	-- the unit later became a duel opponent and GetUnitOptions() started returning Enemy
	-- options, OnAuraDataChanged would never fire to rebuild containers.
	-- We now also track it if the *opposite* faction has any mode enabled, but only in the
	-- open world where duels can occur - inside instances this overhead is unnecessary since
	-- friendly units can never become duel opponents there.
	local inInstance = IsInInstance()
	local oppositeOptions = units:IsEnemy(unitToken) and nmModule.Friendly or nmModule.Enemy
	local anyEnabledOpposite = not inInstance
		and ((oppositeOptions.Bar1 and oppositeOptions.Bar1.Enabled)
			or (oppositeOptions.Bar2 and oppositeOptions.Bar2.Enabled))

	local data = display:Track(unitToken, nameplate, unitOptions, anyEnabledOpposite)
	if not data then
		return
	end

	if not USE_AURA_CONTAINERS then
		local sortRule, sortDirection = GetCCSortOptions()
		observer:Create(unitToken, sortRule, sortDirection, function()
			OnAuraDataChanged(unitToken)
		end)
	end

	kickTracker:Watch(unitToken)
	kickTracker:Subscribe(unitToken, function()
		if USE_AURA_CONTAINERS then
			display:UpdateKick(data)
		else
			OnAuraDataChanged(unitToken)
		end
	end)

	if USE_AURA_CONTAINERS then
		display:UpdateKick(data)
	end

	-- Initial update
	if testModeActive then
		-- In test mode, show test icons for this specific nameplate
		display:ShowTestIconsFor(data)
	end
end

-- Rebuilds a plate whose enemy status flipped: GetUnitOptions starts returning the other
-- faction's options, so the bars are rebuilt (12.1: displays re-acquired with the new faction's
-- budgets; legacy: containers rebuilt and the watcher re-rendered).
local function OnDuelFactionFlip(unitToken)
	OnNamePlateAdded(unitToken)
	OnAuraDataChanged(unitToken)
end

local function RebuildContainers()
	if not moduleUtil:IsModuleEnabled(moduleName.Nameplates) then
		return
	end

	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken

		if unitToken then
			OnNamePlateAdded(unitToken)
		end
	end
end

local function CacheEnabledModes()
	local enemy = nmModule.Enemy
	local friendly = nmModule.Friendly
	local enabled = nmModule.Enabled

	previousEnemyEnabled.Bar1 = enemy.Bar1.Enabled
	previousEnemyEnabled.Bar2 = enemy.Bar2.Enabled

	previousFriendlyEnabled.Bar1 = friendly.Bar1.Enabled
	previousFriendlyEnabled.Bar2 = friendly.Bar2.Enabled

	previousPetEnabled.Friendly = friendly.IgnorePets
	previousPetEnabled.Enemy = enemy.IgnorePets

	previousModuleEnabled.Always = enabled.Always
	previousModuleEnabled.Arena = enabled.Arena
	previousModuleEnabled.BattleGrounds = enabled.BattleGrounds
	previousModuleEnabled.PvE = enabled.PvE

	previousImportantNeeded = display:ImportantNeeded()
end

local function HaveModesChanged()
	local enemy = nmModule.Enemy
	local friendly = nmModule.Friendly
	local enabled = nmModule.Enabled

	return previousEnemyEnabled.Bar1 ~= enemy.Bar1.Enabled
		or previousEnemyEnabled.Bar2 ~= enemy.Bar2.Enabled
		or previousFriendlyEnabled.Bar1 ~= friendly.Bar1.Enabled
		or previousFriendlyEnabled.Bar2 ~= friendly.Bar2.Enabled
		or previousPetEnabled.Friendly ~= friendly.IgnorePets
		or previousPetEnabled.Enemy ~= enemy.IgnorePets
		or previousModuleEnabled.Always ~= enabled.Always
		or previousModuleEnabled.Arena ~= enabled.Arena
		or previousModuleEnabled.BattleGrounds ~= enabled.BattleGrounds
		or previousModuleEnabled.PvE ~= enabled.PvE
		or previousImportantNeeded ~= display:ImportantNeeded()
end

local function ApplyBlizzardNameplateSettings()
	local configureEnabled = db.ConfigureBlizzardNameplates
	if configureEnabled == nil then
		configureEnabled = true
	end

	local anyEnemyEnabled = nmModule.Enemy.Bar1.Enabled
		or nmModule.Enemy.Bar2.Enabled

	local anyFriendlyEnabled = nmModule.Friendly.Bar1.Enabled
		or nmModule.Friendly.Bar2.Enabled

	if configureEnabled and anyEnemyEnabled then
		C_CVar.SetCVarBitfield("nameplateEnemyPlayerAuraDisplay", Enum.NamePlateEnemyPlayerAuraDisplay.LossOfControl, false)
		C_CVar.SetCVarBitfield("nameplateEnemyPlayerAuraDisplay", Enum.NamePlateEnemyPlayerAuraDisplay.Buffs, false)
		C_CVar.SetCVarBitfield("nameplateEnemyNpcAuraDisplay", Enum.NamePlateEnemyNpcAuraDisplay.CrowdControl, false)
	end

	if configureEnabled and anyFriendlyEnabled then
		C_CVar.SetCVarBitfield("nameplateFriendlyPlayerAuraDisplay", Enum.NamePlateFriendlyPlayerAuraDisplay.LossOfControl, false)
	end
end

---@return NameplatesModuleOptions?
local function GetOptions()
	-- Cached in Init off db.Modules.NameplatesModule.
	return nmModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Nameplates) and display:AnyEnabled()
end

---@param active boolean
local function SetEventsActive(active)
	-- While inactive no state tracks nameplates, so the plate events can be unregistered
	-- entirely; reactivation rebuilds from the live plate list. The addon-wide Refresh
	-- (config, world change, raid flip) re-runs this gate.
	plateGate:SetActive(active)
end

local function Teardown()
	observer:DisableAll()
	display:Teardown()

	CacheEnabledModes()
end

local function EnsureFrames()
	ApplyBlizzardNameplateSettings()

	observer:EnableAll()

	-- if the user has enabled/disabled a mode, rebuild the containers
	if HaveModesChanged() then
		RebuildContainers()
	end

	CacheEnabledModes()
end

local function ApplyOptions()
	display:RefreshAnchorsAndSizes()
	observer:SetSort(GetCCSortOptions())
end

local function UpdateContent()
	if testModeActive then
		display:ShowTestIcons()
		return
	end

	-- 12.1: the containers render themselves and no watchers exist, so RenderUnit would bail on
	-- the watcher lookup for every tracked plate. RefreshAnchorsAndSizes (via ApplyOptions) has
	-- already re-applied the bar options to the displays.
	if USE_AURA_CONTAINERS then
		return
	end

	-- Re-render every tracked nameplate so per-bar option changes (Show CC / Defensives /
	-- Important, colours, glow, tooltips, etc.) apply immediately instead of waiting for the next
	-- aura event. HaveModesChanged only catches enabled/mode toggles, and SetSort no-ops when the
	-- sort is unchanged, so neither re-applies the bars on their own.
	for unitToken in pairs(display:GetTrackedPlates()) do
		OnAuraDataChanged(unitToken)
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)

	if active then
		display:SetPaused(true)
	else
		display:ClearAll()
		display:SetPaused(false)
	end

	M:Refresh()

	if not active then
		-- Repopulate from live aura data; the test icons overwrote whatever the plates had.
		observer:ForceFullUpdate()
	end
end

local function CreateEvents()
	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "NAME_PLATE_UNIT_ADDED" then
			OnNamePlateAdded(unitToken)
			-- refresh their aura information
			-- important to do it here an not inside of OnNamePlateAdded because that is also called by Refresh
			-- which would cause a significant performance impact
			OnAuraDataChanged(unitToken)
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		end
	end)

	plateGate = eventGate:New(eventsFrame, {
		"NAME_PLATE_UNIT_ADDED",
		"NAME_PLATE_UNIT_REMOVED",
	}, {
		-- Plates that spawned while inactive were never tracked.
		OnActivate = RebuildContainers,
		-- Release tracked plates now - the removal events that normally clean them up are
		-- no longer registered.
		OnDeactivate = function()
			for unitToken in pairs(display:GetTrackedPlates()) do
				OnNamePlateRemoved(unitToken)
			end
		end,
	})

	duelSub = duelPoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	end, OnDuelFactionFlip)
end

local function ApplyInitialState()
	-- Registers the plate events and initializes existing nameplates when active.
	SetEventsActive(IsEnabled())

	CacheEnabledModes()
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
		return
	end

	EnsureFrames()
	ApplyOptions()
	UpdateContent()
end

function M:Init()
	db = mini:GetSavedVars()
	-- Cache once so all hot-path functions avoid repeatedly traversing db -> Modules -> NameplatesModule
	nmModule = db.Modules.NameplatesModule

	display:Init()
	CreateEvents()
	ApplyInitialState()
end
