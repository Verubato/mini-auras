---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
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

-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type Db
local db
local testModeActive = false
local paused = false
local enabled = false
-- Legacy-only / 12.1-only event gates (see CreateEvents); a disabled portrait module receives no
-- events at all.
---@type EventGate?
local nameplateGate
---@type EventGate?
local unitChangeGate

---Both halves stop rendering while the module is off or paused. Pushed rather than polled so the
---nameplate hook, which runs on Blizzard's hot path, only has a boolean to read.
local function PushSuspension()
	local suspended = not enabled or paused
	display:SetSuspended(suspended)
	observer:SetSuspended(suspended)
end

-- TEMPORARY: feeds observer:SetSort, which only reaches the legacy watchers, so the CCNativeOrder
-- option is a no-op for portraits on 12.1; both die with the 12.0 path.
local function GetCCSortOptions()
	if db.CCNativeOrder then
		return Enum.UnitAuraSortRule.Default, Enum.UnitAuraSortDirection.Normal
	end
	return Enum.UnitAuraSortRule.Unsorted, Enum.UnitAuraSortDirection.Reverse
end

---@return PortraitModuleOptions?
local function GetOptions()
	return db and db.Modules.PortraitModule
end

---Also refreshes the `enabled` cache that the nameplate RefreshAuras hook reads on its hot path.
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
	if nameplateGate then
		nameplateGate:SetActive(active)
	end
	if unitChangeGate then
		unitChangeGate:SetActive(active)
	end
end

local function Teardown()
	observer:DisableWatchers()
	display:Teardown()
end

local function EnsureFrames()
	observer:EnableWatchers()
	display:EnsureFrames()
end

local function ApplyOptions()
	observer:SetSort(GetCCSortOptions())
	display:ApplyOptions()
end

-- Live auras are pushed in by the watchers/containers, so only the fake ones rebuild here.
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

	-- Hook each nameplate's aura refresh so important buffs on the target/focus update live.
	-- Legacy only: on 12.1 the important slot tracks its unit itself.
	if not USE_AURA_CONTAINERS then
		local nameplateEvents = CreateFrame("Frame")
		nameplateEvents:SetScript("OnEvent", function(_, _, unitToken)
			observer:HookNameplateAuraFrame(unitToken)
		end)
		nameplateGate = eventGate:New(nameplateEvents, { "NAME_PLATE_UNIT_ADDED" }, {
			-- Hook plates that spawned while disabled - their add events were never seen.
			OnActivate = function()
				for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
					if nameplate.unitToken then
						observer:HookNameplateAuraFrame(nameplate.unitToken)
					end
				end
			end,
		})
	end

	-- 12.1: containers track their unit token but don't refresh when the token's occupant
	-- changes (the legacy watchers registered these events themselves); the display's
	-- RequestRefresh forces the re-parse.
	if USE_AURA_CONTAINERS then
		local unitChangeEvents = CreateFrame("Frame")
		unitChangeEvents:SetScript("OnEvent", function(_, event)
			local unit = event == "PLAYER_TARGET_CHANGED" and "target" or "focus"
			display:RefreshUnitAuras(unit)
			observer:FireUnitUpdate(unit)
		end)
		unitChangeGate = eventGate:New(unitChangeEvents, { "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED" })
	end
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
