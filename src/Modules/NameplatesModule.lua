---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local units = addon.Utils.Units
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
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
local testDefensiveNameplateSpellIds = {
	104773, -- warlock wall
	48707, -- anti-magic shell
}
local testImportantNameplateSpellIds = {
	190319, -- combustion
	121471, -- Shadow Blades
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
local previousPetEnabled = {
	Friendly = false,
	Enemy = false,
}
local previousModuleEnabled = {}
---@class NameplatesModule : IModule
local M = {}
addon.Modules.NameplatesModule = M

---@return string point
---@return string relativeToPoint
local function GetAnchorPoint(unitToken, containerType)
	local config = M:GetUnitOptions(unitToken)
	local grow = config[containerType].Grow

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

---@return string point
---@return string relativeToPoint
local function GetCombinedAnchorPoint(unitToken)
	return GetAnchorPoint(unitToken, "Combined")
end

---@return string anchorPoint
---@return string relativeToPoint
local function GetCcAnchorPoint(unitToken)
	return GetAnchorPoint(unitToken, "CC")
end

---@return string anchorPoint
---@return string relativeToPoint
local function GetImportantAnchorPoint(unitToken)
	return GetAnchorPoint(unitToken, "Important")
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
			local maxIcons = combinedOptions.Icons.MaxIcons or 8
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

			combinedContainer = iconSlotContainer:New(nameplate, maxIcons, size, 2)
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
			local maxIcons = ccOptions.Icons.MaxIcons or 5
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

			ccContainer = iconSlotContainer:New(nameplate, maxIcons, size, 2)
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
			local maxIcons = importantOptions.Icons.MaxIcons or 5
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

			importantContainer = iconSlotContainer:New(nameplate, maxIcons, size, 2)
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

---Calculate slot distribution across CC, Defensive, and Important categories
---@param containerCount number Total number of available slots
---@param ccCount number Number of CC spells
---@param defensiveCount number Number of Defensive spells
---@param importantCount number Number of Important spells
---@return number ccSlots Number of slots allocated to CC
---@return number defensiveSlots Number of slots allocated to Defensive
---@return number importantSlots Number of slots allocated to Important
local function CalculateSlotDistribution(containerCount, ccCount, defensiveCount, importantCount)
	local ccSlots, defensiveSlots, importantSlots = 0, 0, 0

	-- Calculate how many active categories we have
	local activeCategories = 0
	if ccCount > 0 then
		activeCategories = activeCategories + 1
	end
	if defensiveCount > 0 then
		activeCategories = activeCategories + 1
	end
	if importantCount > 0 then
		activeCategories = activeCategories + 1
	end

	if activeCategories > 0 and containerCount >= activeCategories then
		-- Guarantee each active category gets at least 1 slot
		if ccCount > 0 then
			ccSlots = 1
		end
		if defensiveCount > 0 then
			defensiveSlots = 1
		end
		if importantCount > 0 then
			importantSlots = 1
		end

		-- Distribute remaining slots by priority: CC -> Defensive -> Important
		local remainingSlots = containerCount - activeCategories

		while remainingSlots > 0 do
			local allocatedThisRound = false

			if ccCount > ccSlots and remainingSlots > 0 then
				ccSlots = ccSlots + 1
				remainingSlots = remainingSlots - 1
				allocatedThisRound = true
			end
			if defensiveCount > defensiveSlots and remainingSlots > 0 then
				defensiveSlots = defensiveSlots + 1
				remainingSlots = remainingSlots - 1
				allocatedThisRound = true
			end
			if importantCount > importantSlots and remainingSlots > 0 then
				importantSlots = importantSlots + 1
				remainingSlots = remainingSlots - 1
				allocatedThisRound = true
			end

			-- If we couldn't allocate any more slots this round, break
			if not allocatedThisRound then
				break
			end
		end
	elseif activeCategories > 0 then
		-- Not enough slots for all categories, distribute fairly by priority
		-- Round-robin distribution: CC -> Defensive -> Important
		local remainingSlots = containerCount

		while remainingSlots > 0 do
			local allocatedThisRound = false

			-- CC gets first slot in each round
			if ccCount > ccSlots and remainingSlots > 0 then
				ccSlots = ccSlots + 1
				remainingSlots = remainingSlots - 1
				allocatedThisRound = true
			end

			-- Defensive gets second slot in each round
			if defensiveCount > defensiveSlots and remainingSlots > 0 then
				defensiveSlots = defensiveSlots + 1
				remainingSlots = remainingSlots - 1
				allocatedThisRound = true
			end

			-- Important gets third slot in each round
			if importantCount > importantSlots and remainingSlots > 0 then
				importantSlots = importantSlots + 1
				remainingSlots = remainingSlots - 1
				allocatedThisRound = true
			end

			-- If we couldn't allocate any slots this round, break
			if not allocatedThisRound then
				break
			end
		end
	end

	return ccSlots, defensiveSlots, importantSlots
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

	container:ResetAllSlots()

	if not combinedOptions or not combinedOptions.Enabled then
		return
	end

	local ccData = watcher:GetCcState()
	local defensivesData = watcher:GetDefensiveState()
	local importantData = watcher:GetImportantState()
	local iconsGlow = combinedOptions.Icons.Glow
	local iconsReverse = combinedOptions.Icons.ReverseCooldown

	-- Calculate slot distribution
	local ccSlots, defensiveSlots, importantSlots =
		CalculateSlotDistribution(container.Count, #ccData, #defensivesData, #importantData)

	local slot = 0

	-- Add CC spells (highest priority)
	if ccSlots > 0 then
		-- Each CC gets its own slot
		for i = 1, math.min(ccSlots, #ccData) do
			if slot >= container.Count then
				break
			end
			slot = slot + 1
			container:SetSlotUsed(slot)
			container:SetLayer(slot, 1, {
				Texture = ccData[i].SpellIcon,
				StartTime = ccData[i].StartTime,
				Duration = ccData[i].TotalDuration,
				AlphaBoolean = ccData[i].IsCC,
				Glow = iconsGlow,
				ReverseCooldown = iconsReverse,
				FontScale = db.FontScale,
			})
			container:FinalizeSlot(slot, 1)
		end
	end

	-- Add Defensive spells (second priority)
	if defensiveSlots > 0 then
		for i = 1, math.min(defensiveSlots, #defensivesData) do
			if slot >= container.Count then
				break
			end
			slot = slot + 1
			container:SetSlotUsed(slot)

			container:SetLayer(slot, 1, {
				Texture = defensivesData[i].SpellIcon,
				StartTime = defensivesData[i].StartTime,
				Duration = defensivesData[i].TotalDuration,
				AlphaBoolean = defensivesData[i].IsDefensive,
				Glow = iconsGlow,
				ReverseCooldown = iconsReverse,
				FontScale = db.FontScale,
			})

			container:FinalizeSlot(slot, 1)
		end
	end

	-- Add Important spells (third priority)
	if importantSlots > 0 then
		-- Each Important spell gets its own slot
		for i = 1, math.min(importantSlots, #importantData) do
			if slot >= container.Count then
				break
			end
			slot = slot + 1
			container:SetSlotUsed(slot)
			container:SetLayer(slot, 1, {
				Texture = importantData[i].SpellIcon,
				StartTime = importantData[i].StartTime,
				Duration = importantData[i].TotalDuration,
				AlphaBoolean = importantData[i].IsImportant,
				Glow = iconsGlow,
				ReverseCooldown = iconsReverse,
				FontScale = db.FontScale,
			})
			container:FinalizeSlot(slot, 1)
		end
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

	container:ResetAllSlots()

	if not options or not options.Enabled then
		return
	end

	local ccData = watcher:GetCcState()
	local ccDataCount = #ccData

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
			FontScale = db.FontScale,
		})

		container:FinalizeSlot(slotIndex, 1)
		slotIndex = slotIndex + 1
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

	container:ResetAllSlots()

	local unitOptions = M:GetUnitOptions(unitToken)
	local options = unitOptions and unitOptions.Important

	if not options or not options.Enabled then
		return
	end

	local iconsGlow = options.Icons.Glow
	local iconsReverse = options.Icons.ReverseCooldown
	local slot = 0
	local defensivesData = watcher:GetDefensiveState()
	local importantData = watcher:GetImportantState()

	if #importantData > 0 then
		for _, spellData in ipairs(importantData) do
			slot = slot + 1
			container:SetSlotUsed(slot)
			container:SetLayer(slot, 1, {
				Texture = spellData.SpellIcon,
				StartTime = spellData.StartTime,
				Duration = spellData.TotalDuration,
				AlphaBoolean = spellData.IsImportant,
				Glow = iconsGlow,
				ReverseCooldown = iconsReverse,
				FontScale = db.FontScale,
			})
			container:FinalizeSlot(slot, 1)
		end
	end

	if #defensivesData > 0 then
		for _, spellData in ipairs(defensivesData) do
			slot = slot + 1
			container:SetSlotUsed(slot)

			container:SetLayer(slot, 1, {
				Texture = spellData.SpellIcon,
				StartTime = spellData.StartTime,
				Duration = spellData.TotalDuration,
				AlphaBoolean = spellData.IsDefensive,
				Glow = iconsGlow,
				ReverseCooldown = iconsReverse,
				FontScale = db.FontScale,
			})

			container:FinalizeSlot(slot, 1)
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

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	if not moduleEnabled then
		return
	end

	-- Check if we should ignore pets
	local unitOptions = M:GetUnitOptions(unitToken)
	if unitOptions.IgnorePets and units:IsPet(unitToken) then
		return
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
	watchers[unitToken] = unitWatcher:New(unitToken)
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
	return db.Modules.NameplatesModule.Friendly.CC.Enabled
		or db.Modules.NameplatesModule.Friendly.Important.Enabled
		or db.Modules.NameplatesModule.Friendly.Combined.Enabled
		or db.Modules.NameplatesModule.Enemy.CC.Enabled
		or db.Modules.NameplatesModule.Enemy.Important.Enabled
		or db.Modules.NameplatesModule.Enemy.Combined.Enabled
end

local function CacheEnabledModes()
	previousEnemyEnabled.CC = db.Modules.NameplatesModule.Enemy.CC.Enabled
	previousEnemyEnabled.Important = db.Modules.NameplatesModule.Enemy.Important.Enabled
	previousEnemyEnabled.Combined = db.Modules.NameplatesModule.Enemy.Combined.Enabled

	previousFriendlyEnabled.CC = db.Modules.NameplatesModule.Friendly.CC.Enabled
	previousFriendlyEnabled.Important = db.Modules.NameplatesModule.Friendly.Important.Enabled
	previousFriendlyEnabled.Combined = db.Modules.NameplatesModule.Friendly.Combined.Enabled

	previousPetEnabled.Friendly = db.Modules.NameplatesModule.Friendly.IgnorePets
	previousPetEnabled.Enemy = db.Modules.NameplatesModule.Enemy.IgnorePets

	previousModuleEnabled = mini:CopyTable(db.Modules.NameplatesModule.Enabled)
end

local function HaveModesChanged()
	local options = db.Modules.NameplatesModule

	return previousEnemyEnabled.CC ~= options.Enemy.CC.Enabled
		or previousEnemyEnabled.Important ~= options.Enemy.Important.Enabled
		or previousEnemyEnabled.Combined ~= options.Enemy.Combined.Enabled
		or previousFriendlyEnabled.CC ~= options.Friendly.CC.Enabled
		or previousFriendlyEnabled.Important ~= options.Friendly.Important.Enabled
		or previousFriendlyEnabled.Combined ~= options.Friendly.Combined.Enabled
		or previousPetEnabled.Friendly ~= options.Friendly.IgnorePets
		or previousPetEnabled.Enemy ~= options.Enemy.IgnorePets
		or previousModuleEnabled.Always ~= options.Enabled.Always
		or previousModuleEnabled.Arena ~= options.Enabled.Arena
		or previousModuleEnabled.Dungeons ~= options.Enabled.Dungeons
		or previousModuleEnabled.Raid ~= options.Enabled.Raid
end

local function ShowCombinedTestIcons(combinedContainer, combinedOptions, now)
	if not combinedContainer or not combinedOptions then
		return
	end

	combinedContainer:ResetAllSlots()

	-- Calculate slot distribution
	local ccSlots, defensiveSlots, importantSlots = CalculateSlotDistribution(
		combinedContainer.Count,
		#testCcNameplateSpellIds,
		#testDefensiveNameplateSpellIds,
		#testImportantNameplateSpellIds
	)

	local slot = 0

	-- Add CC spells first (highest priority)
	for i = 1, ccSlots do
		if slot >= combinedContainer.Count then
			break
		end
		slot = slot + 1
		combinedContainer:SetSlotUsed(slot)

		local spellId = testCcNameplateSpellIds[i]
		local tex = spellCache:GetSpellTexture(spellId)
		if tex then
			local duration = 15 + (i - 1) * 3
			local startTime = now - (i - 1) * 0.5
			combinedContainer:SetLayer(slot, 1, {
				Texture = tex,
				StartTime = startTime,
				Duration = duration,
				AlphaBoolean = true,
				Glow = combinedOptions.Icons.Glow,
				ReverseCooldown = combinedOptions.Icons.ReverseCooldown,
				FontScale = db.FontScale,
			})
			combinedContainer:FinalizeSlot(slot, 1)
		end
	end

	-- Add Defensive spells (second priority)
	for i = 1, defensiveSlots do
		if slot >= combinedContainer.Count then
			break
		end
		slot = slot + 1
		combinedContainer:SetSlotUsed(slot)

		local spellId = testDefensiveNameplateSpellIds[i]
		local tex = spellCache:GetSpellTexture(spellId)
		if tex then
			local duration = 15 + (i - 1) * 3
			local startTime = now - (i - 1) * 0.5
			combinedContainer:SetLayer(slot, 1, {
				Texture = tex,
				StartTime = startTime,
				Duration = duration,
				AlphaBoolean = true,
				Glow = combinedOptions.Icons.Glow,
				ReverseCooldown = combinedOptions.Icons.ReverseCooldown,
				FontScale = db.FontScale,
			})
			combinedContainer:FinalizeSlot(slot, 1)
		end
	end

	-- Add Important spells (third priority)
	for i = 1, importantSlots do
		if slot >= combinedContainer.Count then
			break
		end
		slot = slot + 1
		combinedContainer:SetSlotUsed(slot)

		local spellId = testImportantNameplateSpellIds[i]
		local tex = spellCache:GetSpellTexture(spellId)
		if tex then
			local duration = 15 + (i - 1) * 3
			local startTime = now - (i - 1) * 0.5
			combinedContainer:SetLayer(slot, 1, {
				Texture = tex,
				StartTime = startTime,
				Duration = duration,
				AlphaBoolean = true,
				Glow = combinedOptions.Icons.Glow,
				ReverseCooldown = combinedOptions.Icons.ReverseCooldown,
				FontScale = db.FontScale,
			})
			combinedContainer:FinalizeSlot(slot, 1)
		end
	end
end

local function ShowSeparateModeTestIcons(ccContainer, ccOptions, importantContainer, importantOptions, now)
	if ccContainer and ccOptions then
		ccContainer:ResetAllSlots()

		for i = 1, #testCcNameplateSpellIds do
			ccContainer:SetSlotUsed(i)

			local spellId = testCcNameplateSpellIds[i]
			local tex = spellCache:GetSpellTexture(spellId)

			if tex then
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5

				ccContainer:SetLayer(i, 1, {
					Texture = tex,
					StartTime = startTime,
					Duration = duration,
					AlphaBoolean = true,
					Glow = ccOptions.Icons.Glow,
					ReverseCooldown = ccOptions.Icons.ReverseCooldown,
					FontScale = db.FontScale,
				})
				ccContainer:FinalizeSlot(i, 1)
			end
		end
	end

	if importantContainer and importantOptions then
		importantContainer:ResetAllSlots()

		for i = 1, #testImportantNameplateSpellIds do
			importantContainer:SetSlotUsed(i)

			local spellId = testImportantNameplateSpellIds[i]
			local tex = spellCache:GetSpellTexture(spellId)

			if tex then
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5
				importantContainer:SetLayer(i, 1, {
					Texture = tex,
					StartTime = startTime,
					Duration = duration,
					AlphaBoolean = true,
					Glow = importantOptions.Icons.Glow,
					ReverseCooldown = importantOptions.Icons.ReverseCooldown,
					FontScale = db.FontScale,
				})
				importantContainer:FinalizeSlot(i, 1)
			end
		end
	end
end

local function ShowTestIcons()
	for _, container in pairs(nameplateAnchors) do
		local now = GetTime()
		local options = M:GetUnitOptions(container.UnitToken)
		local ccOptions = options.CC
		local importantOptions = options.Important
		local ccContainer = container.CcContainer
		local combinedOptions = options.Combined
		local importantContainer = container.ImportantContainer
		local combinedContainer = container.CombinedContainer

		if options.Combined.Enabled then
			if combinedContainer and combinedOptions then
				ShowCombinedTestIcons(combinedContainer, combinedOptions, now)
			end
		else
			ShowSeparateModeTestIcons(ccContainer, ccOptions, importantContainer, importantOptions, now)
		end
	end
end

local function RefreshAnchorsAndSizes()
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
						combinedContainer:SetCount(combinedOptions.Icons.MaxIcons)
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
end

function M:GetUnitOptions(unitToken)
	if units:IsEnemy(unitToken) then
		-- friendly units can also be enemies in a duel
		return db.Modules.NameplatesModule.Enemy
	end

	if units:IsFriend(unitToken) then
		return db.Modules.NameplatesModule.Friendly
	end

	return db.Modules.NameplatesModule.Enemy
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

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	if moduleEnabled and AnyEnabled() then
		-- Initialize existing nameplates
		RebuildContainers()
	end

	CacheEnabledModes()
end

function M:Refresh()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)

	if not moduleEnabled or not AnyEnabled() then
		M:ClearAll()
		CacheEnabledModes()
		return
	end

	-- if the user has enabled/disabled a mode, rebuild the containers
	if HaveModesChanged() then
		RebuildContainers()
	end

	CacheEnabledModes()
	RefreshAnchorsAndSizes()

	if testModeActive then
		-- update test icons
		ShowTestIcons()
	end
end

function M:StartTesting()
	Pause()
	testModeActive = true

	-- Check if any nameplate mode is enabled
	if not AnyEnabled() then
		M:ClearAll()
		return
	end

	ShowTestIcons()
end

function M:StopTesting()
	testModeActive = false
	-- clear icons
	M:ClearAll()

	Resume()

	-- Refresh all nameplates
	for _, watcher in pairs(watchers) do
		watcher:ForceFullUpdate()
	end
end

function M:ClearAll()
	-- Clean up all existing nameplates
	for unitToken, _ in pairs(nameplateAnchors) do
		ClearNameplate(unitToken)
	end
end
