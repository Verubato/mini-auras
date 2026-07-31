---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local UnitAuraWatcher = addon.Core.UnitAuraWatcher
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local slotDistribution = addon.Utils.SlotDistribution
local wowEx = addon.Utils.WoWEx
local kickTracker = addon.Core.KickTracker
-- 12.1 path: CC + defensive auras render through an AuraContainer per anchor (one group per
-- category); the IconSlotContainer is kept for the kick icon and test mode. Unlike the legacy
-- path there is no dynamic slot split between categories (aura counts are unreadable), so each
-- enabled category gets the full MaxIcons budget. TEMPORARY dual path: remove the watcher
-- branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local eventsFrame
local paused = false
local testModeActive = false
---@type table<table, FriendlyIndicatorWatchEntry>
local watchers = {}
---@type TestSpell[]
local testDefensiveSpells = {}
---@type TestSpell[]
local testCcSpells = {}
---@type Db
local db

local function GetOptions()
	local m = db.Modules.FriendlyIndicatorModule
	if not m then
		return nil
	end
	return instanceOptions:IsRaid() and m.Raid or m.Default
end

---@class FriendlyIndicatorModule : IModule
local M = {}

addon.Modules.FriendlyIndicatorModule = M

---@class FriendlyIndicatorWatchEntry
---@field Container IconSlotContainer On 12.1 this only renders the kick icon and test icons.
---@field Watcher Watcher? Legacy path only (nil on 12.1).
---@field Display AuraContainerDisplay? 12.1 path only: CC/defensive auras render through this.
---@field KickTimer table? 12.1 path only: timer that clears the kick icon on expiry.
---@field Anchor table
---@field Unit string
---@field KickKey number

---@class FriendlyIndicatorModuleOptions
---@field ShowDefensives boolean
---@field ShowImportant boolean 12.1 only: Blizzard-flagged important buffs.
---@field ShowCC boolean

---@param entry FriendlyIndicatorWatchEntry
local function UpdateWatcherAuras(entry)
	if not entry or not entry.Watcher or not entry.Container then
		return
	end

	if paused then
		return
	end

	if not entry.Unit then
		return
	end

	if not UnitExists(entry.Unit) then
		for i = 1, entry.Container.Count do
			entry.Container:SetSlotUnused(i)
		end
		return
	end

	local options = GetOptions()
	if not options or not moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator) then
		return
	end

	-- Cache config options for performance
	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local maxIcons = options.Icons.MaxIcons or 1
	local container = entry.Container
	local colorByDispelType = options.Icons.ColorByDispelType
	local showTooltips = options.ShowTooltips ~= false

	-- Get aura states
	local ccState = entry.Watcher:GetCcState()
	local defensiveState = entry.Watcher:GetDefensiveState()
	local kickEntry = options.ShowKicks ~= false and kickTracker:GetKick(entry.Unit) or nil

	local ccCount = options.ShowCC and #ccState or 0
	local defensiveCount = options.ShowDefensives and #defensiveState or 0

	local slotIndex = 1

	-- Kick is highest priority: always occupies slot 1 when active
	if kickEntry then
		container:SetSlot(slotIndex, {
			Texture = kickEntry.Texture,
			DurationObject = kickEntry.DurationObject,
			Color = colorByDispelType and kickEntry.Color,
			Alpha = true,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			FontScale = db.FontScale,
		})
		slotIndex = slotIndex + 1
	end

	-- Distribute remaining slots: CC first, then Defensive
	local remainingSlots = maxIcons - (slotIndex - 1)
	local ccSlots, defensiveSlots =
		slotDistribution.Calculate(remainingSlots, ccCount, defensiveCount, 0)

	for i = 1, ccSlots do
		if slotIndex > container.Count then
			break
		end
		local aura = ccState[i]
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			DurationObject = aura.DurationObject,
			Alpha = aura.IsCC,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			Color = colorByDispelType and aura.DispelColor,
			FontScale = db.FontScale,
			SpellId = showTooltips and aura.SpellId or nil,
		})
		slotIndex = slotIndex + 1
	end

	for i = 1, defensiveSlots do
		if slotIndex > container.Count then
			break
		end
		local aura = defensiveState[i]
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			DurationObject = aura.DurationObject,
			Alpha = aura.IsDefensive,
			ReverseCooldown = iconsReverse,
			Glow = iconsGlow,
			FontScale = db.FontScale,
			SpellId = showTooltips and aura.SpellId or nil,
		})
		slotIndex = slotIndex + 1
	end

	-- Clear any unused slots beyond the aura count
	for i = slotIndex, container.Count do
		container:SetSlotUnused(i)
	end
end

---12.1 path: positions the aura display on its anchor, chaining after the kick container while
---a kick icon is showing (the kick occupied slot 1 in the legacy layout).
---@param entry FriendlyIndicatorWatchEntry
---@param anchor table
---@param options table
local function AnchorAuraDisplay(entry, anchor, options)
	local display = entry.Display
	if not display then
		return
	end

	local frame = display.Frame
	if frame:GetParent() ~= anchor then
		frame:SetParent(anchor)
	end
	frame:SetIgnoreParentAlpha(db.FadeWithParent == false)
	frame:SetFrameStrata(frames:GetNextStrata(anchor:GetFrameStrata()))
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)

	local kickActive = options.ShowKicks ~= false and kickTracker:GetKick(entry.Unit) ~= nil
	display:AnchorAfterKick(
		entry.Container.Frame,
		anchor,
		options.Grow or "CENTER",
		options.IconSpacing or 2,
		options.Offset.X,
		options.Offset.Y,
		kickActive
	)
end

---12.1 path: renders the kick icon into the entry's IconSlotContainer (slot 1) and re-anchors
---the aura display around it.
---@param entry FriendlyIndicatorWatchEntry
local function UpdateKickIcon(entry)
	if not entry or not entry.Container or paused or testModeActive then
		return
	end

	local options = GetOptions()
	if not options or not moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator) then
		return
	end

	local kickEntry = options.ShowKicks ~= false and kickTracker:GetKick(entry.Unit) or nil
	local slotOptions = kickEntry and {
		Texture = kickEntry.Texture,
		DurationObject = kickEntry.DurationObject,
		Color = options.Icons.ColorByDispelType and kickEntry.Color,
		Alpha = true,
		ReverseCooldown = options.Icons.ReverseCooldown,
		Glow = options.Icons.Glow,
		FontScale = db.FontScale,
	} or nil

	entry.KickTimer = auraContainerDisplay:RenderKickSlot(entry.Container, kickEntry, slotOptions, entry.KickTimer, function()
		entry.KickTimer = nil
		UpdateKickIcon(entry)
	end)

	AnchorAuraDisplay(entry, entry.Anchor, options)
end

---@param header IconSlotContainer
---@param anchor table
---@param options FriendlyIndicatorInstanceOptions
local function AnchorContainer(header, anchor, options)
	if not options then
		return
	end

	local frame = header.Frame
	-- Parent to the anchor so the icons inherit its alpha and fade with the unit frame
	-- (e.g. when the unit goes out of range). Honour the FadeWithParent option: when disabled,
	-- ignore the parent's alpha so the icons stay fully opaque.
	if frame:GetParent() ~= anchor then
		frame:SetParent(anchor)
	end
	frame:SetIgnoreParentAlpha(db.FadeWithParent == false)
	frame:ClearAllPoints()
	frame:SetAlpha(1)
	frame:SetFrameStrata(frames:GetNextStrata(anchor:GetFrameStrata()))
	frame:SetFrameLevel(anchor:GetFrameLevel() + 1)

	local anchorPoint = "CENTER"
	local relativeToPoint = "CENTER"

	if options.Grow == "LEFT" then
		anchorPoint = "RIGHT"
		relativeToPoint = "LEFT"
	elseif options.Grow == "RIGHT" then
		anchorPoint = "LEFT"
		relativeToPoint = "RIGHT"
	elseif options.Grow == "DOWN" then
		anchorPoint = "TOP"
		relativeToPoint = "BOTTOM"
	elseif options.Grow == "UP" then
		anchorPoint = "BOTTOM"
		relativeToPoint = "TOP"
	end

	header:SetGrowDown(options.Grow == "DOWN")
	header:SetGrowUp(options.Grow == "UP")
	header:SetColumns(nil)
	frame:SetPoint(anchorPoint, anchor, relativeToPoint, options.Offset.X, options.Offset.Y)
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

	if units:IsPetOrMinion(unit) then
		return nil
	end

	local options = GetOptions()

	if not options then
		return
	end

	local entry = watchers[anchor]

	if not entry then
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		local size = moduleUtil:GetIconSize(options.Icons, anchor, 32, 75)
		local spacing = options.IconSpacing or 2
		local container = iconSlotContainer:New(UIParent, maxIcons, size, spacing, "Friendly Indicators", nil, "Friendly Indicators")

		entry = {
			Container = container,
			Anchor = anchor,
			Unit = unit,
			KickKey = 0,
		}
		watchers[anchor] = entry

		if USE_AURA_CONTAINERS then
			-- Filter negation partitions the groups so an aura only ever lands in one: EXTERNAL
			-- excludes BIG (they can overlap; legacy deduped by AuraInstanceID) and important
			-- excludes both defensive categories.
			-- The important group is a 12.1 addition with no legacy equivalent (the legacy path
			-- can't identify important buffs without the secret-alpha stacking trick).
			entry.Display = auraContainerDisplay:New(UIParent, unit, {
				{ Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = maxIcons },
				{ Key = "bigdef", FilterString = "HELPFUL|BIG_DEFENSIVE", MaxIcons = maxIcons },
				{ Key = "extdef", FilterString = "HELPFUL|EXTERNAL_DEFENSIVE|!BIG_DEFENSIVE", MaxIcons = maxIcons },
				{ Key = "important", FilterString = "HELPFUL|IMPORTANT|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE", MaxIcons = maxIcons },
			}, size, spacing, "Friendly Indicators")
		else
			entry.Watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, CC = true })
			entry.Watcher:RegisterCallback(function()
				UpdateWatcherAuras(entry)
			end)
		end

		kickTracker:Watch(unit)
		entry.KickKey = kickTracker:Subscribe(unit, function()
			if USE_AURA_CONTAINERS then
				UpdateKickIcon(entry)
			else
				UpdateWatcherAuras(entry)
			end
		end)
	else
		-- Check if unit has changed
		if entry.Unit ~= unit then
			if USE_AURA_CONTAINERS then
				-- The container tracks the new unit itself; only the unit token changes.
				entry.Display:SetUnit(unit)
			else
				-- Unit changed, recreate the watcher
				entry.Watcher:Dispose()
				entry.Watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, CC = true })
				entry.Watcher:RegisterCallback(function()
					UpdateWatcherAuras(entry)
				end)
			end

			kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				if USE_AURA_CONTAINERS then
					UpdateKickIcon(entry)
				else
					UpdateWatcherAuras(entry)
				end
			end)

			entry.Unit = unit

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()

			-- Force immediate refresh for the new unit
			if USE_AURA_CONTAINERS then
				UpdateKickIcon(entry)
			else
				UpdateWatcherAuras(entry)
			end
		end
	end

	if USE_AURA_CONTAINERS then
		UpdateKickIcon(entry)
	else
		UpdateWatcherAuras(entry)
	end
	AnchorContainer(entry.Container, anchor, options)

	if entry.Display then
		AnchorAuraDisplay(entry, anchor, options)
		frames:ShowHideFrame(entry.Display.Frame, anchor, false, options.ExcludePlayer)
	end

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

	local options = GetOptions()

	if not options then
		return
	end

	-- 12.1: the aura icons live in entry.Display, not the kick/test container - it must
	-- follow the unit frame's visibility too.
	if entry.Display then
		frames:ShowHideFrame(entry.Display.Frame, frame, false, options.ExcludePlayer)
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
	local options = GetOptions()

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

	local ccCount = options.ShowCC and #testCcSpells or 0
	local defensiveCount = options.ShowDefensives and #testDefensiveSpells or 0
	local showKicks = options.ShowKicks ~= false

	for _, entry in ipairs(orderedEntries) do
		local container = entry.Container
		local now = GetTime()
		local maxIcons = options.Icons.MaxIcons or 1
		local iconsReverse = options.Icons.ReverseCooldown
		local iconsGlow = options.Icons.Glow
		local colorByDispelType = options.Icons.ColorByDispelType
		local showTooltips = options.ShowTooltips ~= false

		local slotIndex = 1

		if showKicks then
			container:SetSlot(slotIndex, {
				Texture = C_Spell.GetSpellTexture(1766),
				DurationObject = wowEx:CreateDuration(now, 3),
				Alpha = true,
				ReverseCooldown = iconsReverse,
				Glow = iconsGlow,
				FontScale = db.FontScale,
			})
			slotIndex = slotIndex + 1
		end

		local remainingSlots = maxIcons - (slotIndex - 1)
		local ccSlots, defensiveSlots =
			slotDistribution.Calculate(remainingSlots, ccCount, defensiveCount, 0)

		for i = 1, ccSlots do
			if slotIndex > container.Count then
				break
			end
			local spell = testCcSpells[i]
			local texture = C_Spell.GetSpellTexture(spell.SpellId)
			if texture then
				container:SetSlot(slotIndex, {
					Texture = texture,
					DurationObject = wowEx:CreateDuration(now, 15),
					Alpha = true,
					ReverseCooldown = iconsReverse,
					Glow = iconsGlow,
					Color = colorByDispelType and spell.DispelColor,
					FontScale = db.FontScale,
					SpellId = showTooltips and spell.SpellId or nil,
				})
				slotIndex = slotIndex + 1
			end
		end

		for i = 1, defensiveSlots do
			if slotIndex > container.Count then
				break
			end
			local spell = testDefensiveSpells[i]
			local texture = C_Spell.GetSpellTexture(spell.SpellId)
			if texture then
				container:SetSlot(slotIndex, {
					Texture = texture,
					DurationObject = wowEx:CreateDuration(now, 15),
					Alpha = true,
					ReverseCooldown = iconsReverse,
					Glow = iconsGlow,
					FontScale = db.FontScale,
					SpellId = showTooltips and spell.SpellId or nil,
				})
				slotIndex = slotIndex + 1
			end
		end

		for i = slotIndex, container.Count do
			container:SetSlotUnused(i)
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

		if entry.Display then
			entry.Display:SetEnabled(false)
			entry.Display.Frame:Hide()
		end

		if entry.Container then
			entry.Container:ResetAllSlots()
			entry.Container.Frame:Hide()
		end
	end
end

local function EnableWatchers()
	for _, entry in pairs(watchers) do
		if entry.Watcher then
			entry.Watcher:Enable()
		end
		if entry.Display then
			entry.Display:SetEnabled(true)
		end
	end
end

function M:Refresh()
	local options = GetOptions()

	if not options then
		return
	end

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator)

	-- If disabled, disable watchers and hide everything. Events stay unregistered while
	-- disabled; the addon-wide Refresh (config, world change, raid flip) re-runs this gate.
	if not moduleEnabled then
		eventsFrame:UnregisterAllEvents()
		DisableWatchers()
		return
	end

	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	-- Module is enabled, ensure watchers are enabled
	EnableWatchers()
	EnsureWatchers()

	for anchor, entry in pairs(watchers) do
		local container = entry.Container
		local iconSize = moduleUtil:GetIconSize(options.Icons, anchor, 32, 75)
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		container:SetIconSize(iconSize)
		container:SetSpacing(options.IconSpacing or 2)
		container:SetCount(maxIcons)

		if entry.Display then
			entry.Display:SetIconSize(iconSize)
			entry.Display:SetSpacing(options.IconSpacing or 2)
			-- Category toggles map to a zero icon budget for the disabled group.
			entry.Display:SetMaxIcons("cc", options.ShowCC and maxIcons or 0)
			entry.Display:SetMaxIcons("bigdef", options.ShowDefensives and maxIcons or 0)
			entry.Display:SetMaxIcons("extdef", options.ShowDefensives and maxIcons or 0)
			entry.Display:SetMaxIcons("important", options.ShowImportant and maxIcons or 0)
			entry.Display:SetStyle({
				ReverseCooldown = options.Icons.ReverseCooldown,
				ColorByDispelType = options.Icons.ColorByDispelType,
				Glow = options.Icons.Glow,
				FontScale = db.FontScale,
				ShowTooltips = options.ShowTooltips ~= false,
			})
			entry.Display:SetEnabled(true)
		end

		if not testModeActive then
			if USE_AURA_CONTAINERS then
				UpdateKickIcon(entry)
			else
				UpdateWatcherAuras(entry)
			end
		end

		AnchorContainer(container, anchor, options)
		frames:ShowHideFrame(container.Frame, anchor, testModeActive, options.ExcludePlayer)

		if entry.Display then
			if testModeActive then
				-- Test icons render through the IconSlotContainer; hide the live aura display
				-- so real and fake icons don't mix.
				entry.Display.Frame:Hide()
			else
				AnchorAuraDisplay(entry, anchor, options)
				frames:ShowHideFrame(entry.Display.Frame, anchor, false, options.ExcludePlayer)
			end
		end
	end

	if testModeActive then
		RefreshTestIcons()
	end
end

function M:StartTesting()
	testModeActive = true
	Pause()

	M:Refresh()
end

function M:StopTesting()
	testModeActive = false

	for _, entry in pairs(watchers) do
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end

	Resume()
	M:Refresh()

	-- 12.1: repopulate the kick icons the test-mode reset wiped.
	if USE_AURA_CONTAINERS then
		for _, entry in pairs(watchers) do
			UpdateKickIcon(entry)
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()

	local painSupp = { SpellId = 33206 }
	local blessingOfProtection = { SpellId = 1022 }
	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	testDefensiveSpells = { painSupp, blessingOfProtection }
	testCcSpells = { kidneyShot, fear, hex }

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

	if DandersFrames and DandersFrames.RegisterCallback then
		DandersFrames.RegisterCallback(eventsFrame, "OnFramesSorted", function()
			M:Refresh()
		end)
	end

	frames:HookCellSpotlightVisibility(function()
		if moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator) then
			EnsureWatchers()
		end
	end)

	frames:HookNDuiVisibility(function()
		if moduleUtil:IsModuleEnabled(moduleName.FriendlyIndicator) then
			EnsureWatchers()
		end
	end)

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
