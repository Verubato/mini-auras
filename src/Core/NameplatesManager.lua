---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local units = addon.Utils.Units
local unitWatcher = addon.UnitAuraWatcher
local iconSlotContainer = addon.IconSlotContainer
local capabilities = addon.Capabilities
local paused = false
local wasDisabled = false
---@type Db
local db
---@type table<string, NameplateData>
local nameplateAnchors = {}
---@type table<string, Watcher>
local watchers = {}

---@class NameplateData
---@field Nameplate table
---@field CcContainer IconSlotContainer?
---@field ImportantContainer IconSlotContainer?
---@field UnitToken string

---@class NameplatesManager
local M = {}
addon.NameplatesManager = M

local function GetCcOptions(unitToken)
	local config = units:IsFriend(unitToken) and db.Nameplates.Friendly or db.Nameplates.Enemy
	return config.CC
end

local function GetImportantOptions(unitToken)
	local config = units:IsFriend(unitToken) and db.Nameplates.Friendly or db.Nameplates.Enemy
	return config.Important
end

---@return string anchorPoint
---@return string relativeToPoint
local function GetCcAnchorPoint(unitToken)
	local config = units:IsFriend(unitToken) and db.Nameplates.Friendly or db.Nameplates.Enemy
	local grow = config.CC.Grow

	local anchorPoint, relativeToPoint
	if grow == "LEFT" then
		anchorPoint, relativeToPoint = "RIGHT", "LEFT"
	elseif grow == "RIGHT" then
		anchorPoint, relativeToPoint = "LEFT", "RIGHT"
	else
		anchorPoint, relativeToPoint = "CENTER", "CENTER"
	end

	return anchorPoint, relativeToPoint
end

---@return string anchorPoint
---@return string relativeToPoint
local function GetImportantAnchorPoint(unitToken)
	local config = units:IsFriend(unitToken) and db.Nameplates.Friendly or db.Nameplates.Enemy
	local grow = config.Important.Grow

	local anchorPoint, relativeToPoint
	if grow == "LEFT" then
		anchorPoint, relativeToPoint = "RIGHT", "LEFT"
	elseif grow == "RIGHT" then
		anchorPoint, relativeToPoint = "LEFT", "RIGHT"
	else
		anchorPoint, relativeToPoint = "CENTER", "CENTER"
	end

	return anchorPoint, relativeToPoint
end

local function GetNameplateForUnit(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	return nameplate
end

local function CreateContainersForNameplate(nameplate, unitToken)
	local ccContainer = nil
	local importantContainer = nil
	local config = units:IsFriend(unitToken) and db.Nameplates.Friendly or db.Nameplates.Enemy

	-- Create CC container
	local ccOptions = config.CC
	if ccOptions and ccOptions.Enabled then
		local size = ccOptions.Icons.Size or 20
		local maxCount = ccOptions.Icons.MaxCount or 5
		local offsetX = ccOptions.Offset.X or 0
		local offsetY = ccOptions.Offset.Y or 5
		local grow = ccOptions.Grow
		local anchorPoint, relativeToPoint

		if grow == "LEFT" then
			anchorPoint, relativeToPoint = "RIGHT", "LEFT"
		elseif grow == "RIGHT" then
			anchorPoint, relativeToPoint = "LEFT", "RIGHT"
		else
			anchorPoint, relativeToPoint = "CENTER", "CENTER"
		end

		ccContainer = iconSlotContainer:New(nameplate, maxCount, size, 2)
		local frame = ccContainer.Frame
		frame:SetIgnoreParentScale(true)
		frame:SetIgnoreParentAlpha(true)
		frame:SetPoint(anchorPoint, nameplate, relativeToPoint, offsetX, offsetY)
		frame:SetFrameStrata("HIGH")
		frame:SetFrameLevel(nameplate:GetFrameLevel() + 10)
		frame:EnableMouse(false)
		frame:Show()
	end

	-- Create Important container
	local importantOptions = config.Important
	if importantOptions and importantOptions.Enabled then
		local size = importantOptions.Icons.Size or 20
		local maxCount = importantOptions.Icons.MaxCount or 5
		local offsetX = importantOptions.Offset.X or 0
		local offsetY = importantOptions.Offset.Y or 5
		local grow = importantOptions.Grow
		local anchorPoint, relativeToPoint

		if grow == "LEFT" then
			anchorPoint, relativeToPoint = "RIGHT", "LEFT"
		elseif grow == "RIGHT" then
			anchorPoint, relativeToPoint = "LEFT", "RIGHT"
		else
			anchorPoint, relativeToPoint = "CENTER", "CENTER"
		end

		importantContainer = iconSlotContainer:New(nameplate, maxCount, size, 2)
		local frame = importantContainer.Frame
		frame:SetIgnoreParentScale(true)
		frame:SetIgnoreParentAlpha(true)
		frame:SetPoint(anchorPoint, nameplate, relativeToPoint, offsetX, offsetY)
		frame:SetFrameStrata("HIGH")
		frame:SetFrameLevel(nameplate:GetFrameLevel() + 10)
		frame:EnableMouse(false)
		frame:Show()
	end

	return ccContainer, importantContainer
end

---@param data NameplateData
---@param watcher Watcher
---@param unitToken string
local function ApplyCcToNameplate(data, watcher, unitToken)
	local container = data.CcContainer
	if not container then
		return
	end

	local options = GetCcOptions(unitToken)
	if not options or not options.Enabled then
		return
	end

	local ccData = watcher:GetCcState()
	local ccDataCount = #ccData
	local hasNewFilters = capabilities:HasNewFilters()

	-- Clear only slots we'll potentially use
	local slotsNeeded = hasNewFilters and math.min(ccDataCount, container.Count) or 1
	for i = 1, slotsNeeded do
		container:ClearSlot(i)
		container:SetSlotUnused(i)
	end

	-- Clear remaining slots if they were used before
	for i = slotsNeeded + 1, container.Count do
		container:ClearSlot(i)
		container:SetSlotUnused(i)
	end

	if ccDataCount == 0 then
		return
	end

	local slotIndex = 1
	local ccLayerIndex = 1
	local iconsGlow = options.Icons.Glow
	local iconsReverse = options.Icons.ReverseCooldown

	for _, spellInfo in ipairs(ccData) do
		if slotIndex > container.Count then
			break
		end

		container:SetSlotUsed(slotIndex)
		container:SetLayer(
			slotIndex,
			ccLayerIndex,
			spellInfo.SpellIcon,
			spellInfo.StartTime,
			spellInfo.TotalDuration,
			spellInfo.IsCC,
			iconsGlow,
			iconsReverse
		)

		if hasNewFilters then
			-- we're on 12.0.1 and can show multiple cc's
			container:FinalizeSlot(slotIndex, 1)
			slotIndex = slotIndex + 1
		else
			-- can only show 1 cc
			ccLayerIndex = ccLayerIndex + 1
		end
	end

	-- Finalize the single slot if not using new filters
	if not hasNewFilters and ccLayerIndex > 1 then
		container:FinalizeSlot(1, ccLayerIndex - 1)
	end
end

---@param data NameplateData
---@param watcher Watcher
---@param unitToken string
local function ApplyImportantSpellsToNameplate(data, watcher, unitToken)
	local container = data.ImportantContainer
	if not container then
		return
	end

	local options = GetImportantOptions(unitToken)
	if not options or not options.Enabled then
		return
	end

	local slot = 1
	local defensivesData = watcher:GetDefensiveState()
	local importantData = watcher:GetImportantState()
	local slotsNeeded = #defensivesData + (#importantData > 0 and 1 or 0)

	if #importantData > 0 then
		container:ClearSlot(slot)
		container:SetSlotUsed(slot)

		local used = 0
		for _, spellData in ipairs(importantData) do
			used = used + 1
			container:SetLayer(
				slot,
				used,
				spellData.SpellIcon,
				spellData.StartTime,
				spellData.TotalDuration,
				spellData.IsImportant,
				options.Icons.Glow,
				options.Icons.ReverseCooldown
			)
		end

		container:FinalizeSlot(slot, used)

		slot = slot + 1
	else
		container:ClearSlot(slot)
		container:SetSlotUnused(slot)
	end

	if #defensivesData > 0 then
		for _, spellData in ipairs(defensivesData) do
			container:ClearSlot(slot)
			container:SetSlotUsed(slot)

			container:SetLayer(
				slot,
				1,
				spellData.SpellIcon,
				spellData.StartTime,
				spellData.TotalDuration,
				spellData.IsDefensive,
				options.Icons.Glow,
				options.Icons.ReverseCooldown
			)

			container:FinalizeSlot(slot, 1)
			slot = slot + 1
		end
	else
		container:ClearSlot(slot)
		container:SetSlotUnused(slot)
	end

	if slotsNeeded == 0 then
		container:ResetAllSlots()
	else
		-- clear any slots above what we used
		for i = slotsNeeded + 1, container.Count do
			container:ClearSlot(i)
			container:SetSlotUnused(i)
		end
	end
end

local function OnAuraDataChanged(unitToken)
	if paused or not unitToken then
		return
	end

	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	local watcher = watchers[unitToken]
	if not watcher then
		return
	end

	ApplyCcToNameplate(data, watcher, unitToken)
	ApplyImportantSpellsToNameplate(data, watcher, unitToken)
end

local function OnNamePlateAdded(unitToken)
	local nameplate = GetNameplateForUnit(unitToken)
	if not nameplate then
		return
	end

	-- Clean up any existing data for this unit token first
	-- (unit tokens can be reused for different units)
	if nameplateAnchors[unitToken] then
		OnNamePlateRemoved(unitToken)
	end

	-- Create fresh containers
	local ccContainer, importantContainer = CreateContainersForNameplate(nameplate, unitToken)

	if not ccContainer and not importantContainer then
		return
	end

	-- Create new nameplate data
	nameplateAnchors[unitToken] = {
		Nameplate = nameplate,
		CcContainer = ccContainer,
		ImportantContainer = importantContainer,
		UnitToken = unitToken,
	}

	-- Create new watcher
	watchers[unitToken] = unitWatcher:New(unitToken)
	watchers[unitToken]:RegisterCallback(function()
		OnAuraDataChanged(unitToken)
	end)

	-- Initial update
	OnAuraDataChanged(unitToken)
end

local function OnNamePlateRemoved(unitToken)
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	-- Completely dispose of containers
	if data.CcContainer then
		data.CcContainer:ResetAllSlots()
		data.CcContainer.Frame:Hide()
	end

	if data.ImportantContainer then
		data.ImportantContainer:ResetAllSlots()
		data.ImportantContainer.Frame:Hide()
	end

	-- Dispose of watcher
	if watchers[unitToken] then
		watchers[unitToken]:Dispose()
		watchers[unitToken] = nil
	end

	-- Remove all data for this unit token
	nameplateAnchors[unitToken] = nil
end

local function OnNamePlateUpdate(unitToken)
	-- Nameplate might have been recreated, update our reference
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	local newNameplate = GetNameplateForUnit(unitToken)
	if newNameplate and newNameplate ~= data.Nameplate then
		-- Nameplate changed, fully recreate
		OnNamePlateRemoved(unitToken)
		OnNamePlateAdded(unitToken)
	end
end

local function ClearNameplate(unitToken)
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	-- Completely dispose of containers
	if data.CcContainer then
		data.CcContainer:ResetAllSlots()
	end

	if data.ImportantContainer then
		data.ImportantContainer:ResetAllSlots()
	end
end

local function RefreshNameplates()
	local count = 0
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.namePlateUnitToken
		if unitToken then
			OnNamePlateAdded(unitToken)
			count = count + 1
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()

	local eventFrame = CreateFrame("Frame")
	eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
	eventFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "NAME_PLATE_UNIT_ADDED" then
			OnNamePlateAdded(unitToken)
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		elseif event == "PLAYER_TARGET_CHANGED" then
			-- Update target nameplate
			if UnitExists("target") then
				local targetToken = "target"
				OnNamePlateUpdate(targetToken)
			end
		end
	end)

	local anyEnabled = db.Nameplates.Friendly.CC.Enabled
		or db.Nameplates.Friendly.Important.Enabled
		or db.Nameplates.Enemy.CC.Enabled
		or db.Nameplates.Enemy.Important.Enabled

	if anyEnabled then
		-- Initialize existing nameplates
		RefreshNameplates()
	else
		wasDisabled = true
	end
end

---@return NameplateData
function M:GetAllContainers()
	-- ensure containers exist
	-- might be test mode calling is
	RefreshNameplates()

	local containers = {}

	for _, anchor in pairs(nameplateAnchors) do
		containers[#containers + 1] = anchor
	end

	return containers
end

function M:Refresh()
	local anyEnabled = db.Nameplates.Friendly.CC.Enabled
		or db.Nameplates.Friendly.Important.Enabled
		or db.Nameplates.Enemy.CC.Enabled
		or db.Nameplates.Enemy.Important.Enabled

	if not anyEnabled then
		M:ClearAll()
		return
	elseif wasDisabled then
		RefreshNameplates()
		wasDisabled = false
	end

	for _, data in pairs(nameplateAnchors) do
		if data.Nameplate and data.UnitToken then
			local ccAnchorPoint, ccRelativeToPoint = GetCcAnchorPoint(data.UnitToken)
			local ccOptions = GetCcOptions(data.UnitToken)
			local ccContainer = data.CcContainer

			if ccContainer and ccAnchorPoint and ccRelativeToPoint and ccOptions then
				ccContainer.Frame:ClearAllPoints()

				if ccOptions.Enabled then
					ccContainer.Frame:SetPoint(
						ccAnchorPoint,
						data.Nameplate,
						ccRelativeToPoint,
						ccOptions.Offset.X,
						ccOptions.Offset.Y
					)
					ccContainer:SetIconSize(ccOptions.Icons.Size)
				end
			end

			local importantAnchorPoint, importantRelativeToPoint = GetImportantAnchorPoint(data.UnitToken)
			local importantOptions = GetImportantOptions(data.UnitToken)
			local importantContainer = data.ImportantContainer

			if importantContainer and importantAnchorPoint and importantRelativeToPoint and importantOptions then
				importantContainer.Frame:ClearAllPoints()

				if importantOptions.Enabled then
					importantContainer.Frame:SetPoint(
						importantAnchorPoint,
						data.Nameplate,
						importantRelativeToPoint,
						importantOptions.Offset.X,
						importantOptions.Offset.Y
					)
					importantContainer:SetIconSize(importantOptions.Icons.Size)
				end
			end
		end
	end
end

function M:Pause()
	paused = true
end

function M:Resume()
	paused = false

	-- Refresh all nameplates
	for unitToken, _ in pairs(nameplateAnchors) do
		OnAuraDataChanged(unitToken)
	end
end

function M:ClearAll()
	-- Clean up all existing nameplates
	for unitToken, _ in pairs(nameplateAnchors) do
		ClearNameplate(unitToken)
	end
end
