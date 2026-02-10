---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local scheduler = addon.Utils.Scheduler
local frames = addon.Core.Frames
local IconSlotContainer = addon.Core.IconSlotContainer
local UnitAuraWatcher = addon.Core.UnitAuraWatcher
local capabilities = addon.Capabilities
local eventsFrame
local paused = false
local db
---@type InstanceOptions|nil
local currentInstanceOptions
---@type table<table, CcWatchEntry>
local watchers = {}
---@class CcModule : IModule
local M = {}

addon.Modules.CcModule = M

---@class CcWatchEntry
---@field Container IconSlotContainer
---@field Watcher Watcher
---@field Anchor table

local function GetInstanceOptions()
	local inInstance, instanceType = IsInInstance()
	local isBgOrRaid = inInstance and (instanceType == "pvp" or instanceType == "raid")
	return isBgOrRaid and db.Raid or db.Default
end

---@param entry CcWatchEntry
local function UpdateWatcherAuras(entry)
	if not entry or not entry.Watcher or not entry.Container then
		return
	end

	if paused then
		return
	end

	local options = currentInstanceOptions
	if not options then
		return
	end

	local container = entry.Container
	local ccState = entry.Watcher:GetCcState()

	container:ResetAllSlots()

	local slotIndex = 1

	if capabilities:HasNewFilters() then
		-- Each aura gets its own slot
		for _, aura in ipairs(ccState) do
			if slotIndex > container.Count then
				break
			end

			container:SetLayer(
				slotIndex,
				1,
				aura.SpellIcon,
				aura.StartTime,
				aura.TotalDuration,
				aura.IsCC,
				options.Icons.Glow,
				options.Icons.ReverseCooldown
			)
			container:FinalizeSlot(slotIndex, 1)
			container:SetSlotUsed(slotIndex)
			slotIndex = slotIndex + 1
		end
	elseif #ccState > 0 then
		-- Stack all auras in one slot
		local layerIndex = 1
		for _, aura in ipairs(ccState) do
			container:SetLayer(
				slotIndex,
				layerIndex,
				aura.SpellIcon,
				aura.StartTime,
				aura.TotalDuration,
				aura.IsCC,
				options.Icons.Glow,
				options.Icons.ReverseCooldown
			)
			layerIndex = layerIndex + 1
		end
		container:FinalizeSlot(slotIndex, layerIndex - 1)
		container:SetSlotUsed(slotIndex)
		slotIndex = slotIndex + 1
	end
end

local function OnAuraStateUpdated(watcher)
	for _, entry in pairs(watchers) do
		if entry.Watcher == watcher then
			UpdateWatcherAuras(entry)
			break
		end
	end
end

---@param anchor table
---@param unit string?
local function EnsureWatcher(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")
	if not unit then
		return nil
	end

	local options = currentInstanceOptions

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local count = options.Icons.Count or 3
		local size = tonumber(options.Icons.Size) or 32
		local spacing = 2
		local container = IconSlotContainer:New(UIParent, count, size, spacing)
		local watcher = UnitAuraWatcher:New(unit, nil, { CC = true })

		watcher:RegisterCallback(OnAuraStateUpdated)

		entry = {
			Container = container,
			Watcher = watcher,
			Anchor = anchor,
		}
		watchers[anchor] = entry
	else
		local iconSize = tonumber(options.Icons.Size) or 32
		entry.Container:SetIconSize(iconSize)
		entry.Container:SetCount(options.Icons.Count or 3)
	end

	UpdateWatcherAuras(entry)
	M:AnchorContainer(entry.Container, anchor, options)
	frames:ShowHideFrame(entry.Container.Frame, anchor, false, options)

	return entry
end

local function EnsureWatchers()
	local anchors = frames:GetAll(true)

	for _, anchor in ipairs(anchors) do
		EnsureWatcher(anchor)
	end
end

local function OnCufUpdateVisible(frame)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	local entry = watchers[frame]

	if not entry then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		local instanceOptions = M:GetCurrentInstanceOptions()

		if not instanceOptions then
			return
		end

		frames:ShowHideFrame(entry.Container.Frame, frame, false, instanceOptions)
	end)
end

local function OnCufSetUnit(frame, unit)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	if not unit then
		return
	end

	EnsureWatcher(frame, unit)
end

local function OnFrameSortSorted()
	M:Refresh()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		M:Refresh()
	end
end

function M:GetContainers()
	local containers = {}
	for anchor, entry in pairs(watchers) do
		containers[anchor] = entry.Container
	end
	return containers
end

---@return InstanceOptions|nil
function M:GetCurrentInstanceOptions()
	return currentInstanceOptions
end

function M:RefreshInstanceOptions()
	currentInstanceOptions = GetInstanceOptions()

	return currentInstanceOptions
end

---@param header IconSlotContainer
---@param anchor table
---@param options InstanceOptions
function M:AnchorContainer(header, anchor, options)
	if not options then
		return
	end

	local frame = header.Frame
	frame:ClearAllPoints()
	frame:SetIgnoreParentAlpha(true)
	frame:SetAlpha(1)
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)
	frame:SetFrameStrata("HIGH")

	if options.SimpleMode.Enabled then
		local anchorPoint = "CENTER"
		local relativeToPoint = "CENTER"

		if options.SimpleMode.Grow == "LEFT" then
			anchorPoint = "RIGHT"
			relativeToPoint = "LEFT"
		elseif options.SimpleMode.Grow == "RIGHT" then
			anchorPoint = "LEFT"
			relativeToPoint = "RIGHT"
		end
		frame:SetPoint(anchorPoint, anchor, relativeToPoint, options.SimpleMode.Offset.X, options.SimpleMode.Offset.Y)
	elseif options.AdvancedMode then
		frame:SetPoint(
			options.AdvancedMode.Point,
			anchor,
			options.AdvancedMode.RelativePoint,
			options.AdvancedMode.Offset.X,
			options.AdvancedMode.Offset.Y
		)
	end
end

function M:Hide()
	for _, entry in pairs(watchers) do
		entry.Container.Frame:Hide()
	end
end

function M:Refresh()
	local options = M:RefreshInstanceOptions()

	if not options then
		return
	end

	-- avoid doing work in test mode
	if not paused then
		EnsureWatchers()
	end

	for anchor, entry in pairs(watchers) do
		local container = entry.Container
		local iconSize = tonumber(options.Icons.Size) or 32
		container:SetIconSize(iconSize)

		if not paused then
			UpdateWatcherAuras(entry)

			M:AnchorContainer(container, anchor, options)
			frames:ShowHideFrame(container.Frame, anchor, false, options)
		end
	end
end

function M:Pause()
	paused = true
end

function M:Resume()
	paused = false
end

function M:Init()
	db = mini:GetSavedVars()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	if CompactUnitFrame_SetUnit then
		hooksecurefunc("CompactUnitFrame_SetUnit", OnCufSetUnit)
	end

	if CompactUnitFrame_UpdateVisible then
		hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
	end

	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(OnFrameSortSorted)
	end

	M:RefreshInstanceOptions()
	EnsureWatchers()
end
