---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local testModeActive = false
local paused = false
local inPrepRoom = false
local eventsFrame
---@type Db
local db
---@type IconSlotContainer
local container
---@type Watcher[]
local watchers

---@class AlertsModule : IModule
local M = {}
addon.Modules.AlertsModule = M

local function OnAuraDataChanged()
	if paused then
		return
	end

	if not moduleUtil:IsModuleEnabled(moduleName.Alerts) then
		return
	end

	if inPrepRoom then
		-- don't know why it picks up garbage in the starting room
		container:ResetAllSlots()
		return
	end

	local iconsGlow = db.Modules.AlertsModule.Icons.Glow
	local iconsReverse = db.Modules.AlertsModule.Icons.ReverseCooldown
	local colorByClass = db.Modules.AlertsModule.Icons.ColorByClass
	local slot = 0

	for _, watcher in ipairs(watchers) do
		if slot > container.Count then
			break
		end

		local unit = watcher:GetUnit()

		-- when units go stealth, we can't get their aura data anymore
		if unit and UnitExists(unit) then
			local glowColor = nil

			-- Get class color if the option is enabled
			if colorByClass and iconsGlow then
				local _, class = UnitClass(unit)
				if class then
					local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
					if classColor then
						glowColor = { r = classColor.r, g = classColor.g, b = classColor.b, a = 1 }
					end
				end
			end

			local defensivesData = watcher:GetDefensiveState()
			local importantData = watcher:GetImportantState()

			if #importantData > 0 then
				for _, data in ipairs(importantData) do
					slot = slot + 1
					container:ClearSlot(slot)
					container:SetSlotUsed(slot)
					container:SetLayer(slot, 1, {
						Texture = data.SpellIcon,
						StartTime = data.StartTime,
						Duration = data.TotalDuration,
						AlphaBoolean = data.IsImportant,
						Glow = iconsGlow,
						ReverseCooldown = iconsReverse,
						Color = glowColor,
						FontScale = db.FontScale,
					})
					container:FinalizeSlot(slot, 1)
				end
			end

			if #defensivesData > 0 then
				-- we only get defensive data with new filters
				for _, data in ipairs(defensivesData) do
					slot = slot + 1
					container:ClearSlot(slot)
					container:SetSlotUsed(slot)
					container:SetLayer(slot, 1, {
						Texture = data.SpellIcon,
						StartTime = data.StartTime,
						Duration = data.TotalDuration,
						AlphaBoolean = data.IsDefensive,
						Glow = iconsGlow,
						ReverseCooldown = iconsReverse,
						Color = glowColor,
						FontScale = db.FontScale,
					})
					container:FinalizeSlot(slot, 1)
				end
			end
		end
	end

	-- advance forward by 1 for clearing
	if slot > 0 then
		slot = slot + 1
	end

	if slot == 0 then
		container:ResetAllSlots()
	else
		-- clear any slots above what we used
		for i = slot, container.Count do
			container:SetSlotUnused(i)
		end
	end
end

local function OnMatchStateChanged()
	local matchState = C_PvP.GetActiveMatchState()

	inPrepRoom = matchState == Enum.PvPMatchState.StartUp

	if not inPrepRoom then
		return
	end

	for _, watcher in ipairs(watchers) do
		watcher:ClearState(true)
	end

	container:ResetAllSlots()
end

local function RefreshTestAlerts()
	container:ResetAllSlots()

	local testAlertSpellIds = {
		190319, -- Combustion
		121471, -- Shadow Blades
		107574, -- Avatar
	}

	-- Test class colors for demo purposes
	local testClassColors = {
		"MAGE",
		"ROGUE",
		"WARRIOR",
	}

	local count = math.min(#testAlertSpellIds, container.Count or #testAlertSpellIds)
	local now = GetTime()
	local colorByClass = db.Modules.AlertsModule.Icons.ColorByClass
	local iconsGlow = db.Modules.AlertsModule.Icons.Glow

	for i = 1, count do
		container:SetSlotUsed(i)

		local spellId = testAlertSpellIds[i]
		local tex = spellCache:GetSpellTexture(spellId)

		if tex then
			local duration = 12 + (i - 1) * 3
			local startTime = now - (i - 1) * 1.25

			local glowColor = nil
			if colorByClass and iconsGlow and testClassColors[i] then
				local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[testClassColors[i]]
				if classColor then
					glowColor = { r = classColor.r, g = classColor.g, b = classColor.b, a = 1 }
				end
			end

			container:SetLayer(i, 1, {
				Texture = tex,
				StartTime = startTime,
				Duration = duration,
				AlphaBoolean = true,
				Glow = iconsGlow,
				ReverseCooldown = db.Modules.AlertsModule.Icons.ReverseCooldown,
				Color = glowColor,
				FontScale = db.FontScale,
			})

			container:FinalizeSlot(i, 1)
		end
	end
end

local function EnableDisable()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Alerts)

	if moduleEnabled then
		for _, watcher in ipairs(watchers) do
			watcher:Enable()
		end

		OnAuraDataChanged()
	else
		for _, watcher in ipairs(watchers) do
			watcher:Disable()
		end
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
	OnAuraDataChanged()
end

local function ClearAll()
	if not container then
		return
	end

	container:ResetAllSlots()
end

function M:Refresh()
	local options = db.Modules.AlertsModule

	EnableDisable()

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Alerts)

	-- If disabled, clear and return
	if not moduleEnabled then
		ClearAll()
		return
	end

	container.Frame:ClearAllPoints()
	container.Frame:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	container:SetIconSize(options.Icons.Size)

	if testModeActive then
		RefreshTestAlerts()
	end
end

function M:StartTesting()
	testModeActive = true
	Pause()
	M:Refresh()

	if not container then
		return
	end

	container.Frame:EnableMouse(true)
	container.Frame:SetMovable(true)
end

function M:StopTesting()
	testModeActive = false
	ClearAll()
	Resume()

	if not container then
		return
	end

	container.Frame:EnableMouse(false)
	container.Frame:SetMovable(false)
end

function M:Init()
	db = mini:GetSavedVars()

	local options = db.Modules.AlertsModule
	local count = 8
	local size = options.Icons.Size

	container = iconSlotContainer:New(UIParent, count, size, 2)
	container.Frame:SetIgnoreParentScale(true)

	local initialRelativeTo = _G[options.RelativeTo] or UIParent
	container.Frame:SetPoint(
		options.Point,
		initialRelativeTo,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)
	container.Frame:SetFrameStrata("HIGH")
	container.Frame:SetFrameLevel((initialRelativeTo:GetFrameLevel() or 0) + 5)
	container.Frame:EnableMouse(false)
	container.Frame:SetMovable(false)
	container.Frame:SetClampedToScreen(true)
	container.Frame:RegisterForDrag("LeftButton")
	container.Frame:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	container.Frame:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		options.Point = point
		options.RelativePoint = relativePoint
		options.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		options.Offset.X = x
		options.Offset.Y = y
	end)
	container.Frame:Show()

	local events = {
		-- seen/unseen
		"ARENA_OPPONENT_UPDATE",
	}

	watchers = {
		unitWatcher:New("arena1", events),
		unitWatcher:New("arena2", events),
		unitWatcher:New("arena3", events),
	}

	for _, watcher in ipairs(watchers) do
		watcher:RegisterCallback(OnAuraDataChanged)
	end

	eventsFrame = CreateFrame("Frame")
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:SetScript("OnEvent", OnMatchStateChanged)

	EnableDisable()
end
