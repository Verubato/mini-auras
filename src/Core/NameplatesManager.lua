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
---@field CcContainer IconSlotContainer
---@field ImportantContainer IconSlotContainer
---@field UnitToken string

---@class NameplatesManager
local M = {}
addon.NameplatesManager = M

local function GetCcOptions(unitToken)
	if units:IsFriend(unitToken) then
		return db.Nameplates.Friendly.CC
	end

	if units:IsEnemy(unitToken) or not units:IsFriend(unitToken) then
		return db.Nameplates.Enemy.CC
	end

	return nil
end

local function GetImportantOptions(unitToken)
	if units:IsFriend(unitToken) then
		return db.Nameplates.Friendly.Important
	end

	if units:IsEnemy(unitToken) or not units:IsFriend(unitToken) then
		return db.Nameplates.Enemy.Important
	end

	return nil
end

---@return string? anchorPoint
---@return string? relativeToPoint
local function GetCcAnchorPoint(unitToken)
	local anchorPoint = "CENTER"
	local relativeToPoint = "CENTER"

	if units:IsFriend(unitToken) then
		if db.Nameplates.Friendly.CC.Grow == "LEFT" then
			anchorPoint = "RIGHT"
			relativeToPoint = "LEFT"
		elseif db.Nameplates.Friendly.CC.Grow == "RIGHT" then
			anchorPoint = "LEFT"
			relativeToPoint = "RIGHT"
		end

		return anchorPoint, relativeToPoint
	end

	if units:IsEnemy(unitToken) or not units:IsFriend(unitToken) then
		if db.Nameplates.Enemy.CC.Grow == "LEFT" then
			anchorPoint = "RIGHT"
			relativeToPoint = "LEFT"
		elseif db.Nameplates.Enemy.CC.Grow == "RIGHT" then
			anchorPoint = "LEFT"
			relativeToPoint = "RIGHT"
		end

		return anchorPoint, relativeToPoint
	end

	return nil, nil
end

---@return string? anchorPoint
---@return string? relativeToPoint
local function GetImportantAnchorPoint(unitToken)
	local anchorPoint = "CENTER"
	local relativeToPoint = "CENTER"

	if units:IsFriend(unitToken) then
		if db.Nameplates.Friendly.Important.Grow == "LEFT" then
			anchorPoint = "RIGHT"
			relativeToPoint = "LEFT"
		elseif db.Nameplates.Friendly.Important.Grow == "RIGHT" then
			anchorPoint = "LEFT"
			relativeToPoint = "RIGHT"
		end

		return anchorPoint, relativeToPoint
	end

	if units:IsEnemy(unitToken) or not units:IsFriend(unitToken) then
		if db.Nameplates.Enemy.Important.Grow == "LEFT" then
			anchorPoint = "RIGHT"
			relativeToPoint = "LEFT"
		elseif db.Nameplates.Enemy.Important.Grow == "RIGHT" then
			anchorPoint = "LEFT"
			relativeToPoint = "RIGHT"
		end

		return anchorPoint, relativeToPoint
	end

	return nil, nil
end

local function GetNameplateForUnit(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	return nameplate
end

local function CreateContainersForNameplate(nameplate, unitToken)
	local ccContainer, importantContainer

	do
		local options = GetCcOptions(unitToken)
		local anchorPoint, relativeToPoint = GetCcAnchorPoint(unitToken)
		if options and anchorPoint and relativeToPoint and options.Enabled then
			local size = options.Icons.Size or 20
			local maxCount = options.Icons.MaxCount or 5
			local offsetX = options.Offset.X or 0
			local offsetY = options.Offset.Y or 5

			ccContainer = iconSlotContainer:New(nameplate, maxCount, size, 2)
			ccContainer.Frame:SetIgnoreParentScale(true)
			ccContainer.Frame:SetIgnoreParentAlpha(true)
			ccContainer.Frame:SetPoint(anchorPoint, nameplate, relativeToPoint, offsetX, offsetY)
			ccContainer.Frame:SetFrameStrata("HIGH")
			ccContainer.Frame:SetFrameLevel(nameplate:GetFrameLevel() + 10)
			ccContainer.Frame:EnableMouse(false)
			ccContainer.Frame:Show()
		end
	end

	do
		local options = GetImportantOptions(unitToken)
		local anchorPoint, relativeToPoint = GetImportantAnchorPoint(unitToken)
		if options and anchorPoint and relativeToPoint and options.Enabled then
			local size = options.Icons.Size or 20
			local maxCount = options.Icons.MaxCount or 5
			local offsetX = options.Offset.X or 0
			local offsetY = options.Offset.Y or 5

			importantContainer = iconSlotContainer:New(nameplate, maxCount, size, 2)
			importantContainer.Frame:SetIgnoreParentScale(true)
			importantContainer.Frame:SetIgnoreParentAlpha(true)
			importantContainer.Frame:SetPoint(anchorPoint, nameplate, relativeToPoint, offsetX, offsetY)
			importantContainer.Frame:SetFrameStrata("HIGH")
			importantContainer.Frame:SetFrameLevel(nameplate:GetFrameLevel() + 10)
			importantContainer.Frame:EnableMouse(false)
			importantContainer.Frame:Show()
		end
	end

	return ccContainer, importantContainer
end

---@param data NameplateData
---@param watcher Watcher
---@param unitToken string
local function ApplyCcToNameplate(data, watcher, unitToken)
	local container = data.CcContainer
	local options = GetCcOptions(unitToken)

	for i = 1, container.Count do
		container:ClearSlot(i)
		container:SetSlotUnused(i)
	end

	if not container or not options then
		return
	end

	local slotIndex = 1
	local ccLayerIndex = 1
	local ccData = watcher:GetCcState()

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
			options.Icons.Glow,
			options.Icons.ReverseCooldown
		)

		if capabilities:HasNewFilters() then
			-- we're on 12.0.1 and can show multiple cc's
			slotIndex = slotIndex + 1
			container:FinalizeSlot(slotIndex, 1)
		else
			-- can only show 1 cc
			ccLayerIndex = ccLayerIndex + 1
		end
	end
end

---@param data NameplateData
---@param watcher Watcher
---@param unitToken string
local function ApplyImportantSpellsToNameplate(data, watcher, unitToken)
	-- note important spells already cover defensives, so don't double up
	local container = data.ImportantContainer
	local options = GetImportantOptions(unitToken)

	for i = 1, container.Count do
		container:ClearSlot(i)
		container:SetSlotUnused(i)
	end

	if not container or not options then
		return
	end

	local spellData = watcher:GetImportantState()

	if #spellData > 0 then
		container:SetSlotUsed(1)
	end

	for layerIndex, spellInfo in ipairs(spellData) do
		container:SetLayer(
			1,
			layerIndex,
			spellInfo.SpellIcon,
			spellInfo.StartTime,
			spellInfo.TotalDuration,
			spellInfo.IsImportant,
			options.Icons.Glow,
			options.Icons.ReverseCooldown
		)
	end

	container:FinalizeSlot(1, #spellData)
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
	if nameplateAnchors[unitToken] then
		return
	end

	local nameplate = GetNameplateForUnit(unitToken)
	if not nameplate then
		return
	end

	local ccContainer, importantContainer = CreateContainersForNameplate(nameplate, unitToken)

	if not container and not importantContainer then
		return
	end

	nameplateAnchors[unitToken] = {
		Nameplate = nameplate,
		CcContainer = ccContainer,
		ImportantContainer = importantContainer,
		UnitToken = unitToken,
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

	if data.CcContainer then
		data.CcContainer:ResetAllSlots()
		data.CcContainer.Frame:Hide()
		data.CcContainer.Frame:SetParent(nil)
	end

	if data.ImportantContainer then
		data.ImportantContainer:ResetAllSlots()
		data.ImportantContainer.Frame:Hide()
		data.ImportantContainer.Frame:SetParent(nil)
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
	if newNameplate and newNameplate ~= data.Nameplate then
		-- Nameplate changed, recreate container
		OnNamePlateRemoved(unitToken)
		OnNamePlateAdded(unitToken)
	end
end

local function RefreshNameplates()
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.namePlateUnitToken
		if unitToken then
			OnNamePlateAdded(unitToken)
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

	if db.Nameplates.Enabled then
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
	for _, data in pairs(nameplateAnchors) do
		if data.CcContainer then
			data.CcContainer:ResetAllSlots()
		end
		if data.ImportantContainer then
			data.ImportantContainer:ResetAllSlots()
		end
	end
end
