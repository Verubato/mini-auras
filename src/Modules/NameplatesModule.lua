---@type string, Addon
local addonName, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local units = addon.Utils.Units
local unitWatcher = addon.Core.UnitAuraWatcher
local kickTracker = addon.Core.KickTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local slotDistribution = addon.Utils.SlotDistribution
local mathMin = math.min
local GetTime = GetTime
local C_NamePlate = C_NamePlate
local testModeActive = false
local paused = false
---@type Db
local db
---@type table
local nmModule
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
	1022, -- bop
}
local testImportantNameplateSpellIds = {
	31884, -- avenging wrath
	121471, -- shadow blades
}
-- Pre-computed lengths; these lists never change at runtime so recalculating
-- #list on every test-mode call is pure waste.
local testCcCount = #testCcNameplateSpellIds
local testDefensiveCount = #testDefensiveNameplateSpellIds
local testImportantCount = #testImportantNameplateSpellIds

-- Test spell dispel colors for CC spells
local testCcDispelColors = {
	[408] = DEBUFF_TYPE_NONE_COLOR, -- kidney shot
	[5782] = DEBUFF_TYPE_MAGIC_COLOR, -- fear
}

-- Category colors
local defensiveColor = { r = 0.0, g = 0.8, b = 0.0 } -- Green
local importantColor = { r = 0.85, g = 0.7, b = 0.1 } -- Gold

---@class NameplateData
---@field Nameplate table
---@field Bar1Container IconSlotContainer?
---@field Bar2Container IconSlotContainer?
---@field UnitToken string

local previousFriendlyEnabled = {
	Bar1 = false,
	Bar2 = false,
}
local previousEnemyEnabled = {
	Bar1 = false,
	Bar2 = false,
}
local previousPetEnabled = {
	Friendly = false,
	Enemy = false,
}
local previousModuleEnabled = { Always = false, Arena = false, BattleGrounds = false, PvE = false }
local previousImportantNeeded = false

-- Reusable scratch table for SetSlot calls.
-- This avoids creating a new table on every aura update for every nameplate slot,
-- which significantly reduces garbage collection pressure.
local layerScratch = {}

-- Shared empty list returned when a bar isn't showing a given spell type. Never mutate this.
local EMPTY = {}

local importantDisplayScratch = {}
local importantEntryPool = {}
local hookedAuraFrames = {}
-- AuraInstanceIDs already shown as defensives this update, excluded from the important set so a
-- both-important-and-defensive aura isn't drawn twice. Rebuilt per unit in OnAuraDataChanged.
local importantSkipScratch = {}

---@class NameplatesModule
local M = {}
addon.Modules.NameplatesModule = M

local nameplateBar1Key = addonName .. "_Bar1Container"
local nameplateBar2Key = addonName .. "_Bar2Container"

-- The two generic nameplate bars. Each bar independently shows CC, defensives, and/or important
-- buffs based on its ShowCC / ShowDefensives / ShowImportant options, and both bars can display
-- at the same time.
local BARS = {
	{ Key = "Bar1", ContainerKey = nameplateBar1Key, DataField = "Bar1Container" },
	{ Key = "Bar2", ContainerKey = nameplateBar2Key, DataField = "Bar2Container" },
}

local function ImportantNeeded()
	local enemy = nmModule.Enemy
	local friendly = nmModule.Friendly
	return (enemy.Bar1.Enabled and enemy.Bar1.ShowImportant)
		or (enemy.Bar2.Enabled and enemy.Bar2.ShowImportant)
		or (friendly.Bar1.Enabled and friendly.Bar1.ShowImportant)
		or (friendly.Bar2.Enabled and friendly.Bar2.ShowImportant)
		or false
end

local function GetCCSortOptions()
	if db.CCNativeOrder then
		return Enum.UnitAuraSortRule.Default, Enum.UnitAuraSortDirection.Normal
	end
	return Enum.UnitAuraSortRule.Unsorted, Enum.UnitAuraSortDirection.Reverse
end

local function GrowToAnchor(grow)
	if grow == "LEFT" then
		return "RIGHT", "LEFT"
	elseif grow == "RIGHT" then
		return "LEFT", "RIGHT"
	elseif grow == "DOWN" then
		return "TOP", "BOTTOM"
	else
		return "CENTER", "CENTER"
	end
end

---@return string point
---@return string relativeToPoint
local function GetAnchorPoint(unitToken, containerType)
	local config = M:GetUnitOptions(unitToken)
	return GrowToAnchor(config[containerType].Grow)
end

---@param container IconSlotContainer?
local function HideAndReset(container)
	if not container then
		return
	end
	container:ResetAllSlots()
	container.Frame:Hide()
end

---@param container IconSlotContainer
---@param nameplate table
---@param anchorPoint string
---@param relativeToPoint string
---@param offsetX number
---@param offsetY number
---Returns the effective anchor frame for a nameplate.
---For ThreatPlates, anchors to TPFrame (or its GetAnchor result) so that
---icons scale and move with TP's target-highlight scaling, not the raw base frame.
local function GetNameplateAnchorFrame(nameplate)
	if nameplate.TPFrame then
		if nameplate.TPFrame.GetAnchor then
			local anchor = nameplate.TPFrame:GetAnchor()
			-- GetAnchor may return a FontString or other non-Frame object that lacks GetFrameLevel
			if anchor and anchor.GetFrameLevel then
				return anchor
			end
		end
		return nameplate.TPFrame
	end
	return nameplate
end

local function SetupContainerFrame(container, nameplate, anchorPoint, relativeToPoint, offsetX, offsetY)
	local anchorFrame = GetNameplateAnchorFrame(nameplate)
	local frame = container.Frame
	frame:ClearAllPoints()
	frame:SetPoint(anchorPoint, anchorFrame, relativeToPoint, offsetX, offsetY)
	frame:SetFrameLevel(anchorFrame:GetFrameLevel() + 10)
	frame:EnableMouse(false)
	frame:SetIgnoreParentScale(not nmModule.ScaleWithNameplate)
	frame:Show()
end

---@param nameplate table
---@param unitToken string
---@param unitOptions table
---@return IconSlotContainer? bar1Container, IconSlotContainer? bar2Container
local function EnsureContainersForNameplate(nameplate, unitToken, unitOptions)
	-- Each bar shows when its own Enabled flag is set, so both bars can display at once.
	local result = {}
	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		if barOptions and barOptions.Enabled then
			local size = barOptions.Icons.Size or 35
			local maxIcons = barOptions.Icons.MaxIcons or 5
			local offsetX = barOptions.Offset.X or 0
			local offsetY = barOptions.Offset.Y or 0
			local anchorPoint, relativeToPoint = GetAnchorPoint(unitToken, bar.Key)

			local container = nameplate[bar.ContainerKey]
			if not container then
				container = iconSlotContainer:New(nameplate, maxIcons, size, db.IconSpacing or 2, "Nameplates", nil, "Nameplates")
				nameplate[bar.ContainerKey] = container
			else
				container:SetIconSize(size)
				container:SetCount(maxIcons)
			end

			SetupContainerFrame(container, nameplate, anchorPoint, relativeToPoint, offsetX, offsetY)
			result[bar.Key] = container
		else
			HideAndReset(nameplate[bar.ContainerKey])
		end
	end

	return result.Bar1, result.Bar2
end

local function GetNameplateBuffList(nameplate)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.buffList and af.buffList.Iterate and not (af.IsForbidden and af:IsForbidden()) then
		return af.buffList
	end
	return nil
end

-- Unit for the in-progress GetImportantBuffs iteration. Passed to the hoisted callback via this
-- upvalue rather than a per-call closure, since the buff scan runs on the aura hot path.
local importantIterUnit

local function CollectImportantBuff(auraInstanceID)
	if importantSkipScratch[auraInstanceID] then
		return
	end
	local unit = importantIterUnit
	local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
	if aura then
		local filtered = importantDisplayScratch
		local n = #filtered + 1
		local entry = importantEntryPool[n]
		if not entry then
			entry = {}
			importantEntryPool[n] = entry
		end
		entry.SpellIcon = aura.icon
		entry.SpellId = aura.spellId
		entry.AuraInstanceID = auraInstanceID
		entry.DurationObject = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
		filtered[n] = entry
	end
end

---Collects the "important" buffs Blizzard chooses to display on a nameplate (e.g. enemy
---offensive cooldowns). These come straight from Blizzard's own nameplate buff list rather
---than the aura watcher, so we never have to evaluate importance ourselves.
local function GetImportantBuffs(data)
	local filtered = importantDisplayScratch
	wipe(filtered)
	local buffList = GetNameplateBuffList(data.Nameplate)
	if buffList then
		importantIterUnit = data.UnitToken
		buffList:Iterate(CollectImportantBuff)
	end
	return filtered
end

---Renders one bar from the spell types it has enabled: CC (with the kick icon) for ShowCC,
---defensives for ShowDefensives, and Blizzard's important buffs for ShowImportant. Priority is
---CC, then defensives, then important; slotDistribution divides the bar's slots between them.
---@param container IconSlotContainer?
---@param barOptions table?
---@param watcher Watcher
---@param data NameplateData
local function ApplyBarToNameplate(container, barOptions, watcher, data)
	if not container or not barOptions or not barOptions.Enabled then
		return
	end

	local showCC = barOptions.ShowCC
	local showDefensives = barOptions.ShowDefensives
	local showImportant = barOptions.ShowImportant

	local kickEntry = showCC and kickTracker:GetKick(data.UnitToken) or nil
	local ccData = showCC and watcher:GetCcState() or EMPTY
	local defensivesData = showDefensives and watcher:GetDefensiveState() or EMPTY
	local importantData = showImportant and GetImportantBuffs(data) or EMPTY
	local kickCount = kickEntry and 1 or 0

	local ccSlots, defensiveSlots, importantSlots =
		slotDistribution.Calculate(container.Count, #ccData + kickCount, #defensivesData, #importantData)

	local iconsGlow = barOptions.Icons.Glow
	local iconsReverse = barOptions.Icons.ReverseCooldown
	local showMilliseconds = barOptions.Icons.ShowMilliseconds
	local colorByCategory = barOptions.Icons.ColorByCategory
	local showTooltips = barOptions.ShowTooltips ~= false
	local fontScale = db.FontScale
	local slot = 0

	-- CC spells (highest priority); kick icon fills the first CC slot
	if ccSlots > 0 then
		if kickEntry then
			slot = slot + 1
			layerScratch.Texture = kickEntry.Texture
			layerScratch.DurationObject = kickEntry.DurationObject
			layerScratch.Alpha = true
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.ShowMilliseconds = showMilliseconds
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and kickEntry.Color or nil
			layerScratch.SpellId = nil
			container:SetSlot(slot, layerScratch)
			ccSlots = ccSlots - 1
		end
		for i = 1, mathMin(ccSlots, #ccData) do
			if slot >= container.Count then
				break
			end
			slot = slot + 1
			local entry = ccData[i]
			layerScratch.Texture = entry.SpellIcon
			layerScratch.DurationObject = entry.DurationObject
			layerScratch.Alpha = entry.IsCC
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.ShowMilliseconds = showMilliseconds
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and entry.DispelColor or nil
			layerScratch.SpellId = showTooltips and entry.SpellId or nil
			container:SetSlot(slot, layerScratch)
		end
	end

	-- Defensive spells (second priority)
	if defensiveSlots > 0 then
		for i = 1, mathMin(defensiveSlots, #defensivesData) do
			if slot >= container.Count then
				break
			end
			slot = slot + 1
			local entry = defensivesData[i]
			layerScratch.Texture = entry.SpellIcon
			layerScratch.DurationObject = entry.DurationObject
			layerScratch.Alpha = entry.IsDefensive
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.ShowMilliseconds = nil
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and defensiveColor or nil
			layerScratch.SpellId = showTooltips and entry.SpellId or nil
			container:SetSlot(slot, layerScratch)
		end
	end

	if importantSlots > 0 then
		for i = 1, mathMin(importantSlots, #importantData) do
			if slot >= container.Count then
				break
			end
			slot = slot + 1
			local entry = importantData[i]
			layerScratch.Texture = entry.SpellIcon
			layerScratch.DurationObject = entry.DurationObject
			layerScratch.Alpha = true
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.ShowMilliseconds = nil
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and importantColor or nil
			layerScratch.SpellId = showTooltips and entry.SpellId or nil
			container:SetSlot(slot, layerScratch)
		end
	end

	-- Clear any unused slots beyond the used count
	for i = slot + 1, container.Count do
		container:SetSlotUnused(i)
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

	-- Fetch once and pass down to avoid each Apply function re-traversing the db path
	local unitOptions = M:GetUnitOptions(unitToken)

	-- BUGFIX (duels): If GetUnitOptions() switches between Friendly and Enemy for the
	-- same unitToken (e.g. duel starts), the cached container references may be nil
	-- for the now-active options. Rebuild lazily so aura data isn't silently dropped.
	local needRebuild = false
	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		if barOptions and barOptions.Enabled and not data[bar.DataField] then
			needRebuild = true
		end
	end

	if needRebuild then
		local nameplate = data.Nameplate or C_NamePlate.GetNamePlateForUnit(unitToken)
		if nameplate then
			local bar1Container, bar2Container =
				EnsureContainersForNameplate(nameplate, unitToken, unitOptions)
			data.Bar1Container = bar1Container
			data.Bar2Container = bar2Container
		end
	end

	-- Dedup: an aura can be both a defensive and an "important" buff. When any enabled bar shows
	-- defensives, exclude those auras (by AuraInstanceID) from the important set on every bar so the
	-- same icon isn't drawn twice (defensives win - they carry the real category/duration tracking).
	wipe(importantSkipScratch)
	local anyDefensives, anyImportant = false, false
	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		if barOptions and barOptions.Enabled then
			anyDefensives = anyDefensives or barOptions.ShowDefensives
			anyImportant = anyImportant or barOptions.ShowImportant
		end
	end
	if anyDefensives and anyImportant then
		for _, d in ipairs(watcher:GetDefensiveState()) do
			if d.AuraInstanceID then
				importantSkipScratch[d.AuraInstanceID] = true
			end
		end
	end

	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		if barOptions and barOptions.Enabled then
			ApplyBarToNameplate(data[bar.DataField], barOptions, watcher, data)
		end
	end
end

---Shows test icons for one bar: CC test spells when the bar has ShowCC, defensive test spells
---when it has ShowDefensives, using the same CC-priority slot distribution as the live path.
local function ShowBarTestIcons(container, barOptions, now)
	if not container or not barOptions then
		return
	end

	local ccCount = barOptions.ShowCC and testCcCount or 0
	local defensiveCount = barOptions.ShowDefensives and testDefensiveCount or 0
	local importantCount = barOptions.ShowImportant and testImportantCount or 0
	local ccSlots, defensiveSlots, importantSlots =
		slotDistribution.Calculate(container.Count, ccCount, defensiveCount, importantCount)

	local iconsGlow = barOptions.Icons.Glow
	local iconsReverse = barOptions.Icons.ReverseCooldown
	local colorByCategory = barOptions.Icons.ColorByCategory
	local showTooltips = barOptions.ShowTooltips ~= false
	local fontScale = db.FontScale
	local slot = 0

	-- CC test spells first (highest priority)
	for i = 1, ccSlots do
		if slot >= container.Count then
			break
		end
		slot = slot + 1
		local spellId = testCcNameplateSpellIds[i]
		local tex = C_Spell.GetSpellTexture(spellId)
		if tex then
			layerScratch.Texture = tex
			layerScratch.DurationObject = wowEx:CreateDuration(now - (i - 1) * 0.5, 15 + (i - 1) * 3)
			layerScratch.Alpha = true
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and testCcDispelColors[spellId] or nil
			layerScratch.SpellId = showTooltips and spellId or nil
			container:SetSlot(slot, layerScratch)
		end
	end

	-- Defensive test spells (second priority)
	for i = 1, defensiveSlots do
		if slot >= container.Count then
			break
		end
		slot = slot + 1
		local spellId = testDefensiveNameplateSpellIds[i]
		local tex = C_Spell.GetSpellTexture(spellId)
		if tex then
			layerScratch.Texture = tex
			layerScratch.DurationObject = wowEx:CreateDuration(now - (i - 1) * 0.5, 15 + (i - 1) * 3)
			layerScratch.Alpha = true
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and defensiveColor or nil
			layerScratch.SpellId = showTooltips and spellId or nil
			container:SetSlot(slot, layerScratch)
		end
	end

	for i = 1, importantSlots do
		if slot >= container.Count then
			break
		end
		slot = slot + 1
		local spellId = testImportantNameplateSpellIds[i]
		local tex = C_Spell.GetSpellTexture(spellId)
		if tex then
			layerScratch.Texture = tex
			layerScratch.DurationObject = wowEx:CreateDuration(now - (i - 1) * 0.5, 15 + (i - 1) * 3)
			layerScratch.Alpha = true
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and importantColor or nil
			layerScratch.SpellId = showTooltips and spellId or nil
			container:SetSlot(slot, layerScratch)
		end
	end

	-- Clear any unused slots beyond what we just set
	for i = slot + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

local function OnNamePlateRemoved(unitToken)
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	HideAndReset(data.Bar1Container)
	HideAndReset(data.Bar2Container)

	-- Dispose of watcher
	if watchers[unitToken] then
		watchers[unitToken]:Dispose()
		watchers[unitToken] = nil
	end

	kickTracker:Unwatch(unitToken)

	-- Remove all data for this unit token
	nameplateAnchors[unitToken] = nil
end

local function HookNameplateAuraFrame(nameplate)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.RefreshAuras and not hookedAuraFrames[af] then
		hookedAuraFrames[af] = true
		hooksecurefunc(af, "RefreshAuras", function(self)
			if self.IsForbidden and self:IsForbidden() then
				return
			end
			local parent = self:GetParent()
			local u = parent and parent.unit
			if u and ImportantNeeded() and nameplateAnchors[u] and watchers[u] then
				OnAuraDataChanged(u)
			end
		end)
	end
end

local function OnNamePlateAdded(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	if not nameplate then
		return
	end

	HookNameplateAuraFrame(nameplate)

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	if not moduleEnabled then
		return
	end

	-- Check if we should ignore pets
	local unitOptions = M:GetUnitOptions(unitToken)
	if unitOptions.IgnorePets and units:IsPetOrMinion(unitToken) then
		return
	end

	-- Reuse containers stored on the nameplate; only create if missing
	local bar1Container, bar2Container =
		EnsureContainersForNameplate(nameplate, unitToken, unitOptions)

	-- BUGFIX (duels): Previously this returned early if no containers were created for
	-- the current options table (e.g. friendly player with Friendly.* all disabled).
	-- That meant `nameplateAnchors[unitToken]` and `watchers[unitToken]` were never
	-- populated, so when the unit later became a duel opponent and GetUnitOptions()
	-- started returning Enemy options, there was no watcher listening to UNIT_AURA and
	-- OnAuraDataChanged would never fire to rebuild containers.
	-- We now also create data+watcher if the *opposite* faction has any mode enabled,
	-- but only in the open world where duels can occur - inside instances this overhead
	-- is unnecessary since friendly units can never become duel opponents there.
	local inInstance = IsInInstance()
	local oppositeOptions = units:IsEnemy(unitToken) and nmModule.Friendly or nmModule.Enemy
	local anyEnabledOpposite = not inInstance
		and ((oppositeOptions.Bar1 and oppositeOptions.Bar1.Enabled)
			or (oppositeOptions.Bar2 and oppositeOptions.Bar2.Enabled))

	if not bar1Container and not bar2Container and not anyEnabledOpposite then
		return
	end

	-- Create / update nameplate data
	local data = {
		Nameplate = nameplate,
		Bar1Container = bar1Container,
		Bar2Container = bar2Container,
		UnitToken = unitToken,
	}
	nameplateAnchors[unitToken] = data

	-- Create new watcher
	if watchers[unitToken] then
		watchers[unitToken]:Dispose()
	end

	-- Important buffs are read straight from Blizzard's nameplate buff list (see GetImportantBuffs),
	-- so the watcher only tracks CC + defensives. We always track both (rather than narrowing to the
	-- bars' current ShowCC/ShowDefensives) so a duel faction flip can't leave the watcher querying the
	-- wrong aura types. Stated explicitly so we don't silently inherit any future change to the "all"
	-- default (e.g. if it ever started including buffs, which we don't want here).
	local sortRule, sortDirection = GetCCSortOptions()
	watchers[unitToken] = unitWatcher:New(unitToken, nil, { CC = true, Defensives = true }, sortRule, sortDirection)
	watchers[unitToken]:RegisterCallback(function()
		OnAuraDataChanged(unitToken)
	end)

	kickTracker:Watch(unitToken)
	kickTracker:Subscribe(unitToken, function()
		OnAuraDataChanged(unitToken)
	end)

	-- Initial update
	if testModeActive then
		-- In test mode, show test icons for this specific nameplate
		local now = GetTime()

		for _, bar in ipairs(BARS) do
			local barOptions = unitOptions[bar.Key]
			if barOptions and barOptions.Enabled and data[bar.DataField] then
				ShowBarTestIcons(data[bar.DataField], barOptions, now)
			end
		end
	end
end

local function ClearNameplate(unitToken)
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	for _, bar in ipairs(BARS) do
		if data[bar.DataField] then
			data[bar.DataField]:ResetAllSlots()
		end
	end
end

local function DisableWatchers()
	for _, watcher in pairs(watchers) do
		if watcher then
			watcher:Disable()
		end
	end

	for unitToken, _ in pairs(nameplateAnchors) do
		ClearNameplate(unitToken)
	end
end

local function EnableWatchers()
	for _, watcher in pairs(watchers) do
		if watcher then
			watcher:Enable()
		end
	end
end

local function RebuildContainers()
	if not moduleUtil:IsModuleEnabled(moduleName.Nameplates) then
		return
	end

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
	return nmModule.Friendly.Bar1.Enabled
		or nmModule.Friendly.Bar2.Enabled
		or nmModule.Enemy.Bar1.Enabled
		or nmModule.Enemy.Bar2.Enabled
end

local function CacheEnabledModes()
	local enemy = nmModule.Enemy
	local friendly = nmModule.Friendly
	local enabled = nmModule.Enabled

	previousEnemyEnabled.Bar1 = enemy.Bar1.Enabled
	previousEnemyEnabled.Bar2 = enemy.Bar2.Enabled

	previousFriendlyEnabled.Bar1 = friendly.Bar1.Enabled
	previousFriendlyEnabled.Bar2 = friendly.Bar2.Enabled

	previousPetEnabled.Friendly = friendly.IgnorePets
	previousPetEnabled.Enemy = enemy.IgnorePets

	previousModuleEnabled.Always = enabled.Always
	previousModuleEnabled.Arena = enabled.Arena
	previousModuleEnabled.BattleGrounds = enabled.BattleGrounds
	previousModuleEnabled.PvE = enabled.PvE

	previousImportantNeeded = ImportantNeeded()
end

local function HaveModesChanged()
	local enemy = nmModule.Enemy
	local friendly = nmModule.Friendly
	local enabled = nmModule.Enabled

	return previousEnemyEnabled.Bar1 ~= enemy.Bar1.Enabled
		or previousEnemyEnabled.Bar2 ~= enemy.Bar2.Enabled
		or previousFriendlyEnabled.Bar1 ~= friendly.Bar1.Enabled
		or previousFriendlyEnabled.Bar2 ~= friendly.Bar2.Enabled
		or previousPetEnabled.Friendly ~= friendly.IgnorePets
		or previousPetEnabled.Enemy ~= enemy.IgnorePets
		or previousModuleEnabled.Always ~= enabled.Always
		or previousModuleEnabled.Arena ~= enabled.Arena
		or previousModuleEnabled.BattleGrounds ~= enabled.BattleGrounds
		or previousModuleEnabled.PvE ~= enabled.PvE
		or previousImportantNeeded ~= ImportantNeeded()
end

local function ShowTestIcons()
	local now = GetTime()
	for _, data in pairs(nameplateAnchors) do
		local options = M:GetUnitOptions(data.UnitToken)
		for _, bar in ipairs(BARS) do
			local barOptions = options[bar.Key]
			if barOptions and barOptions.Enabled and data[bar.DataField] then
				ShowBarTestIcons(data[bar.DataField], barOptions, now)
			end
		end
	end
end

local function RefreshAnchorsAndSizes()
	local ignoreParentScale = not nmModule.ScaleWithNameplate
	for _, data in pairs(nameplateAnchors) do
		if data.Nameplate and data.UnitToken then
			local unitOptions = M:GetUnitOptions(data.UnitToken)
			local anchorFrame = GetNameplateAnchorFrame(data.Nameplate)

			-- Both bars are independent; reposition each that exists.
			for _, bar in ipairs(BARS) do
				local container = data[bar.DataField]
				local barOptions = unitOptions[bar.Key]
				if container then
					container.Frame:ClearAllPoints()

					if barOptions and barOptions.Enabled then
						local anchorPoint, relativeToPoint = GrowToAnchor(barOptions.Grow)
						container.Frame:SetPoint(
							anchorPoint,
							anchorFrame,
							relativeToPoint,
							barOptions.Offset.X,
							barOptions.Offset.Y
						)
						container:SetGrowDown(barOptions.Grow == "DOWN")
						container:SetIconSize(barOptions.Icons.Size)
						container:SetSpacing(db.IconSpacing or 2)
						container:SetCount(barOptions.Icons.MaxIcons)
						container.Frame:SetFrameLevel(anchorFrame:GetFrameLevel() + 10)
					end
					container.Frame:SetIgnoreParentScale(ignoreParentScale)
				end
			end
		end
	end
end

local function ClearAll()
	-- Clean up all existing nameplates
	for unitToken, _ in pairs(nameplateAnchors) do
		ClearNameplate(unitToken)
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
		return nmModule.Enemy
	end

	if units:IsFriend(unitToken) then
		return nmModule.Friendly
	end

	return nmModule.Enemy
end

function M:StartTesting()
	testModeActive = true
	Pause()

	M:Refresh()
end

function M:StopTesting()
	testModeActive = false
	ClearAll()

	Resume()

	-- Refresh all nameplates
	for _, watcher in pairs(watchers) do
		watcher:ForceFullUpdate()
	end
end

local function ApplyBlizzardNameplateSettings()
	local configureEnabled = db.ConfigureBlizzardNameplates
	if configureEnabled == nil then
		configureEnabled = true
	end

	local anyEnemyEnabled = nmModule.Enemy.Bar1.Enabled
		or nmModule.Enemy.Bar2.Enabled

	local anyFriendlyEnabled = nmModule.Friendly.Bar1.Enabled
		or nmModule.Friendly.Bar2.Enabled

	if configureEnabled and anyEnemyEnabled then
		C_CVar.SetCVarBitfield("nameplateEnemyPlayerAuraDisplay", Enum.NamePlateEnemyPlayerAuraDisplay.LossOfControl, false)
		C_CVar.SetCVarBitfield("nameplateEnemyNpcAuraDisplay", Enum.NamePlateEnemyNpcAuraDisplay.CrowdControl, false)
	end

	if configureEnabled and anyFriendlyEnabled then
		C_CVar.SetCVarBitfield("nameplateFriendlyPlayerAuraDisplay", Enum.NamePlateFriendlyPlayerAuraDisplay.LossOfControl, false)
	end
end

function M:Refresh()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)

	if not moduleEnabled or not AnyEnabled() then
		DisableWatchers()
		CacheEnabledModes()
		return
	end

	ApplyBlizzardNameplateSettings()

	-- Module is enabled, ensure watchers are enabled
	EnableWatchers()

	-- if the user has enabled/disabled a mode, rebuild the containers
	if HaveModesChanged() then
		RebuildContainers()
	end

	CacheEnabledModes()
	RefreshAnchorsAndSizes()

	local sortRule, sortDirection = GetCCSortOptions()
	for _, watcher in pairs(watchers) do
		watcher:SetSort(sortRule, sortDirection)
	end

	if testModeActive then
		-- update test icons
		ShowTestIcons()
	end
end

function M:Init()
	db = mini:GetSavedVars()
	-- Cache once so all hot-path functions avoid repeatedly traversing db -> Modules -> NameplatesModule
	nmModule = db.Modules.NameplatesModule

	local eventFrame = CreateFrame("Frame")
	eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
	eventFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "NAME_PLATE_UNIT_ADDED" then
			OnNamePlateAdded(unitToken)
			-- refresh their aura information
			-- important to do it here an not inside of OnNamePlateAdded because that is also called by Refresh
			-- which would cause a significant performance impact
			OnAuraDataChanged(unitToken)
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		end
	end)

	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Nameplates)
	if moduleEnabled and AnyEnabled() then
		-- Initialize existing nameplates
		RebuildContainers()
	end

	CacheEnabledModes()
end
