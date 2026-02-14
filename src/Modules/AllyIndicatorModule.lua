---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local UnitAuraWatcher = addon.Core.UnitAuraWatcher
local spellCache = addon.Utils.SpellCache
local eventsFrame
local paused = false
local testModeActive = false
---@type table<table, AllyIndicatorWatchEntry>
local watchers = {}
---@type TestSpell[]
local testDefensiveSpells = {}
---@type TestSpell[]
local testImportantSpells = {}
---@type Db
local db

---@class AllyIndicatorModule : IModule
local M = {}

addon.Modules.AllyIndicatorModule = M

---@class AllyIndicatorWatchEntry
---@field Container IconSlotContainer
---@field Watcher Watcher
---@field Anchor table
---@field Unit string

---@param entry AllyIndicatorWatchEntry
local function UpdateWatcherAuras(entry)
	if not entry or not entry.Watcher or not entry.Container then
		return
	end

	if paused then
		return
	end

	if not entry.Unit or not UnitExists(entry.Unit) then
		return
	end

	local options = db.AllyIndicator
	if not options or not options.Enabled then
		return
	end

	-- Cache config options for performance
	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local container = entry.Container

	-- Get both defensive and important states
	local defensiveState = entry.Watcher:GetDefensiveState()
	local importantState = entry.Watcher:GetImportantState()

	container:ResetAllSlots()

	-- Priority: Defensive -> Important
	local auraToShow = nil
	local alpha = nil

	if #defensiveState > 0 then
		auraToShow = defensiveState[#defensiveState]
		if auraToShow then
			alpha = auraToShow.IsDefensive
		end
	elseif #importantState > 0 then
		auraToShow = importantState[#importantState]
		if auraToShow then
			alpha = auraToShow.IsImportant
		end
	end

	if auraToShow then
		container:SetSlotUsed(1)
		container:SetLayer(1, 1, {
			Texture = auraToShow.SpellIcon,
			StartTime = auraToShow.StartTime,
			Duration = auraToShow.TotalDuration,
			AlphaBoolean = alpha,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
		})
		container:FinalizeSlot(1, 1)
	end
end

---@param header IconSlotContainer
---@param anchor table
---@param options AllyIndicatorOptions
local function AnchorContainer(header, anchor, options)
	if not options then
		return
	end

	local frame = header.Frame
	frame:ClearAllPoints()
	frame:SetIgnoreParentAlpha(true)
	frame:SetIgnoreParentScale(true)
	frame:SetAlpha(1)
	frame:SetFrameLevel(anchor:GetFrameLevel() + 5)
	frame:SetFrameStrata("HIGH")

	local anchorPoint = "CENTER"
	local relativeToPoint = "CENTER"

	if options.Grow == "LEFT" then
		anchorPoint = "RIGHT"
		relativeToPoint = "LEFT"
	elseif options.Grow == "RIGHT" then
		anchorPoint = "LEFT"
		relativeToPoint = "RIGHT"
	end

	frame:SetPoint(anchorPoint, anchor, relativeToPoint, options.Offset.X, options.Offset.Y)
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

	local options = db.AllyIndicator

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local size = tonumber(options.Icons.Size) or 32
		local spacing = 2
		local container = iconSlotContainer:New(UIParent, 1, size, spacing)
		container.Frame:SetIgnoreParentScale(true)
		container.Frame:SetIgnoreParentAlpha(true)
		local watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, Important = true })

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
			entry.Watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, Important = true })
			entry.Watcher:RegisterCallback(OnAuraStateUpdated)
			entry.Unit = unit

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()

			-- Force immediate aura scan for the new unit
			entry.Watcher:ForceFullUpdate()
		end

		local iconSize = tonumber(options.Icons.Size) or 32
		entry.Container:SetIconSize(iconSize)
	end

	UpdateWatcherAuras(entry)
	AnchorContainer(entry.Container, anchor, options)
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

	local options = db.AllyIndicator

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

	if units:IsCompoundUnit(unit) then
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

local function RefreshTestIcons()
	local options = db.AllyIndicator

	if not options then
		return
	end

	-- ensure predictable ordering for showing the test spell icon on visible entries
	local orderedEntries = {}
	for _, entry in pairs(watchers) do
		if entry.Anchor and entry.Anchor:IsShown() then
			table.insert(orderedEntries, entry)
		end
	end

	for index, entry in ipairs(orderedEntries) do
		local container = entry.Container
		local now = GetTime()

		container:ResetAllSlots()
		container:SetIconSize(tonumber(options.Icons.Size) or 50)

		local spell = index % 2 == 0 and testImportantSpells[1] or testDefensiveSpells[1]

		if spell then
			local texture = spellCache:GetSpellTexture(spell.SpellId)

			if texture then
				local duration = 15
				local startTime = now

				container:SetSlotUsed(1)

				container:SetLayer(1, 1, {
					Texture = texture,
					StartTime = startTime,
					Duration = duration,
					AlphaBoolean = true,
					ReverseCooldown = options.Icons.ReverseCooldown,
					Glow = options.Icons.Glow,
				})
				container:FinalizeSlot(1, 1)
			end
		end

		AnchorContainer(container, entry.Anchor, options)
		frames:ShowHideFrame(container.Frame, entry.Anchor, true, options)
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

local function Hide()
	for _, entry in pairs(watchers) do
		entry.Container.Frame:Hide()
	end
end

function M:Refresh()
	local options = db.AllyIndicator

	if not options then
		return
	end

	-- If disabled, hide everything and return
	if not options.Enabled then
		Hide()
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

		AnchorContainer(container, anchor, options)
		frames:ShowHideFrame(container.Frame, anchor, testModeActive, options)
	end

	if testModeActive then
		RefreshTestIcons()
	end
end

function M:StartTesting()
	-- Pause real watcher updates
	Pause()
	testModeActive = true

	M:Refresh()
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
	db = mini:GetSavedVars()

	local painSupp = { SpellId = 33206 }
	local combustion = { SpellId = 190319 }
	testDefensiveSpells = { painSupp }
	testImportantSpells = { combustion }

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

---@class AllyIndicatorModule
---@field Init fun(self: AllyIndicatorModule)
---@field Refresh fun(self: AllyIndicatorModule)
---@field StartTesting fun(self: AllyIndicatorModule)
---@field StopTesting fun(self: AllyIndicatorModule)
