---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local observer = addon.Modules.Portrait.Observer
local display  = addon.Modules.Portrait.Display
local anchors  = addon.Modules.Portrait.Anchors

---@class PortraitModule : IModule
local M = {}
addon.Modules.Portrait.Module = M
addon.Modules.PortraitModule = M

-- Which portrait token each occupant-change event speaks for.
local UNIT_CHANGE_TOKEN = {
	PLAYER_TARGET_CHANGED = "target",
	PLAYER_FOCUS_CHANGED = "focus",
	UNIT_PET = "pet",
}

-- The one event whose occupant change each unit's portrait waits on.
local UNIT_CHANGE_EVENT = {
	target = "PLAYER_TARGET_CHANGED",
	focus = "PLAYER_FOCUS_CHANGED",
	-- A summoned pet is assistable where the empty token was not, so its disarm layer has to be
	-- re-budgeted the moment it turns up.
	pet = "UNIT_PET",
}

---@type Db
local db
local testModeActive = false
local paused = false
local enabled = false
---@type ModuleLifecycle?
local lifecycle
-- One gate per unit, so a switched-off unit hears nothing.
---@type table<string, EventGate>
local unitChangeGates = {}

---The display stops rendering while the module is off or paused.
local function PushSuspension()
	display:SetSuspended(not enabled or paused)
end

---@return PortraitModuleOptions?
local function GetOptions()
	return db and db.Modules.Portrait
end

---Also refreshes the `enabled` cache the suspension push reads.
---@return boolean
local function IsEnabled()
	enabled = moduleUtil:IsModuleEnabled(ModuleName.Portrait)
	PushSuspension()
	return enabled
end

---Builds the portrait containers on first enable rather than at load. Attaching moves the
---Blizzard portraits a strata down, which Voidform's glow draws over even when no icon is ever
---rendered, so a disabled module, or a unit switched off, must leave its frames untouched.
local function EnsureAttached()
	if not enabled then
		return
	end

	anchors:AttachBlizzardFrames()

	-- Third-party unit frames do not exist until the world has loaded.
	if addon:HasEnteredWorld() then
		anchors:AttachThirdPartyFrames()
	end
end

---Brings each unit's event gate and kick subscription in line with the module and its switches.
local function SyncUnits()
	for unit, gate in pairs(unitChangeGates) do
		local on = enabled and display:IsUnitOn(unit)

		gate:SetActive(on)

		-- Only the target and focus portraits listen for kicks.
		if unit ~= "pet" then
			if on then
				observer:WatchKick(unit)
			else
				observer:UnwatchKick(unit)
			end
		end
	end
end

-- Live auras are pushed in by the containers, so only the fake ones rebuild here.
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
		paused = true
	else
		display:ResetAllSlots()
		paused = false
	end

	PushSuspension()
	M:Refresh()
end

local function Setup()
	-- Containers track their unit token but do not refresh when the token's occupant changes, so
	-- the re-parse has to be forced here.
	local unitChangeEvents = CreateFrame("Frame")
	unitChangeEvents:SetScript("OnEvent", function(_, event, owner)
		-- UNIT_PET fires for every group member's pet, and only the player's has a portrait.
		if event == "UNIT_PET" and owner ~= "player" then
			return
		end

		local unit = UNIT_CHANGE_TOKEN[event]
		display:RefreshUnitAuras(unit)
		observer:FireUnitUpdate(unit)
	end)
	for unit, event in pairs(UNIT_CHANGE_EVENT) do
		unitChangeGates[unit] = eventGate:New(unitChangeEvents, { event })
	end
end

-- Events stay unregistered while disabled. The addon-wide Refresh is what brings the module back.
local function OnDisable()
	SyncUnits()
	anchors:DetachAll()
end

local function Apply()
	SyncUnits()
	EnsureAttached()
	display:EnsureFrames()
	display:ApplyOptions()
	UpdateContent()
end

---@return IconSlotContainer[]
function M:GetContainers()
	return display:GetContainers()
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
		OnDisable = OnDisable,
		Apply = Apply,
	})
end
