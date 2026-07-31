---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local frames = addon.Core.Frames
local trinketsTracker = addon.Core.TrinketsTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
-- 12.1 only: on older clients the friendly cooldown tracker renders the trinket slot
-- itself; this standalone module replaces that surviving slice on 12.1 (trinket data is
-- C_PvP-based, not aura-based, so it survives the aura lockdown).
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
-- track self + party for test mode; arena is a raid, so also raid units
local TRACKED_UNITS = {
	"player",
	"party1",
	"party2",
	"party3",
	"raid1",
	"raid2",
	"raid3",
}
local eventFrame
local enabled = false
local paused = false
local testModeActive = false
---@type { [table]: TrinketWatcher }
local watchers = {}
---@type Db
local db
---@type TrinketsModuleOptions
local options

---@class TrinketsModule : IModule
local M = {}
addon.Modules.TrinketsModule = M

local function IsInArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and (instanceType == "arena")
end

local function IsTrackedUnit(unit)
	for _, u in ipairs(TRACKED_UNITS) do
		if u == unit then
			return true
		end
	end

	return false
end

local function SetIconState(container, durationData)
	if not container then
		return
	end

	container:SetSlot(1, {
		Texture = trinketsTracker:GetDefaultIcon(),
		DurationObject = durationData or wowEx:CreateDuration(0, 0),
		Alpha = true,
		ReverseCooldown = options.Icons.ReverseCooldown,
		Glow = options.Icons.Glow,
		FontScale = db.FontScale,
	})
end

local function UpdateUnit(unit, durationData)
	for _, w in pairs(watchers) do
		if w.Unit == unit then
			SetIconState(w.Container, durationData)
		end
	end
end

local function ClearAll()
	for _, w in pairs(watchers) do
		SetIconState(w.Container, nil)
	end
end

local function AnchorContainerToFrame(container, anchorFrame)
	container.Frame:ClearAllPoints()
	container.Frame:SetPoint(options.Point, anchorFrame, options.RelativePoint, options.Offset.X, options.Offset.Y)
	container.Frame:SetAlpha(1)
end

local function EnsureWatcher(anchorFrame, unit)
	local watcher = watchers[anchorFrame]
	if watcher then
		watcher.Unit = unit
		return watcher
	end

	local size = tonumber(options.Icons.Size) or 32
	local container = iconSlotContainer:New(UIParent, 1, size, 2, "Trinkets")

	watcher = {
		Anchor = anchorFrame,
		Unit = unit,
		Container = container,
	}
	watchers[anchorFrame] = watcher

	return watcher
end

local function DestroyWatcher(anchorFrame)
	local watcher = watchers[anchorFrame]
	if not watcher then
		return
	end

	if watcher.Container then
		watcher.Container:ResetAllSlots()
		watcher.Container.Frame:Hide()
		watcher.Container.Frame:SetParent(nil)
	end

	watchers[anchorFrame] = nil
end

local function RebuildAnchors()
	local anchors = frames:GetAll(true, testModeActive)
	local seen = {}

	for _, anchor in ipairs(anchors) do
		if anchor and not (anchor.IsForbidden and anchor:IsForbidden()) then
			local unit = anchor.unit or (anchor.GetAttribute and anchor:GetAttribute("unit"))
			if unit and unit ~= "" and IsTrackedUnit(unit) then
				local w = EnsureWatcher(anchor, unit)
				seen[anchor] = true
				AnchorContainerToFrame(w.Container, anchor)
			end
		end
	end

	for anchorFrame in pairs(watchers) do
		if not seen[anchorFrame] then
			DestroyWatcher(anchorFrame)
		end
	end
end

local function RefreshUnit(unit)
	if not unit or unit == "" or not UnitExists(unit) then
		return
	end

	local durationData = trinketsTracker:GetUnitDuration(unit)

	if not durationData then
		return
	end

	for _, watcher in pairs(watchers) do
		if watcher.Container and watcher.Unit == unit then
			SetIconState(watcher.Container, durationData)
			break
		end
	end
end

local function RefreshAll()
	for _, watcher in pairs(watchers) do
		local unit = watcher.Unit
		local container = watcher.Container

		if container and unit and UnitExists(unit) then
			SetIconState(container, trinketsTracker:GetUnitDuration(unit))
		elseif container then
			-- Show default icon when unit doesn't exist
			SetIconState(container, nil)
		end
	end
end

local function UpdateVisibility()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Trinkets)
	local show = moduleEnabled and (IsInArena() or testModeActive)

	for _, watcher in pairs(watchers) do
		if watcher.Container and watcher.Anchor then
			if show then
				local anchor = watcher.Anchor
				local unit = anchor.unit or (anchor.GetAttribute and anchor:GetAttribute("unit"))
				local shouldExclude = options.ExcludePlayer and unit and UnitIsUnit(unit, "player")
				if shouldExclude then
					watcher.Container.Frame:Hide()
				elseif anchor:IsVisible() then
					watcher.Container.Frame:SetAlpha(1)
					watcher.Container.Frame:Show()
				else
					watcher.Container.Frame:Hide()
				end
			else
				watcher.Container.Frame:Hide()
			end
		end
	end
end

local function OnEvent(_, event)
	if paused then
		-- While paused, we still allow anchor rebuild + visibility so people can position frames
		RebuildAnchors()
		UpdateVisibility()
		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		M:Refresh()
	elseif event == "GROUP_ROSTER_UPDATE" then
		-- for some reason it doesn't work right away
		C_Timer.After(0, function()
			M:Refresh()
		end)
	end
end

-- Trinket cooldown data changes arrive via TrinketsTracker (arena cooldown updates and
-- match-state transitions); this module only re-renders the affected slot.
local function OnTrinketDataChanged(unit)
	if not enabled or paused then
		return
	end

	if unit then
		RefreshUnit(unit)
	else
		RefreshAll()
	end
end

local function RefreshTestTrinkets()
	local now = GetTime()

	-- Stagger durations so you can see different states
	local stateByUnit = {
		player = {
			start = now,
			duration = 90,
		},
		party1 = {
			start = now,
			duration = 120,
		},
		party2 = {
			start = now,
			duration = 60,
		},
		party3 = {
			start = now,
			duration = 45,
		},
	}

	for unit, state in pairs(stateByUnit) do
		UpdateUnit(unit, wowEx:CreateDuration(state.start, state.duration))
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

-- Lifecycle

---Trinket tracking reads the 12.1 trinket API and has no legacy equivalent.
---@return boolean
local function IsSupported()
	return USE_AURA_CONTAINERS
end

---@return TrinketsModuleOptions?
local function GetOptions()
	if not IsSupported() then
		return nil
	end

	return options
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Trinkets)
end

---Edge-triggered: the roster/world events are the module's only event source, so they are
---created on wake and torn down on sleep.
---@param active boolean
local function SetEventsActive(active)
	if active == enabled then
		return
	end

	enabled = active
	paused = not active

	if active then
		eventFrame = CreateFrame("Frame")
		eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
		eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
		eventFrame:SetScript("OnEvent", OnEvent)
	elseif eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame:SetScript("OnEvent", nil)
		eventFrame = nil
	end
end

local function Teardown()
	for anchorFrame in pairs(watchers) do
		DestroyWatcher(anchorFrame)
	end
end

local function EnsureFrames()
	RebuildAnchors()
end

---@param options TrinketsModuleOptions
local function ApplyOptions(options)
	UpdateVisibility()

	local size = tonumber(options.Icons.Size) or 32

	for _, watcher in pairs(watchers) do
		if watcher.Container then
			watcher.Container:SetIconSize(size)
		end
	end
end

---@param options TrinketsModuleOptions
local function UpdateContent(options)
	if IsInArena() then
		RefreshAll()
	elseif testModeActive then
		RefreshTestTrinkets()
	end
end

---@param active boolean
local function SetTestMode(active)
	if not IsSupported() then
		return
	end

	testModeActive = active

	if active then
		Pause()
	else
		ClearAll()
		Resume()
	end

	M:Refresh()
end

local function InstallHooks()
	trinketsTracker:RegisterCallback(OnTrinketDataChanged)
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
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent(options)
end

function M:Init()
	if not IsSupported() then
		return
	end

	db = mini:GetSavedVars()
	options = db.Modules.TrinketsModule

	InstallHooks()
	ApplyInitialState()
end

---@class TrinketWatcher
---@field Anchor table
---@field Unit string
---@field Container IconSlotContainer
