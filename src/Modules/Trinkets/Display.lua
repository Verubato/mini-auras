---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local frames = addon.Core.Frames
local trinketsTracker = addon.Core.TrinketsTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

addon.Modules.Trinkets = addon.Modules.Trinkets or {}

---@class TrinketsDisplay
local M = {}
addon.Modules.Trinkets.Display = M

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
local testModeActive = false
-- Anchor frame -> its trinket slot. Owned here: the module asks for whole-set operations
-- rather than reaching into it.
---@type { [table]: TrinketWatcher }
local watchers = {}
-- Anchor frame -> its container, kept for the session: WoW frames can never be freed, so a
-- released anchor's container is parked (hidden, unanchored) and reused when the anchor returns
-- instead of building a replacement per roster flip.
---@type { [table]: IconSlotContainer }
local containersByAnchor = {}
---@type Db
local db
---@type TrinketsModuleOptions
local options

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
		Color = moduleUtil:GetIconColor(options.Icons),
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

	local container = containersByAnchor[anchorFrame]
	if not container then
		container = iconSlotContainer:New(UIParent, 1, tonumber(options.Icons.Size) or 32, 2, "Trinkets")
		containersByAnchor[anchorFrame] = container
	end

	watcher = {
		Anchor = anchorFrame,
		Unit = unit,
		Container = container,
	}
	watchers[anchorFrame] = watcher

	return watcher
end

---Parks the anchor's container rather than discarding it (see containersByAnchor).
local function ReleaseWatcher(anchorFrame)
	local watcher = watchers[anchorFrame]
	if not watcher then
		return
	end

	if watcher.Container then
		watcher.Container:ResetAllSlots()
		watcher.Container.Frame:Hide()
		watcher.Container.Frame:ClearAllPoints()
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
			ReleaseWatcher(anchorFrame)
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
					if testModeActive then
						moduleUtil:SetTestLabel(watcher.Container.Frame,
							L["Party Trinkets_Short"] or L["Party Trinkets"])
					end
				else
					watcher.Container.Frame:Hide()
				end
			else
				watcher.Container.Frame:Hide()
			end
		end
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

---@return TrinketsModuleOptions? nil until Init has read the saved variables
function M:GetOptions()
	return options
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

---Rebuilds the anchor set from the currently visible unit frames.
function M:EnsureFrames()
	RebuildAnchors()
end

function M:Teardown()
	for anchorFrame in pairs(watchers) do
		ReleaseWatcher(anchorFrame)
	end
end

function M:ApplyOptions()
	UpdateVisibility()

	local size = tonumber(options.Icons.Size) or 32

	for _, watcher in pairs(watchers) do
		if watcher.Container then
			watcher.Container:SetIconSize(size)
		end
	end
end

---Live cooldowns in an arena, the staggered fake ones in test mode, nothing elsewhere.
function M:UpdateContent()
	if IsInArena() then
		RefreshAll()
	elseif testModeActive then
		RefreshTestTrinkets()
	end
end

---Re-renders one unit's slot, or every slot when no unit is given.
---@param unit string?
function M:Render(unit)
	if unit then
		RefreshUnit(unit)
	else
		RefreshAll()
	end
end

---Blanks every slot back to the default icon.
function M:ClearAll()
	ClearAll()
end

---Anchor discovery and visibility only, for the paused case: the frames still have to follow
---the unit frames around so they can be positioned while the module is asleep.
function M:RefreshAnchorsOnly()
	RebuildAnchors()
	UpdateVisibility()
end

function M:Init()
	db = mini:GetSavedVars()
	options = db.Modules.TrinketsModule
end

---@class TrinketWatcher
---@field Anchor table
---@field Unit string
---@field Container IconSlotContainer
