---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local units = addon.Utils.Units
local iconSlotContainer = addon.Core.IconSlotContainer
local UnitAuraWatcher = addon.Core.UnitAuraWatcher
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local slotDistribution = addon.Utils.SlotDistribution
local wowEx = addon.Utils.WoWEx
local kickTracker = addon.Core.KickTracker
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
-- Shared empty list returned when important isn't shown. Never mutate this.
local EMPTY = {}
-- Scratch tables reused by the important stack (avoids per-update allocations).
local importantOptionsScratch = {}
local importantSkipScratch = {}
-- Whether watchers are currently collecting helpful buffs (for the important slot). Tracked so a
-- config toggle can recreate watchers with the right filter instead of always paying the cost.
local importantWatchEnabled = false

local function GetOptions()
	local m = db.Modules.FriendlyIndicatorModule
	if not m then
		return nil
	end
	return instanceOptions:IsRaid() and m.Raid or m.Default
end

-- Whether either context (party/raid) wants the important slot, so watchers know to collect
-- helpful buffs. Checked across both because a watcher persists as the group type changes.
local function ImportantNeeded()
	local m = db.Modules.FriendlyIndicatorModule
	return m ~= nil and ((m.Default and m.Default.ShowImportant) or (m.Raid and m.Raid.ShowImportant)) or false
end

---@class FriendlyIndicatorModule : IModule
local M = {}

addon.Modules.FriendlyIndicatorModule = M

---@class FriendlyIndicatorWatchEntry
---@field Container IconSlotContainer
---@field Watcher Watcher
---@field Anchor table
---@field Unit string
---@field KickKey number

---@class FriendlyIndicatorModuleOptions
---@field ShowDefensives boolean
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
	local buffState = options.ShowImportant and entry.Watcher:GetBuffState() or EMPTY
	local kickEntry = options.ShowKicks ~= false and kickTracker:GetKick(entry.Unit) or nil

	local ccCount = options.ShowCC and #ccState or 0
	local defensiveCount = options.ShowDefensives and #defensiveState or 0
	-- Important collapses to a single stacked slot regardless of how many buffs the unit has.
	local importantCount = #buffState > 0 and 1 or 0

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

	-- Distribute remaining slots: CC first, then Defensive, then the important slot
	local remainingSlots = maxIcons - (slotIndex - 1)
	local ccSlots, defensiveSlots, importantSlots =
		slotDistribution.Calculate(remainingSlots, ccCount, defensiveCount, importantCount)

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

	-- Important spell: one stacked slot at the end that lets IsSpellImportant decide which buff
	-- shows. Exclude defensives already shown so a both-important-and-defensive aura isn't doubled.
	if importantSlots > 0 and slotIndex <= container.Count then
		local skipIds = nil
		if options.ShowDefensives then
			wipe(importantSkipScratch)
			for _, aura in ipairs(defensiveState) do
				if aura.AuraInstanceID then
					importantSkipScratch[aura.AuraInstanceID] = true
				end
			end
			skipIds = importantSkipScratch
		end

		importantOptionsScratch.Glow = iconsGlow
		importantOptionsScratch.ReverseCooldown = iconsReverse
		importantOptionsScratch.Color = nil
		importantOptionsScratch.FontScale = db.FontScale
		container:StackImportantBuffs(slotIndex, buffState, importantOptionsScratch, false, skipIds)
		slotIndex = slotIndex + 1
	end

	-- Clear any unused slots beyond the aura count
	for i = slotIndex, container.Count do
		container:SetSlotUnused(i)
	end
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
		local spacing = db.IconSpacing or 2
		local container = iconSlotContainer:New(UIParent, maxIcons, size, spacing, "Friendly Indicators", nil, "Friendly Indicators")
		local watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, CC = true, Buffs = ImportantNeeded() })

		entry = {
			Container = container,
			Watcher = watcher,
			Anchor = anchor,
			Unit = unit,
			KickKey = 0,
		}
		watchers[anchor] = entry

		watcher:RegisterCallback(function()
			UpdateWatcherAuras(entry)
		end)

		kickTracker:Watch(unit)
		entry.KickKey = kickTracker:Subscribe(unit, function()
			UpdateWatcherAuras(entry)
		end)
	else
		-- Check if unit has changed
		if entry.Unit ~= unit then
			-- Unit changed, recreate the watcher
			entry.Watcher:Dispose()
			entry.Watcher = UnitAuraWatcher:New(unit, nil, { Defensives = true, CC = true, Buffs = ImportantNeeded() })
			entry.Watcher:RegisterCallback(function()
				UpdateWatcherAuras(entry)
			end)

			kickTracker:Unsubscribe(entry.Unit, entry.KickKey)
			kickTracker:Watch(unit)
			entry.KickKey = kickTracker:Subscribe(unit, function()
				UpdateWatcherAuras(entry)
			end)

			entry.Unit = unit

			-- Clear the container since it's a different unit now
			entry.Container:ResetAllSlots()

			-- Force immediate refresh for the new unit
			UpdateWatcherAuras(entry)
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

	local options = GetOptions()

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
	local importantCount = options.ShowImportant and 1 or 0
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
		local ccSlots, defensiveSlots, importantSlots =
			slotDistribution.Calculate(remainingSlots, ccCount, defensiveCount, importantCount)

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

		-- Important test icon (shown directly; the live path gates it by IsSpellImportant)
		if importantSlots > 0 and slotIndex <= container.Count then
			local texture = C_Spell.GetSpellTexture(377362) -- precog
			if texture then
				container:SetSlot(slotIndex, {
					Texture = texture,
					DurationObject = wowEx:CreateDuration(now, 4),
					Alpha = true,
					ReverseCooldown = iconsReverse,
					Glow = iconsGlow,
					FontScale = db.FontScale,
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
	end
end

function M:Refresh()
	local options = GetOptions()

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

	-- If the important toggle changed, recreate existing watchers so they start/stop collecting
	-- helpful buffs (kept off by default to avoid scanning every aura on up to 40 raid frames).
	-- Containers are preserved; only the watcher is swapped.
	local needBuffs = ImportantNeeded()
	if needBuffs ~= importantWatchEnabled then
		importantWatchEnabled = needBuffs
		for _, entry in pairs(watchers) do
			if entry.Watcher then
				entry.Watcher:Dispose()
				entry.Watcher = UnitAuraWatcher:New(entry.Unit, nil, { Defensives = true, CC = true, Buffs = needBuffs })
				entry.Watcher:RegisterCallback(function()
					UpdateWatcherAuras(entry)
				end)
			end
		end
	end

	EnsureWatchers()

	for anchor, entry in pairs(watchers) do
		local container = entry.Container
		local iconSize = moduleUtil:GetIconSize(options.Icons, anchor, 32, 75)
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		container:SetIconSize(iconSize)
		container:SetSpacing(db.IconSpacing or 2)
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
