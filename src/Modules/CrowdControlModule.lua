---@type string, Addon
local _, addon = ...
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local unitAuraWatcher = addon.Core.UnitAuraWatcher
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local wowEx = addon.Utils.WoWEx
local eventsFrame
local paused = false
local testModeActive = false
---@type table<table, CrowdControlWatchEntry>
local watchers = {}
---@type TestSpell[]
local testSpells = {}

---@class CrowdControlModule : IModule
local M = {}

addon.Modules.CrowdControlModule = M

---@class CrowdControlWatchEntry
---@field Container IconSlotContainer
---@field Watcher Watcher
---@field Anchor table
---@field Unit string

---@param entry CrowdControlWatchEntry
local function UpdateWatcherAuras(entry)
	if not entry or not entry.Watcher or not entry.Container then
		return
	end

	if paused then
		return
	end

	local options = instanceOptions:GetInstanceOptions()
	if not options or not moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
		return
	end

	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local colorByDispelType = options.Icons.ColorByDispelType
	local container = entry.Container
	local ccState = entry.Watcher:GetCcState()
	local slotIndex = 1

	container:ResetAllSlots()

	-- Each aura gets its own slot
	for _, aura in ipairs(ccState) do
		if slotIndex > container.Count then
			break
		end

		container:SetLayer(slotIndex, 1, {
			Texture = aura.SpellIcon,
			StartTime = aura.StartTime,
			Duration = aura.TotalDuration,
			AlphaBoolean = aura.IsCC,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			Color = colorByDispelType and aura.DispelColor or nil,
			FontScale = addon.Core.Framework:GetSavedVars().FontScale,
		})
		container:FinalizeSlot(slotIndex, 1)
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

	local options = testModeActive and instanceOptions:GetTestInstanceOptions() or instanceOptions:GetInstanceOptions()

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local count = options.Icons.Count or 5
		local size = tonumber(options.Icons.Size) or 32
		local spacing = 2
		local container = iconSlotContainer:New(UIParent, count, size, spacing)
		local watcher = unitAuraWatcher:New(unit, nil, { CC = true })

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
			entry.Watcher = unitAuraWatcher:New(unit, nil, { CC = true })
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
	M:AnchorContainer(entry.Container, anchor, options)
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

	local options = instanceOptions:GetInstanceOptions()

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

	if units:IsCompoundUnit(unit) then
		-- in PvE ignore main tank and assist frames
		-- you can't scan them for auras
		return
	end

	EnsureWatcher(frame, unit)
end

local function OnFrameSortSorted()
	M:Refresh()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		-- wait for frame addons (danders/grid) to update
		C_Timer.After(0, function()
			M:Refresh()
		end)
	end
end

---@param header IconSlotContainer
---@param anchor table
---@param options CrowdControlInstanceOptions
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

local function RefreshTestIcons()
	local options = instanceOptions:GetTestInstanceOptions()

	if not options then
		return
	end

	-- Populate all containers with test data
	for anchor, entry in pairs(watchers) do
		local container = entry.Container
		local now = GetTime()

		container:SetIconSize(tonumber(options.Icons.Size) or 32)

		for i, spell in ipairs(testSpells) do
			local texture = spellCache:GetSpellTexture(spell.SpellId)

			if texture then
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5

				container:SetSlotUsed(i)

				container:SetLayer(i, 1, {
					Texture = texture,
					StartTime = startTime,
					Duration = duration,
					AlphaBoolean = true,
					ReverseCooldown = options.Icons.ReverseCooldown,
					Glow = options.Icons.Glow,
					Color = options.Icons.ColorByDispelType and spell.DispelColor,
					FontScale = addon.Core.Framework:GetSavedVars().FontScale,
				})
				container:FinalizeSlot(i, 1)
			end
		end

		-- Clear any unused slots beyond the test spell count
		for i = #testSpells + 1, container.Count do
			if container:IsSlotUsed(i) then
				container:SetSlotUnused(i)
			end
		end

		-- Anchor and show/hide based on anchor visibility
		M:AnchorContainer(container, anchor, options)
		frames:ShowHideFrame(container.Frame, anchor, true, options.ExcludePlayer)
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

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.CrowdControl)

	-- If disabled, hide everything and return
	if not moduleEnabled then
		M:Hide()
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
	-- Initialize test spells
	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	testSpells = { kidneyShot, fear, hex }

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

	EnsureWatchers()
end
