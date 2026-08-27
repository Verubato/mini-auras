---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local units = addon.Utils.UnitUtil
local kickTracker = addon.Core.KickTracker
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
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
---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local plateGate
-- No event fires when a friendly unit turns attackable at a duel start or end, so the shared
-- UnitStatePoller re-registers plates whose enemy status flips. Baselines are seeded on plate add
-- and cleared on plate remove.
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

	-- Critters and the game's "minus" adds never carry anything worth showing, and a busy zone is
	-- mostly them: each one tracked costs a live aura container the client parses for as long as the
	-- plate is up. Pets are exempt so IgnorePets stays the only thing deciding those, since a
	-- warlock's imps are classed minus too.
	if units:IsMinorUnit(unitToken) and not units:IsPetOrMinion(unitToken) then
		display:Release(unitToken)
		return
	end

	local unitOptions = display:GetUnitOptions(unitToken)
	if unitOptions.IgnorePets and units:IsPetOrMinion(unitToken) then
		display:Release(unitToken)
		return
	end

	-- A plate with nothing enabled for its current faction is still tracked when the opposite
	-- faction has a bar on, so a flip has state to rebuild from and the displays the plate was
	-- drawing with are parked by EnsureBarDisplays rather than left reading a unit they were never
	-- filtered for. A duel is the open-world way a plate changes sides, and a mind control is the
	-- arena way.
	local oppositeOptions = units:IsEnemy(unitToken) and nmModule.Friendly or nmModule.Enemy
	local anyEnabledOpposite = (oppositeOptions.Bar1 and oppositeOptions.Bar1.Enabled)
		or (oppositeOptions.Bar2 and oppositeOptions.Bar2.Enabled)

	local data = display:Track(unitToken, nameplate, unitOptions, anyEnabledOpposite)
	if not data then
		-- Neither side has anything to draw. Whatever this plate was showing before goes with it.
		display:Untrack(unitToken)
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

	if testModeActive then
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
	-- Cached in Init off db.Modules.Nameplates.
	return nmModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Nameplates) and display:AnyEnabled()
end

local function EnsureFrames()
	ApplyBlizzardNameplateSettings()

	if HaveModesChanged() then
		RebuildContainers()
	end

	CacheEnabledModes()
end

local function ApplyOptions()
	display:RefreshAnchorsAndSizes()
end

-- Only the fake icons rebuild here. The containers render the live ones themselves, and
-- RefreshAnchorsAndSizes has already re-applied the bar options to them.
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

local function Setup()
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
	})

	-- A plate whose enemy status flipped goes back through the add path: GetUnitOptions starts
	-- returning the other faction's options, so its displays are re-acquired with that faction's
	-- budgets.
	stateSub = unitStatePoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	end, OnNamePlateAdded)
end

-- While inactive no state tracks nameplates, so the plate events can be unregistered entirely.
-- The addon-wide Refresh (config, world change, raid flip) is what brings the module back.
local function OnEnable()
	plateGate:SetActive(true)

	-- Plates that spawned while inactive were never tracked, so the live list is read back in.
	RebuildContainers()

	-- After that rebuild, so a mode changed while the module was off does not send EnsureFrames
	-- through a second one.
	CacheEnabledModes()
end

local function OnDisable()
	plateGate:SetActive(false)

	-- Release the tracked plates by hand: the removal events that normally clean them up are no
	-- longer registered.
	for unitToken in pairs(display:GetTrackedPlates()) do
		OnNamePlateRemoved(unitToken)
	end

	display:Teardown()
end

local function Apply()
	EnsureFrames()
	ApplyOptions()
	UpdateContent()

	-- Only behind a loading screen, which is the once-per-world-load trigger rather than the window
	-- the work runs in. Display:Prewarm queues the set and the background walker builds it one
	-- display per tick. PLAYER_ENTERING_WORLD lands here with the screen still up, which is the case
	-- that matters. Outside one, a plate builds its own on first sight.
	if addon:IsLoadingScreenUp() then
		-- After ApplyOptions, so the displays are built with the geometry and look this refresh
		-- settled rather than the previous one's.
		display:Prewarm()
	end
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
	-- Cache once so all hot-path functions avoid repeatedly traversing db -> Modules -> Nameplates
	nmModule = db.Modules.Nameplates

	display:Init()

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		IsEnabled = IsEnabled,
		Setup = Setup,
		OnEnable = OnEnable,
		OnDisable = OnDisable,
		Apply = Apply,
	})

	-- The plate events wait for the first Refresh rather than registering here: the gate picks up
	-- every plate already on screen when it activates, so nothing is missed by leaving them off,
	-- and the world state the prewarm sizes itself from has not settled this early.
	CacheEnabledModes()
end
