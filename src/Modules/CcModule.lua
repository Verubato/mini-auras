---@type string, Addon
local _, addon = ...
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local IconSlotContainer = addon.Core.IconSlotContainer
local UnitAuraWatcher = addon.Core.UnitAuraWatcher
local capabilities = addon.Capabilities
local eventsFrame
local paused = false
local testModeActive = false
---@type table<table, CcWatchEntry>
local watchers = {}
---@type TestSpell[]
local testSpells = {}

---@class CcModule : IModule
local M = {}

addon.Modules.CcModule = M

---@class CcWatchEntry
---@field Container IconSlotContainer
---@field Watcher Watcher
---@field Anchor table
---@field Unit string

---@param entry CcWatchEntry
local function UpdateWatcherAuras(entry)
	if not entry or not entry.Watcher or not entry.Container then
		return
	end

	if paused then
		return
	end

	local options = instanceOptions:GetInstanceOptions()
	if not options or not options.Enabled then
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

	local options = testModeActive and instanceOptions:GetTestInstanceOptions()
		or instanceOptions:GetInstanceOptions()

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
			Unit = unit,
		}
		watchers[anchor] = entry
	else
		-- Check if unit has changed
		if entry.Unit ~= unit then
			-- Unit changed, recreate the watcher
			entry.Watcher:Dispose()
			entry.Watcher = UnitAuraWatcher:New(unit, nil, { CC = true })
			entry.Watcher:RegisterCallback(OnAuraStateUpdated)
			entry.Unit = unit

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()
		end

		local iconSize = tonumber(options.Icons.Size) or 32
		entry.Container:SetIconSize(iconSize)
		entry.Container:SetCount(options.Icons.Count or 3)
	end

	UpdateWatcherAuras(entry)
	M:AnchorContainer(entry.Container, anchor, options)
	frames:ShowHideFrame(entry.Container.Frame, anchor, testModeActive, options)

	return entry
end

local function EnsureWatchers()
	local anchors = frames:GetAll(true, testModeActive)

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

	local options = instanceOptions:GetInstanceOptions()

	if not options then
		return
	end

	frames:ShowHideFrame(entry.Container.Frame, frame, false, options)
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

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

function M:Hide()
	for _, entry in pairs(watchers) do
		entry.Container.Frame:Hide()
	end
end

function M:Refresh()
	local options = testModeActive and instanceOptions:GetTestInstanceOptions() or instanceOptions:GetInstanceOptions()

	if not options then
		return
	end

	EnsureWatchers()

	for anchor, entry in pairs(watchers) do
		local container = entry.Container
		local iconSize = tonumber(options.Icons.Size) or 32
		container:SetIconSize(iconSize)

		if not testModeActive then
			UpdateWatcherAuras(entry)
		end

		M:AnchorContainer(container, anchor, options)
		frames:ShowHideFrame(container.Frame, anchor, testModeActive, options)
	end
end

function M:StartTesting()
	-- Pause real watcher updates
	Pause()
	testModeActive = true

	-- Get test options
	local options = instanceOptions:GetTestInstanceOptions()
	if not options or not options.Enabled then
		testModeActive = false
		Resume()
		return
	end

	-- Create containers for all frames (including test frames)
	EnsureWatchers()

	-- Populate all containers with test data
	for anchor, entry in pairs(watchers) do
		local container = entry.Container
		local now = GetTime()

		container:ResetAllSlots()
		container:SetIconSize(tonumber(options.Icons.Size) or 32)
		container:SetCount(#testSpells)

		for i, spell in ipairs(testSpells) do
			local texture = C_Spell.GetSpellTexture(spell.SpellId)
			local duration = 15 + (i - 1) * 3
			local startTime = now - (i - 1) * 0.5

			container:SetSlotUsed(i)
			container:SetLayer(
				i,
				1,
				texture,
				startTime,
				duration,
				true,
				options.Icons.Glow,
				options.Icons.ReverseCooldown
			)
			container:FinalizeSlot(i, 1)
		end

		-- Anchor and show/hide based on anchor visibility
		M:AnchorContainer(container, anchor, options)
		frames:ShowHideFrame(container.Frame, anchor, true, options)
	end
end

function M:StopTesting()
	-- Clear all test data
	for _, entry in pairs(watchers) do
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end

	testModeActive = false

	-- Resume real watcher updates
	Resume()

	-- Refresh to show real data
	M:Refresh()
end

function M:Init()
	-- Initialize test spells
	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	local multipleTestSpells = { kidneyShot, fear, hex }
	testSpells = capabilities:HasNewFilters() and multipleTestSpells or { kidneyShot }

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

	EnsureWatchers()
end
