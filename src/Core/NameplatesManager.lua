---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local unitWatcher = addon.UnitAuraWatcher
local iconSlotContainer = addon.IconSlotContainer
local paused = false
---@type Db
local db
---@type table<string, NameplateData>
local nameplateAnchors = {}
---@type table<string, Watcher>
local watchers = {}

---@class NameplateData
---@field nameplate table
---@field container IconSlotContainer
---@field unitToken string

---@class NameplatesManager
local M = {}
addon.NameplatesManager = M

---@return string anchorPoint
---@return string relativeToPoint
local function GetAnchorPoint()
	local anchorPoint = "CENTER"
	local relativeToPoint = "CENTER"

	if db.Nameplates.Grow == "LEFT" then
		anchorPoint = "RIGHT"
		relativeToPoint = "LEFT"
	elseif db.Nameplates.Grow == "RIGHT" then
		anchorPoint = "LEFT"
		relativeToPoint = "RIGHT"
	end

	return anchorPoint, relativeToPoint
end

local function GetNameplateForUnit(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	return nameplate
end

local function CreateContainerForNameplate(nameplate)
	if not nameplate then
		return nil
	end

	local size = db.Nameplates.Icons.Size or 20
	local maxCount = db.Nameplates.Icons.MaxCount or 5

	local container = iconSlotContainer:New(nameplate, maxCount, size, 2)
	container.Frame:SetIgnoreParentScale(true)

	local anchorPoint, relativeToPoint = GetAnchorPoint()
	local offsetX = db.Nameplates.Offset.X or 0
	local offsetY = db.Nameplates.Offset.Y or 5

	container.Frame:SetPoint(anchorPoint, nameplate, relativeToPoint, offsetX, offsetY)
	container.Frame:SetFrameStrata("HIGH")
	container.Frame:SetFrameLevel(nameplate:GetFrameLevel() + 10)
	container.Frame:EnableMouse(false)
	container.Frame:Show()

	return container
end

local function OnAuraDataChanged(unitToken)
	if paused then
		return
	end

	local data = nameplateAnchors[unitToken]
	if not data or not data.container then
		return
	end

	local watcher = watchers[unitToken]
	if not watcher then
		return
	end

	local container = data.container

	-- Clear all slots first
	for i = 1, container.Count do
		container:ClearSlot(i)
		container:SetSlotUnused(i)
	end

	local slotIndex = 1
	local ccData = watcher:GetCcState()
	for _, spellInfo in ipairs(ccData) do
		if slotIndex > container.Count then
			break
		end

		container:SetSlotUsed(slotIndex)
		container:SetLayer(
			slotIndex,
			1,
			spellInfo.SpellIcon,
			spellInfo.StartTime,
			spellInfo.TotalDuration,
			spellInfo.IsCC,
			db.Nameplates.Icons.Glow,
			db.Nameplates.Icons.ReverseCooldown
		)
		container:FinalizeSlot(slotIndex, 1)

		print("Filling slot", slotIndex, "with", C_Spell.GetSpellName(spellInfo.SpellId))

		slotIndex = slotIndex + 1
	end

	if slotIndex > container.Count then
		print("too many icons")
		return
	end

	-- note important spells already cover defensives, so don't double up
	local spellData = watcher:GetImportantState()

	if #spellData > 0 then
		container:SetSlotUsed(slotIndex)
	end

	for layerIndex, spellInfo in ipairs(spellData) do
		container:SetLayer(
			slotIndex,
			layerIndex,
			spellInfo.SpellIcon,
			spellInfo.StartTime,
			spellInfo.TotalDuration,
			spellInfo.IsImportant,
			db.Nameplates.Icons.Glow,
			db.Nameplates.Icons.ReverseCooldown
		)

		print(
			"Filling slot",
			slotIndex,
			"with",
			C_Spell.GetSpellName(spellInfo.SpellId),
			"IsShown",
			spellInfo.IsImportant
		)
	end

	if #spellData > 0 then
		container:FinalizeSlot(slotIndex, #spellData)
	end
end

local function OnNamePlateAdded(unitToken)
	if nameplateAnchors[unitToken] then
		return
	end

	local nameplate = GetNameplateForUnit(unitToken)
	if not nameplate then
		return
	end

	local container = CreateContainerForNameplate(nameplate)
	if not container then
		return
	end

	nameplateAnchors[unitToken] = {
		nameplate = nameplate,
		container = container,
		unitToken = unitToken,
	}

	-- Create watcher if it doesn't exist
	if not watchers[unitToken] then
		watchers[unitToken] = unitWatcher:New(unitToken, { "NAME_PLATE_UNIT_ADDED" })
		watchers[unitToken]:RegisterCallback(function()
			OnAuraDataChanged(unitToken)
		end)
	end

	-- Initial update
	OnAuraDataChanged(unitToken)
end

local function OnNamePlateRemoved(unitToken)
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	-- Clean up container
	if data.container then
		data.container:ResetAllSlots()
		data.container.Frame:Hide()
		data.container.Frame:SetParent(nil)
	end

	nameplateAnchors[unitToken] = nil
end

local function OnNamePlateUpdate(unitToken)
	-- Nameplate might have been recreated, update our reference
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	local newNameplate = GetNameplateForUnit(unitToken)
	if newNameplate and newNameplate ~= data.nameplate then
		-- Nameplate changed, recreate container
		OnNamePlateRemoved(unitToken)
		OnNamePlateAdded(unitToken)
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

	-- Initialize existing nameplates
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.namePlateUnitToken
		if unitToken then
			OnNamePlateAdded(unitToken)
		end
	end
end

function M:GetContainerForUnit(unitToken)
	local data = nameplateAnchors[unitToken]
	return data and data.container
end

function M:GetAllContainers()
	local containers = {}
	for _, data in pairs(nameplateAnchors) do
		if data.container then
			containers[#containers + 1] = data.container
		end
	end
	return containers
end

function M:Refresh()
	local options = db.Nameplates
	local anchorPoint, relativeToPoint = GetAnchorPoint()

	for _, data in pairs(nameplateAnchors) do
		if data.container and data.nameplate then
			local container = data.container

			container.Frame:ClearAllPoints()
			container.Frame:SetPoint(anchorPoint, data.nameplate, relativeToPoint, options.Offset.X, options.Offset.Y)

			container:SetIconSize(options.Icons.Size)
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
	for _, data in pairs(nameplateAnchors) do
		if data.container then
			data.container:ResetAllSlots()
		end
	end
end

function M:RefreshData()
	for unitToken, _ in pairs(nameplateAnchors) do
		OnAuraDataChanged(unitToken)
	end
end
