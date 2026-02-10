---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local units = addon.Utils.Units
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local capabilities = addon.Capabilities
local testModeActive = false
local paused = false
---@type Db
local db
---@type table<string, NameplateData>
local nameplateAnchors = {}
---@type table<string, Watcher>
local watchers = {}

local testCcNameplateSpellIds = {
	408, -- kidney shot
	5782, -- fear
}
local testImportantNameplateSpellIds = {
	104773, -- warlock wall
	377362, -- precog
}

---@class NameplateData
---@field Nameplate table
---@field CcContainer IconSlotContainer?
---@field ImportantContainer IconSlotContainer?
---@field CombinedContainer IconSlotContainer?
---@field UnitToken string

local previousFriendlyEnabled = {
	CC = false,
	Important = false,
	Combined = false,
}
local previousEnemyEnabled = {
	CC = false,
	Important = false,
	Combined = false,
}

---@class NameplatesModule : IModule
local M = {}
addon.Modules.NameplatesModule = M

---@return string point
---@return string relativeToPoint
local function GetCombinedAnchorPoint(unitToken)
	local config = M:GetUnitOptions(unitToken)
	local grow = config.Combined.Grow

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
local function GetCcAnchorPoint(unitToken)
	local config = M:GetUnitOptions(unitToken)
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
	local config = M:GetUnitOptions(unitToken)
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
	local combinedContainer = nil
	local config = M:GetUnitOptions(unitToken)

	if config.Combined.Enabled then
		-- Create a single combined container for both CC and Important spells
		local combinedOptions = config.Combined

		if combinedOptions and combinedOptions.Enabled then
			local size = combinedOptions.Icons.Size or 50
			local maxCount = combinedOptions.Icons.MaxCount or 10
			local offsetX = combinedOptions.Offset.X or 0
			local offsetY = combinedOptions.Offset.Y or 0
			local grow = combinedOptions.Grow or "RIGHT"
			local anchorPoint, relativeToPoint

			if grow == "LEFT" then
				anchorPoint, relativeToPoint = "RIGHT", "LEFT"
			elseif grow == "RIGHT" then
				anchorPoint, relativeToPoint = "LEFT", "RIGHT"
			else
				anchorPoint, relativeToPoint = "CENTER", "CENTER"
			end

			combinedContainer = iconSlotContainer:New(nameplate, maxCount, size, 2)
			local frame = combinedContainer.Frame
			frame:SetIgnoreParentScale(true)
			frame:SetIgnoreParentAlpha(true)
			frame:SetPoint(anchorPoint, nameplate, relativeToPoint, offsetX, offsetY)
			frame:SetFrameStrata("HIGH")
			frame:SetFrameLevel(nameplate:GetFrameLevel() + 10)
			frame:EnableMouse(false)
			frame:Show()
		end
	else
		-- Separate mode: Create CC container
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

		-- Separate mode: Create Important container
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
	end

	return ccContainer, importantContainer, combinedContainer
end

---@param data NameplateData
---@param watcher Watcher
---@param unitToken string
local function ApplyCombinedToNameplate(data, watcher, unitToken)
	local container = data.CombinedContainer
	if not container then
		return
	end

	local unitOptions = M:GetUnitOptions(unitToken)
	local combinedOptions = unitOptions and unitOptions.Combined

	if not combinedOptions or not combinedOptions.Enabled then
		return
	end

	local ccData = watcher:GetCcState()
	local defensivesData = watcher:GetDefensiveState()
	local importantData = watcher:GetImportantState()
	local hasNewFilters = capabilities:HasNewFilters()

	local slot = 0
	local iconsGlow = combinedOptions.Icons.Glow
	local iconsReverse = combinedOptions.Icons.ReverseCooldown

	-- Add CC spells first
	if #ccData > 0 then
		if hasNewFilters then
			for _, spellInfo in ipairs(ccData) do
				slot = slot + 1
				if slot > container.Count then
					break
				end
				container:ClearSlot(slot)
				container:SetSlotUsed(slot)
				container:SetLayer(slot, 1, {
					Texture = spellInfo.SpellIcon,
					StartTime = spellInfo.StartTime,
					Duration = spellInfo.TotalDuration,
					AlphaBoolean = spellInfo.IsCC,
					Glow = iconsGlow,
					ReverseCooldown = iconsReverse,
				})
				container:FinalizeSlot(slot, 1)
			end
		else
			-- Old filters: stack all CC on one slot
			slot = slot + 1
			container:ClearSlot(slot)
			container:SetSlotUsed(slot)
			local layerIndex = 1
			for _, spellInfo in ipairs(ccData) do
				container:SetLayer(slot, layerIndex, {
					Texture = spellInfo.SpellIcon,
					StartTime = spellInfo.StartTime,
					Duration = spellInfo.TotalDuration,
					AlphaBoolean = spellInfo.IsCC,
					Glow = iconsGlow,
					ReverseCooldown = iconsReverse,
				})
				layerIndex = layerIndex + 1
			end
			container:FinalizeSlot(slot, layerIndex - 1)
		end
	end

	-- Add Important spells
	if #importantData > 0 then
		if hasNewFilters then
			for _, spellData in ipairs(importantData) do
				slot = slot + 1
				if slot > container.Count then
					break
				end
				container:ClearSlot(slot)
				container:SetSlotUsed(slot)
				container:SetLayer(slot, 1, {
					Texture = spellData.SpellIcon,
					StartTime = spellData.StartTime,
					Duration = spellData.TotalDuration,
					AlphaBoolean = spellData.IsImportant,
					Glow = iconsGlow,
					ReverseCooldown = iconsReverse,
				})
				container:FinalizeSlot(slot, 1)
			end
		else
			slot = slot + 1
			if slot <= container.Count then
				container:ClearSlot(slot)
				container:SetSlotUsed(slot)

				local used = 0
				for _, spellData in ipairs(importantData) do
					used = used + 1
					container:SetLayer(slot, used, {
						Texture = spellData.SpellIcon,
						StartTime = spellData.StartTime,
						Duration = spellData.TotalDuration,
						AlphaBoolean = spellData.IsImportant,
						Glow = iconsGlow,
						ReverseCooldown = iconsReverse,
					})
				end

				container:FinalizeSlot(slot, used)
			end
		end
	end

	-- Add Defensive spells
	if #defensivesData > 0 then
		for _, spellData in ipairs(defensivesData) do
			slot = slot + 1
			if slot > container.Count then
				break
			end
			container:ClearSlot(slot)
			container:SetSlotUsed(slot)

			container:SetLayer(slot, 1, {
				Texture = spellData.SpellIcon,
				StartTime = spellData.StartTime,
				Duration = spellData.TotalDuration,
				AlphaBoolean = spellData.IsDefensive,
				Glow = iconsGlow,
				ReverseCooldown = iconsReverse,
			})

			container:FinalizeSlot(slot, 1)
		end
	end

	-- Clear any remaining slots
	for i = slot + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

---@param data NameplateData
---@param watcher Watcher
---@param unitToken string
local function ApplyCcToNameplate(data, watcher, unitToken)
	local container = data.CcContainer
	if not container then
		return
	end

	local unitOptions = M:GetUnitOptions(unitToken)
	local options = unitOptions and unitOptions.CC

	if not options or not options.Enabled then
		return
	end

	local ccData = watcher:GetCcState()
	local ccDataCount = #ccData
	local hasNewFilters = capabilities:HasNewFilters()

	-- Clear only slots we'll potentially use
	local slotsNeeded = hasNewFilters and math.min(ccDataCount, container.Count) or 1
	for i = 1, slotsNeeded do
		container:SetSlotUnused(i)
	end

	-- Clear remaining slots if they were used before
	for i = slotsNeeded + 1, container.Count do
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
		container:SetLayer(slotIndex, ccLayerIndex, {
			Texture = spellInfo.SpellIcon,
			StartTime = spellInfo.StartTime,
			Duration = spellInfo.TotalDuration,
			AlphaBoolean = spellInfo.IsCC,
			Glow = iconsGlow,
			ReverseCooldown = iconsReverse,
		})

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

	local unitOptions = M:GetUnitOptions(unitToken)
	local options = unitOptions and unitOptions.Important

	if not options or not options.Enabled then
		return
	end

	local slot = 0
	local defensivesData = watcher:GetDefensiveState()
	local importantData = watcher:GetImportantState()

	if #importantData > 0 then
		if capabilities:HasNewFilters() then
			for _, spellData in ipairs(importantData) do
				slot = slot + 1
				container:ClearSlot(slot)
				container:SetSlotUsed(slot)
				container:SetLayer(slot, 1, {
					Texture = spellData.SpellIcon,
					StartTime = spellData.StartTime,
					Duration = spellData.TotalDuration,
					AlphaBoolean = spellData.IsImportant,
					Glow = options.Icons.Glow,
					ReverseCooldown = options.Icons.ReverseCooldown,
				})
				container:FinalizeSlot(slot, 1)
			end
		else
			slot = slot + 1
			container:ClearSlot(slot)
			container:SetSlotUsed(slot)

			local used = 0
			for _, spellData in ipairs(importantData) do
				used = used + 1
				container:SetLayer(slot, used, {
					Texture = spellData.SpellIcon,
					StartTime = spellData.StartTime,
					Duration = spellData.TotalDuration,
					AlphaBoolean = spellData.IsImportant,
					Glow = options.Icons.Glow,
					ReverseCooldown = options.Icons.ReverseCooldown,
				})
			end

			container:FinalizeSlot(slot, used)
		end
	end

	if #defensivesData > 0 then
		for _, spellData in ipairs(defensivesData) do
			slot = slot + 1
			container:ClearSlot(slot)
			container:SetSlotUsed(slot)

			container:SetLayer(slot, 1, {
				Texture = spellData.SpellIcon,
				StartTime = spellData.StartTime,
				Duration = spellData.TotalDuration,
				AlphaBoolean = spellData.IsDefensive,
				Glow = options.Icons.Glow,
				ReverseCooldown = options.Icons.ReverseCooldown,
			})

			container:FinalizeSlot(slot, 1)
		end
	end

	-- advance forward 1 slot for clearing
	if #importantData > 0 or #defensivesData > 0 then
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

	local unitOptions = M:GetUnitOptions(unitToken)

	if unitOptions.Combined.Enabled then
		ApplyCombinedToNameplate(data, watcher, unitToken)
	else
		ApplyCcToNameplate(data, watcher, unitToken)
		ApplyImportantSpellsToNameplate(data, watcher, unitToken)
	end
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

	if data.CombinedContainer then
		data.CombinedContainer:ResetAllSlots()
		data.CombinedContainer.Frame:Hide()
	end

	-- Dispose of watcher
	if watchers[unitToken] then
		watchers[unitToken]:Dispose()
		watchers[unitToken] = nil
	end

	-- Remove all data for this unit token
	nameplateAnchors[unitToken] = nil
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
	local ccContainer, importantContainer, combinedContainer = CreateContainersForNameplate(nameplate, unitToken)

	if not ccContainer and not importantContainer and not combinedContainer then
		return
	end

	-- Create new nameplate data
	nameplateAnchors[unitToken] = {
		Nameplate = nameplate,
		CcContainer = ccContainer,
		ImportantContainer = importantContainer,
		CombinedContainer = combinedContainer,
		UnitToken = unitToken,
	}

	-- Create new watcher
	watchers[unitToken] = unitWatcher:New(unitToken, nil)
	watchers[unitToken]:RegisterCallback(function()
		OnAuraDataChanged(unitToken)
	end)

	-- Initial update
	OnAuraDataChanged(unitToken)
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

	if data.CombinedContainer then
		data.CombinedContainer:ResetAllSlots()
	end
end

local function RebuildContainers()
	local count = 0
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken

		if unitToken then
			OnNamePlateAdded(unitToken)
			count = count + 1
		end
	end
end

local function AnyEnabled()
	return db.Nameplates.Friendly.CC.Enabled
		or db.Nameplates.Friendly.Important.Enabled
		or db.Nameplates.Friendly.Combined.Enabled
		or db.Nameplates.Enemy.CC.Enabled
		or db.Nameplates.Enemy.Important.Enabled
		or db.Nameplates.Enemy.Combined.Enabled
end

local function CacheEnabledModes()
	previousEnemyEnabled.CC = db.Nameplates.Enemy.CC.Enabled
	previousEnemyEnabled.Important = db.Nameplates.Enemy.Important.Enabled
	previousEnemyEnabled.Combined = db.Nameplates.Enemy.Combined.Enabled

	previousFriendlyEnabled.CC = db.Nameplates.Friendly.CC.Enabled
	previousFriendlyEnabled.Important = db.Nameplates.Friendly.Important.Enabled
	previousFriendlyEnabled.Combined = db.Nameplates.Friendly.Combined.Enabled
end

local function HasModesChanged()
	return previousEnemyEnabled.CC ~= db.Nameplates.Enemy.CC.Enabled
		or previousEnemyEnabled.Important ~= db.Nameplates.Enemy.Important.Enabled
		or previousEnemyEnabled.Combined ~= db.Nameplates.Enemy.Combined.Enabled
		or previousFriendlyEnabled.CC ~= db.Nameplates.Friendly.CC.Enabled
		or previousFriendlyEnabled.Important ~= db.Nameplates.Friendly.Important.Enabled
		or previousFriendlyEnabled.Combined ~= db.Nameplates.Friendly.Combined.Enabled
end

function M:GetUnitOptions(unitToken)
	if units:IsEnemy(unitToken) then
		-- friendly units can also be enemies in a duel
		return db.Nameplates.Enemy
	end

	if units:IsFriend(unitToken) then
		return db.Nameplates.Friendly
	end

	return db.Nameplates.Enemy
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

	if AnyEnabled() then
		-- Initialize existing nameplates
		RebuildContainers()
	end

	CacheEnabledModes()
end

---@return NameplateData
function M:GetAllContainers()
	-- ensure containers exist
	-- might be test mode calling is
	RebuildContainers()

	local containers = {}

	for _, anchor in pairs(nameplateAnchors) do
		containers[#containers + 1] = anchor
	end

	return containers
end

function M:Refresh()
	if not AnyEnabled() then
		M:ClearAll()
		return
	end

	-- if the user has enabled/disabled a mode, rebuild the containers
	if HasModesChanged() then
		RebuildContainers()

		if testModeActive then
			-- update test icons
			M:StartTesting()
		end
	end

	CacheEnabledModes()

	for _, data in pairs(nameplateAnchors) do
		if data.Nameplate and data.UnitToken then
			local unitOptions = M:GetUnitOptions(data.UnitToken)

			if unitOptions.Combined.Enabled then
				-- Handle combined container
				local combinedContainer = data.CombinedContainer
				if combinedContainer then
					local combinedOptions = unitOptions.Combined
					if combinedOptions then
						local combinedAnchorPoint, combinedRelativeToPoint = GetCombinedAnchorPoint(data.UnitToken)
						combinedContainer.Frame:ClearAllPoints()
						combinedContainer.Frame:SetPoint(
							combinedAnchorPoint,
							data.Nameplate,
							combinedRelativeToPoint,
							combinedOptions.Offset.X,
							combinedOptions.Offset.Y
						)
						combinedContainer:SetIconSize(combinedOptions.Icons.Size)
					end
				end
			else
				-- Handle separate containers
				local ccAnchorPoint, ccRelativeToPoint = GetCcAnchorPoint(data.UnitToken)
				local ccOptions = unitOptions and unitOptions.CC
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
				local importantOptions = unitOptions and unitOptions.Important
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
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false

	-- Refresh all nameplates
	for _, watcher in pairs(watchers) do
		watcher:ForceFullUpdate()
	end
end

function M:StartTesting()
	if testModeActive then
		-- this module is smart enough to resume testing without needing to be told
		return
	end

	Pause()

	testModeActive = true

	if not AnyEnabled() then
		return
	end

	local containers = M:GetAllContainers()

	for _, container in ipairs(containers) do
		local now = GetTime()
		local options = M:GetUnitOptions(container.UnitToken)
		local ccOptions = options.CC
		local importantOptions = options.Important
		local ccContainer = container.CcContainer
		local combinedOptions = options.Combined
		local importantContainer = container.ImportantContainer
		local combinedContainer = container.CombinedContainer

		if options.Combined.Enabled then
			if not combinedContainer then
				return
			end
			-- Test combined container with both CC and Important spells
			local slot = 0

			combinedContainer:ResetAllSlots()

			-- Add test CC spells
			for i = 1, #testCcNameplateSpellIds do
				slot = slot + 1
				combinedContainer:SetSlotUsed(slot)

				local spellId = testCcNameplateSpellIds[i]
				local tex = C_Spell.GetSpellTexture(spellId)
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5

				combinedContainer:SetLayer(slot, 1, {
					Texture = tex,
					StartTime = startTime,
					Duration = duration,
					AlphaBoolean = true,
					Glow = combinedOptions.Icons.Glow,
					ReverseCooldown = combinedOptions.Icons.ReverseCooldown,
				})
				combinedContainer:FinalizeSlot(slot, 1)
			end

			-- Add test Important spells
			for i = 1, #testImportantNameplateSpellIds do
				slot = slot + 1
				combinedContainer:SetSlotUsed(slot)

				local spellId = testImportantNameplateSpellIds[i]
				local tex = C_Spell.GetSpellTexture(spellId)
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5
				combinedContainer:SetLayer(slot, 1, {
					Texture = tex,
					StartTime = startTime,
					Duration = duration,
					AlphaBoolean = true,
					Glow = combinedOptions.Icons.Glow,
					ReverseCooldown = combinedOptions.Icons.ReverseCooldown,
				})
				combinedContainer:FinalizeSlot(slot, 1)
			end
		else
			-- Separate mode testing
			if ccContainer and ccOptions then
				ccContainer:ResetAllSlots()

				for i = 1, #testCcNameplateSpellIds do
					ccContainer:SetSlotUsed(i)

					local spellId = testCcNameplateSpellIds[i]
					local tex = C_Spell.GetSpellTexture(spellId)
					local duration = 15 + (i - 1) * 3
					local startTime = now - (i - 1) * 0.5

					ccContainer:SetLayer(i, 1, {
						Texture = tex,
						StartTime = startTime,
						Duration = duration,
						AlphaBoolean = true,
						Glow = ccOptions.Icons.Glow,
						ReverseCooldown = ccOptions.Icons.ReverseCooldown,
					})
					ccContainer:FinalizeSlot(i, 1)
				end
			end

			if importantContainer and importantOptions then
				importantContainer:ResetAllSlots()

				for i = 1, #testImportantNameplateSpellIds do
					importantContainer:SetSlotUsed(i)

					local spellId = testImportantNameplateSpellIds[i]
					local tex = C_Spell.GetSpellTexture(spellId)
					local duration = 15 + (i - 1) * 3
					local startTime = now - (i - 1) * 0.5
					importantContainer:SetLayer(i, 1, {
						Texture = tex,
						StartTime = startTime,
						Duration = duration,
						AlphaBoolean = true,
						Glow = importantOptions.Icons.Glow,
						ReverseCooldown = importantOptions.Icons.ReverseCooldown,
					})
					importantContainer:FinalizeSlot(i, 1)
				end
			end
		end
	end
end

function M:StopTesting()
	Resume()
	testModeActive = false
end

function M:ClearAll()
	-- Clean up all existing nameplates
	for unitToken, _ in pairs(nameplateAnchors) do
		ClearNameplate(unitToken)
	end
end
