---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local units = addon.Utils.UnitUtil
local kickTracker = addon.Core.KickTracker
local eventGate = addon.Core.EventGate
local unitStatePoller = addon.Core.UnitStatePoller
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local display = addon.Modules.Nameplates.Display

---@class NameplatesModule : IModule
local M = {}
addon.Modules.Nameplates.Module = M
addon.Modules.NameplatesModule = M

---@type Db
local db
---@type table
local nmModule
local testModeActive = false
---@type EventGate?
local plateGate
-- Duel detection: no event fires when a friendly unit turns attackable at duel start (or back
-- at duel end), so the shared UnitStatePoller re-registers plates whose enemy status flips
-- (GetUnitOptions switches between Friendly and Enemy for the same token). Baselines are
-- seeded on plate add and cleared on plate remove.
---@type UnitStatePollerSubscriber
local stateSub

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

local function OnNamePlateRemoved(unitToken)
	-- Clear before the early return: friendly plates have a poll baseline but no anchor data.
	stateSub:Clear(unitToken)

	if not display:GetData(unitToken) then
		return
	end

	display:Untrack(unitToken)
	kickTracker:Unwatch(unitToken)
end

local function OnNamePlateAdded(unitToken)
	-- The personal resource display arrives as a plate like any other, but it is the player's own
	-- frame: a friendly bar there would draw the player's own auras a second time, on top of
	-- whatever the unit frame modules already show.
	if units:SameUnit(unitToken, "player") then
		return
	end

	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	if not nameplate then
		return
	end

	-- Baseline for the state poll, kept fresh on every (re)registration. RebuildContainers routes
	-- through here too, so plates that existed before Init/enable are also seeded.
	stateSub:Seed(unitToken)

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	if not moduleEnabled then
		-- An already-tracked token may still hold pooled displays from before the module/option
		-- flip; release them instead of leaving them tracking until the plate despawns.
		display:Release(unitToken)
		return
	end

	-- A charmed unit is under the other team's control: its aura list flips to the
	-- controller's buffs, and either faction's bars would draw those as the unit's own.
	-- Untracked entirely (containers hidden, displays parked); the charm poll routes back
	-- here when the mind control ends.
	if units:IsCharmed(unitToken) then
		display:Untrack(unitToken)
		return
	end

	-- Check if we should ignore pets
	local unitOptions = display:GetUnitOptions(unitToken)
	if unitOptions.IgnorePets and units:IsPetOrMinion(unitToken) then
		display:Release(unitToken)
		return
	end

	-- Duels: a plate with nothing enabled for its current faction is still tracked when the
	-- OPPOSITE faction has a bar on, so the flip has state to rebuild from. Only in the open
	-- world, the one place a friendly unit can become a duel opponent.
	local inInstance = IsInInstance()
	local oppositeOptions = units:IsEnemy(unitToken) and nmModule.Friendly or nmModule.Enemy
	local anyEnabledOpposite = not inInstance
		and ((oppositeOptions.Bar1 and oppositeOptions.Bar1.Enabled)
			or (oppositeOptions.Bar2 and oppositeOptions.Bar2.Enabled))

	local data = display:Track(unitToken, nameplate, unitOptions, anyEnabledOpposite)
	if not data then
		return
	end

	-- Subscribed once per token, not once per registration: this path re-runs for a plate that is
	-- already tracked (a duel flipping its faction, a rebuild), and a second callback would keep
	-- a stale data table alive and update it forever. The token's current data is looked up when
	-- the kick lands rather than captured, so one subscription serves every rebuild.
	if kickTracker:Watch(unitToken) then
		kickTracker:Subscribe(unitToken, function()
			local current = display:GetData(unitToken)

			if current then
				display:UpdateKick(current)
			end
		end)
	end

	display:UpdateKick(data)

	-- Initial update
	if testModeActive then
		-- In test mode, show test icons for this specific nameplate
		display:ShowTestIconsFor(data)
	end
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

---Clears one bit of a nameplate aura CVar, but only when it is actually set. This runs on every
---refresh, and a write broadcasts CVAR_UPDATE to every addon listening whether the value moved or
---not.
local function ClearCVarBit(cvar, index)
	if C_CVar.GetCVarBitfield(cvar, index) then
		C_CVar.SetCVarBitfield(cvar, index, false)
	end
end

local function ApplyBlizzardNameplateSettings()
	local configureEnabled = db.ConfigureBlizzardNameplates
	if configureEnabled == nil then
		configureEnabled = true
	end

	if not configureEnabled then
		return
	end

	local anyEnemyEnabled = nmModule.Enemy.Bar1.Enabled
		or nmModule.Enemy.Bar2.Enabled

	local anyFriendlyEnabled = nmModule.Friendly.Bar1.Enabled
		or nmModule.Friendly.Bar2.Enabled

	if anyEnemyEnabled then
		ClearCVarBit("nameplateEnemyPlayerAuraDisplay", Enum.NamePlateEnemyPlayerAuraDisplay.LossOfControl)
		ClearCVarBit("nameplateEnemyPlayerAuraDisplay", Enum.NamePlateEnemyPlayerAuraDisplay.Buffs)
		ClearCVarBit("nameplateEnemyNpcAuraDisplay", Enum.NamePlateEnemyNpcAuraDisplay.CrowdControl)
	end

	if anyFriendlyEnabled then
		ClearCVarBit("nameplateFriendlyPlayerAuraDisplay", Enum.NamePlateFriendlyPlayerAuraDisplay.LossOfControl)
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
	display:Teardown()

	CacheEnabledModes()
end

local function EnsureFrames()
	ApplyBlizzardNameplateSettings()

	-- if the user has enabled/disabled a mode, rebuild the containers
	if HaveModesChanged() then
		RebuildContainers()
	end

	CacheEnabledModes()
end

local function ApplyOptions()
	display:RefreshAnchorsAndSizes()
end

-- Only the fake icons rebuild here; the containers render the live ones themselves, and
-- RefreshAnchorsAndSizes (via ApplyOptions) has already re-applied the bar options to them.
local function UpdateContent()
	if testModeActive then
		display:ShowTestIcons()
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
end

local function CreateEvents()
	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "NAME_PLATE_UNIT_ADDED" then
			OnNamePlateAdded(unitToken)
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

	-- A plate whose enemy status flipped goes back through the add path: GetUnitOptions starts
	-- returning the other faction's options, so its displays are re-acquired with that faction's
	-- budgets.
	stateSub = unitStatePoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	end, OnNamePlateAdded)
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

	-- Only behind a loading screen. Building every token's displays is a long frame, which costs
	-- nothing while nothing is being drawn and would be a visible hitch at any other time - and
	-- PLAYER_ENTERING_WORLD lands here with the screen still up, which is the case that matters.
	-- Outside one, plates build their own on first sight as they always did.
	if addon:IsLoadingScreenUp() then
		-- After ApplyOptions, so the displays are built with the geometry and look this refresh
		-- settled rather than the previous one's.
		display:Prewarm()
	end
end

function M:Init()
	db = mini:GetSavedVars()
	-- Cache once so all hot-path functions avoid repeatedly traversing db -> Modules -> NameplatesModule
	nmModule = db.Modules.NameplatesModule

	display:Init()
	CreateEvents()
	ApplyInitialState()
end
