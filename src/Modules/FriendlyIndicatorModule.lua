---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local UnitAuraWatcher = addon.Core.UnitAuraWatcher
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local wowEx = addon.Utils.WoWEx
local eventsFrame
local paused = false
local testModeActive = false
---@type table<table, FriendlyIndicatorWatchEntry>
local watchers = {}
---@type TestSpell[]
local testDefensiveSpells = {}
---@type TestSpell[]
local testImportantSpells = {}
---@type Db
local db

---@class FriendlyIndicatorModule : IModule
local M = {}

addon.Modules.FriendlyIndicatorModule = M

---@class FriendlyIndicatorWatchEntry
---@field Container IconSlotContainer
---@field Watcher Watcher
---@field Anchor table
---@field Unit string

---@param entry FriendlyIndicatorWatchEntry
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

	local options = db.Modules.FriendlyIndicatorModule
	if not options or not moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator) then
		return
	end

	-- Cache config options for performance
	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local maxIcons = options.Icons.MaxIcons or 1
	local container = entry.Container

	-- Get both defensive and important states
	local defensiveState = entry.Watcher:GetDefensiveState()
	local importantState = entry.Watcher:GetImportantState()

	-- Combine all auras (defensive first, then important), filtered by options
	local allAuras = {}
	if options.ShowDefensives ~= false then
		for _, aura in ipairs(defensiveState) do
			table.insert(allAuras, { aura = aura, alpha = aura.IsDefensive })
		end
	end
	if options.ShowImportant ~= false then
		for _, aura in ipairs(importantState) do
			table.insert(allAuras, { aura = aura, alpha = aura.IsImportant })
		end
	end

	-- Display up to MaxIcons auras
	local slotIndex = 1
	for _, auraData in ipairs(allAuras) do
		if slotIndex > maxIcons or slotIndex > container.Count then
			break
		end

		local aura = auraData.aura
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			StartTime = aura.StartTime,
			Duration = aura.TotalDuration,
			AlphaBoolean = auraData.alpha,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			FontScale = db.FontScale,
		})
		slotIndex = slotIndex + 1
	end

	-- Clear any unused slots beyond the aura count
	for i = slotIndex, container.Count do
		container:SetSlotUnused(i)
	end
end

---@param header IconSlotContainer
---@param anchor table
---@param options FriendlyIndicatorModuleOptions
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

	if units:IsCompoundUnit(unit) then
		return nil
	end

	local options = db.Modules.FriendlyIndicatorModule

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		local size = tonumber(options.Icons.Size) or 32
		local spacing = 2
		local container = iconSlotContainer:New(UIParent, maxIcons, size, spacing)
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
	end

	UpdateWatcherAuras(entry)
	AnchorContainer(entry.Container, anchor, options)
	frames:ShowHideFrame(entry.Container.Frame, anchor, testModeActive, options.ExcludePlayer)

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

	local options = db.Modules.FriendlyIndicatorModule

	if not options then
		return
	end

	frames:ShowHideFrame(entry.Container.Frame, frame, false, options.ExcludePlayer)
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
		C_Timer.After(0, function()
			M:Refresh()
		end)
	end
end

local function RefreshTestIcons()
	local options = db.Modules.FriendlyIndicatorModule

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

	for _, entry in ipairs(orderedEntries) do
		local container = entry.Container
		local now = GetTime()
		local maxIcons = options.Icons.MaxIcons or 1

		container:SetIconSize(tonumber(options.Icons.Size) or 50)

		-- Build test pool from enabled types, alternating defensive/important when both are on
		local testPool = {}
		local showDefensives = options.ShowDefensives ~= false
		local showImportant = options.ShowImportant ~= false
		if showDefensives and showImportant then
			local defLen = #testDefensiveSpells
			local impLen = #testImportantSpells
			for i = 1, math.max(defLen, impLen) do
				table.insert(testPool, testDefensiveSpells[((i - 1) % defLen) + 1])
				table.insert(testPool, testImportantSpells[((i - 1) % impLen) + 1])
			end
		elseif showDefensives then
			for _, spell in ipairs(testDefensiveSpells) do
				table.insert(testPool, spell)
			end
		elseif showImportant then
			for _, spell in ipairs(testImportantSpells) do
				table.insert(testPool, spell)
			end
		end

		if #testPool == 0 then
			-- Both types disabled, clear all slots
			for i = 1, container.Count do
				container:SetSlotUnused(i)
			end
		else
			-- Fill up to MaxIcons test icons, cycling through the enabled pool
			for slotIndex = 1, math.min(maxIcons, container.Count) do
				local spell = testPool[((slotIndex - 1) % #testPool) + 1]

				if spell then
					local texture = spellCache:GetSpellTexture(spell.SpellId)

					if texture then
						local duration = 15
						local startTime = now

						container:SetSlot(slotIndex, {
							Texture = texture,
							StartTime = startTime,
							Duration = duration,
							AlphaBoolean = true,
							ReverseCooldown = options.Icons.ReverseCooldown,
							Glow = options.Icons.Glow,
							FontScale = db.FontScale,
						})
					end
				end
			end

			-- Clear any unused slots beyond maxIcons
			for i = maxIcons + 1, container.Count do
				container:SetSlotUnused(i)
			end
		end

		AnchorContainer(container, entry.Anchor, options)
		frames:ShowHideFrame(container.Frame, entry.Anchor, true, options.ExcludePlayer)
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

local function DisableWatchers()
	for _, entry in pairs(watchers) do
		if entry.Watcher then
			entry.Watcher:Disable()
		end

		if entry.Container then
			entry.Container:ResetAllSlots()
			entry.Container.Frame:Hide()
		end
	end

	paused = true
end

local function EnableWatchers()
	paused = false

	for _, entry in pairs(watchers) do
		if entry.Watcher then
			entry.Watcher:Enable()
		end
	end
end

function M:Refresh()
	local options = db.Modules.FriendlyIndicatorModule

	if not options then
		return
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator)

	-- If disabled, disable watchers and hide everything
	if not moduleEnabled then
		DisableWatchers()
		return
	end

	-- Module is enabled, ensure watchers are enabled
	EnableWatchers()
	EnsureWatchers()

	for anchor, entry in pairs(watchers) do
		local container = entry.Container
		local iconSize = tonumber(options.Icons.Size) or 32
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		container:SetIconSize(iconSize)
		container:SetCount(maxIcons)

		if not testModeActive then
			UpdateWatcherAuras(entry)
		end

		AnchorContainer(container, anchor, options)
		frames:ShowHideFrame(container.Frame, anchor, testModeActive, options.ExcludePlayer)
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
	local blessingOfProtection = { SpellId = 1022 }
	local combustion = { SpellId = 190319 }
	local shadowBlades = { SpellId = 121471 }
	testDefensiveSpells = { painSupp, blessingOfProtection }
	testImportantSpells = { combustion, shadowBlades }

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	if not wowEx:IsDandersEnabled() then
		if CompactUnitFrame_SetUnit then
			hooksecurefunc("CompactUnitFrame_SetUnit", OnCufSetUnit)
		end

		if CompactUnitFrame_UpdateVisible then
			hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
		end
	end

	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(OnFrameSortSorted)
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator)

	if moduleEnabled then
		EnsureWatchers()
	end
end

---@class FriendlyIndicatorModule
---@field Init fun(self: FriendlyIndicatorModule)
---@field Refresh fun(self: FriendlyIndicatorModule)
---@field StartTesting fun(self: FriendlyIndicatorModule)
---@field StopTesting fun(self: FriendlyIndicatorModule)
