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

-- An arena counts as a raid, so party members answer to raid tokens as well.
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
-- Anchor frame -> its trinket slot.
---@type { [table]: TrinketWatcher }
local watchers = {}
-- Anchor frame -> its container. WoW frames can never be freed, so a released anchor's container
-- is parked and reused when the anchor comes back.
---@type { [table]: IconSlotContainer }
local containersByAnchor = {}
-- Anchors met during one walk, wiped at the top of it.
local seenScratch = {}
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

---Parks the anchor's container so the anchor can reuse it later.
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

local function TakeAnchor(anchor)
	if not anchor or (anchor.IsForbidden and anchor:IsForbidden()) then
		return
	end

	local unit = anchor.unit or (anchor.GetAttribute and anchor:GetAttribute("unit"))

	if unit and unit ~= "" and IsTrackedUnit(unit) then
		local watcher = EnsureWatcher(anchor, unit)
		seenScratch[anchor] = true
		AnchorContainerToFrame(watcher.Container, anchor)
	end
end

local function RebuildAnchors()
	wipe(seenScratch)

	frames:ForEachAnchor(true, testModeActive, TakeAnchor)

	for anchorFrame in pairs(watchers) do
		if not seenScratch[anchorFrame] then
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

	-- Every watcher on the unit, not just the first. Two frame addons on screen at once, or a
	-- custom anchor beside a party frame, give the same unit more than one icon.
	for _, watcher in pairs(watchers) do
		if watcher.Container and watcher.Unit == unit then
			SetIconState(watcher.Container, durationData)
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

function M:ClearAll()
	for _, w in pairs(watchers) do
		SetIconState(w.Container, nil)
	end
end

---Anchor discovery and visibility only. A paused module still has to follow the unit frames
---around so the icons can be positioned.
function M:RefreshAnchorsOnly()
	RebuildAnchors()
	UpdateVisibility()
end

function M:Init()
	db = mini:GetSavedVars()
	options = db.Modules.Trinkets
end

---@class TrinketWatcher
---@field Anchor table
---@field Unit string
---@field Container IconSlotContainer
