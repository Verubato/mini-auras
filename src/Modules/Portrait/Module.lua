---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local eventGate = addon.Core.EventGate
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

-- Which portrait token each occupant-change event speaks for (see CreateEvents).
local UNIT_CHANGE_TOKEN = {
	PLAYER_TARGET_CHANGED = "target",
	PLAYER_FOCUS_CHANGED = "focus",
	UNIT_PET = "pet",
}

---@type Db
local db
local testModeActive = false
local paused = false
local enabled = false
-- A disabled portrait module receives no events at all (see CreateEvents).
---@type EventGate?
local unitChangeGate

---The display stops rendering while the module is off or paused.
local function PushSuspension()
	display:SetSuspended(not enabled or paused)
end

---@return PortraitModuleOptions?
local function GetOptions()
	return db and db.Modules.PortraitModule
end

---Also refreshes the `enabled` cache the suspension push reads.
---@return boolean
local function IsEnabled()
	enabled = moduleUtil:IsModuleEnabled(ModuleName.Portrait)
	PushSuspension()
	return enabled
end

---@param active boolean
local function SetEventsActive(active)
	-- Events stay unregistered while disabled; the addon-wide Refresh (config, world
	-- change, raid flip) re-runs this gate.
	if unitChangeGate then
		unitChangeGate:SetActive(active)
	end
end

local function Teardown()
	display:Teardown()
end

local function EnsureFrames()
	display:EnsureFrames()
end

local function ApplyOptions()
	display:ApplyOptions()
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

local function CreateEvents()
	-- defer attaching to third-party unit frames until they are created
	local eventsFrame = CreateFrame("Frame")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:SetScript("OnEvent", function()
		eventsFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
		anchors:AttachThirdPartyFrames()
	end)

	-- Containers track their unit token but don't refresh when the token's occupant changes; the
	-- display's RequestRefresh forces the re-parse.
	local unitChangeEvents = CreateFrame("Frame")
	unitChangeEvents:SetScript("OnEvent", function(_, event, owner)
		-- UNIT_PET fires for every group member's pet; only the player's has a portrait.
		if event == "UNIT_PET" and owner ~= "player" then
			return
		end

		local unit = UNIT_CHANGE_TOKEN[event]
		display:RefreshUnitAuras(unit)
		observer:FireUnitUpdate(unit)
	end)
	unitChangeGate = eventGate:New(unitChangeEvents, {
		"PLAYER_TARGET_CHANGED",
		"PLAYER_FOCUS_CHANGED",
		-- A summoned pet is assistable where the empty token was not, so its disarm layer
		-- has to be re-budgeted the moment the pet turns up.
		"UNIT_PET",
	})
end

local function ApplyInitialState()
	M:Refresh()
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

	display:Init()
	anchors:AttachBlizzardFrames()
	CreateEvents()
	observer:WatchKicks()
	ApplyInitialState()
end
