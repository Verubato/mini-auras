---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local units = addon.Utils.Units
local auras = addon.Utils.Auras
local kickTracker = addon.Core.KickTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local growAnchors = addon.Core.GrowAnchors
local kickSlot = addon.Core.KickSlot
local slotDistribution = addon.Utils.SlotDistribution
local testSpellData = addon.Core.TestSpells
local mathMin = math.min
local GetTime = GetTime
local C_NamePlate = C_NamePlate

addon.Modules.Nameplates = addon.Modules.Nameplates or {}

---@class NameplatesDisplay
local M = {}
addon.Modules.Nameplates.Display = M

-- 12.1 path: each bar gets its own AuraContainer per nameplate token (reparented to the plate
-- and retargeted with SetUnit as plates come and go) with one group per category; the bar's
-- IconSlotContainer is kept for the kick icon and test icons. The
-- legacy watcher/buffList path never runs there
-- (no watchers are created). Deviations forced by aura data being unreadable: no dynamic slot
-- split between categories (each enabled category gets the bar's full MaxIcons budget) and no
-- category colours (ColorByCategory maps to dispel-type colouring). TEMPORARY dual path:
-- remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type Db
local db
---@type table
local nmModule
local testModeActive = false
local paused = false
---@type table<string, NameplateData>
local nameplateAnchors = {}

local TEST_CC_NAMEPLATE_SPELL_IDS = testSpellData.Nameplates.CrowdControl
local TEST_DEFENSIVE_NAMEPLATE_SPELL_IDS = testSpellData.Nameplates.Defensive
local TEST_IMPORTANT_NAMEPLATE_SPELL_IDS = testSpellData.Nameplates.Important
-- Pre-computed lengths; these lists never change at runtime so recalculating
-- #list on every test-mode call is pure waste.
local TEST_CC_COUNT = #TEST_CC_NAMEPLATE_SPELL_IDS
local TEST_DEFENSIVE_COUNT = #TEST_DEFENSIVE_NAMEPLATE_SPELL_IDS
local TEST_IMPORTANT_COUNT = #TEST_IMPORTANT_NAMEPLATE_SPELL_IDS

local TEST_CC_DISPEL_COLORS = testSpellData.Nameplates.DispelColors

-- Caption locale keys for the test-mode bar labels, matching the config tab titles.
local TEST_BAR_LABELS = {
	Enemy = { Bar1 = "Enemy - Bar 1", Bar2 = "Enemy - Bar 2" },
	Friendly = { Bar1 = "Friendly - Bar 1", Bar2 = "Friendly - Bar 2" },
}

-- Category colors
local DEFENSIVE_COLOR = { r = 0.0, g = 0.8, b = 0.0 } -- Green
local IMPORTANT_COLOR = { r = 0.9, g = 0.1, b = 0.1 } -- Red

-- Per-category test data driving ShowBarTestIcons: the bar option that shows the category, its
-- spell list and precomputed length, and the glow colour (per spell for CC, fixed otherwise).
local TEST_BAR_CATEGORIES = {
	{ Show = "ShowCC", Ids = TEST_CC_NAMEPLATE_SPELL_IDS, Count = TEST_CC_COUNT, Colors = TEST_CC_DISPEL_COLORS },
	{ Show = "ShowDefensives", Ids = TEST_DEFENSIVE_NAMEPLATE_SPELL_IDS, Count = TEST_DEFENSIVE_COUNT, Color = DEFENSIVE_COLOR },
	{ Show = "ShowImportant", Ids = TEST_IMPORTANT_NAMEPLATE_SPELL_IDS, Count = TEST_IMPORTANT_COUNT, Color = IMPORTANT_COLOR },
}
-- Reused per-call slot budgets, parallel to TEST_BAR_CATEGORIES.
local testBudgetScratch = {}

-- Reusable scratch table for SetSlot calls.
-- This avoids creating a new table on every aura update for every nameplate slot,
-- which significantly reduces garbage collection pressure.
local layerScratch = {}

-- Shared empty list returned when a bar isn't showing a given spell type. Never mutate this.
local EMPTY = {}

local importantDisplayScratch = {}
local importantEntryPool = {}
-- AuraInstanceIDs already shown as defensives this update, excluded from the important set so a
-- both-important-and-defensive aura isn't drawn twice. Rebuilt per unit in RenderUnit.
local importantSkipScratch = {}

local NAMEPLATE_BAR1_KEY = addonName .. "_Bar1Container"
local NAMEPLATE_BAR2_KEY = addonName .. "_Bar2Container"

-- The two generic nameplate bars. Each bar independently shows CC, defensives, and/or important
-- buffs based on its ShowCC / ShowDefensives / ShowImportant options, and both bars can display
-- at the same time.
local BARS = {
	{ Key = "Bar1", ContainerKey = NAMEPLATE_BAR1_KEY, DataField = "Bar1Container", DisplayField = "Bar1Display" },
	{ Key = "Bar2", ContainerKey = NAMEPLATE_BAR2_KEY, DataField = "Bar2Container", DisplayField = "Bar2Display" },
}

-- 12.1 path: one AuraContainer per (nameplate token, bar), built with its bar's full
-- configuration and kept for the session.
--
-- Not pooled. Everything StyleButton applies - size, swipe, countdown, glow, dispel textures -
-- is baked into a button when the frame pool creates it and can only be changed by a restyle,
-- which is blocked for as long as C_Secrets.ShouldAurasBeSecret is true (a whole arena). A
-- generic pool hands out displays built for some other bar's configuration, which then cannot be
-- corrected. Building per bar means a display is right from the moment it exists.
--
-- Cached per token rather than created per plate spawn because WoW frames can never be freed:
-- tokens are a small fixed set (nameplate1..N) so this is bounded, whereas creating one per
-- spawn would grow for the whole session. Exactly ONE display per (token, bar): a configuration
-- change restyles it in place rather than building a replacement. Keying on the configuration
-- instead meant every step of an icon-size slider drag built a fresh display for every tracked
-- plate - twenty buttons apiece, each with its own cooldown, border and animated glow - and left
-- all of them resident for the session.
--
-- Restyling is impossible while auras are secret, but that is already handled: ApplyConfig stores
-- the new values and flags the display, and AuraContainerDisplay's retry settles the buttons when
-- the restriction lifts. The cost is that a change made inside an arena shows late, which is the
-- same deal every other display in the addon takes.
---@type table<string, table<string, {Display: AuraContainerDisplay, Signature: string}>>
local barDisplays = {}
-- Fallbacks for a bar with no configured geometry.
local DEFAULT_BAR_ICONS = 5
local DEFAULT_BAR_SIZE = 35
local DEFAULT_BAR_SPACING = 2

---@param container IconSlotContainer?
local function HideAndReset(container)
	if not container then
		return
	end
	container:ResetAllSlots()
	container.Frame:Hide()
end

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
	-- Optionally anchor to the health bar container: addons that resize plates (e.g.
	-- BetterBlizzPlates) do it by shrinking HealthBarsContainer, which the base nameplate
	-- frame doesn't follow. Deliberately NOT HealthBarsContainer.healthBar - that bar
	-- shifts around inside the container with the anti-heal display (since TWW).
	if nmModule.AnchorToHealthBar then
		local uf = nameplate.UnitFrame
		local healthBars = uf and uf.HealthBarsContainer
		if healthBars then
			return healthBars
		end
	end
	return nameplate
end

---Applies a bar's full geometry to its container: anchor on the plate, frame level, scale
---behaviour, slot count/size/spacing and grow direction. The single path both the plate-add
---build and the options refresh take, so the two can never diverge.
local function ApplyContainerLayout(container, nameplate, barOptions)
	local anchorFrame = GetNameplateAnchorFrame(nameplate)
	local anchorPoint, relativeToPoint = growAnchors:GetAnchor(barOptions.Grow)
	local frame = container.Frame

	frame:ClearAllPoints()
	frame:SetPoint(anchorPoint, anchorFrame, relativeToPoint, barOptions.Offset.X or 0, barOptions.Offset.Y or 0)
	frame:SetFrameLevel(anchorFrame:GetFrameLevel() + 10)
	frame:EnableMouse(false)
	frame:SetIgnoreParentScale(not nmModule.ScaleWithNameplate)

	container:SetIconSize(barOptions.Icons.Size or 35)
	container:SetCount(barOptions.Icons.MaxIcons or 5)
	container:SetSpacing(barOptions.Icons.Spacing or 2)
	container:SetGrowDown(barOptions.Grow == "DOWN")
	-- Grow LEFT mirrors the slots so slot 1 (highest priority - e.g. the important buffs
	-- Blizzard sorts to the front) sits at the rightmost icon, nearest the nameplate. RIGHT and
	-- DOWN already place slot 1 nearest the anchor.
	container:SetRows(nil, "CENTER", barOptions.Grow == "LEFT")
end

---12.1 path: positions a bar's aura display, chaining after the bar's kick container while a
---kick icon is showing.
local function AnchorBarDisplay(display, container, nameplate, barOptions, kickActive)
	local anchorFrame = GetNameplateAnchorFrame(nameplate)
	local frame = display.Frame
	frame:SetFrameLevel(anchorFrame:GetFrameLevel() + 10)
	frame:SetIgnoreParentScale(not nmModule.ScaleWithNameplate)

	display:AnchorAfterKick(
		container.Frame,
		anchorFrame,
		barOptions.Grow or "CENTER",
		barOptions.Icons.Spacing or 2,
		barOptions.Offset.X or 0,
		barOptions.Offset.Y or 0,
		kickActive
	)
end

---12.1 path: builds one pooled bar display with the four standard categories (partitioned by
---filter negation, see Core/AuraFilters). Budgets/unit/style are applied per bar on acquisition;
---the size is fixed here because the buttons take it at creation and can't be resized in an arena.
---@param size number
---@param spacing number
---@param style AuraDisplayStyle applied at creation; it cannot be changed while auras are secret
local function CreateBarDisplay(size, spacing, style)
	return auraContainerDisplay:New(
		UIParent,
		"none",
		auraFilters:BuildCategoryGroups(DEFAULT_BAR_ICONS),
		size,
		spacing,
		"Nameplates",
		{ Style = style }
	)
end

---12.1 path: parks a pooled bar display.
local function ResetBarDisplay(display)
	display:SetEnabled(false)
	display:Hide()
	display.Frame:ClearAllPoints()
	display.Frame:SetParent(UIParent)
end

---@return number the icon size a bar's displays must be built at
local function BarIconSize(barOptions)
	return tonumber(barOptions.Icons.Size) or DEFAULT_BAR_SIZE
end

---Fills the shared style scratch from a bar's options.
---@return AuraDisplayStyle
local function BarStyle(barOptions)
	local style = auraContainerDisplay:BuildStandardStyle(barOptions.Icons)
	-- Nameplates stores the toggle as ColorByCategory, which the standard reader doesn't know;
	-- category colours can't be applied per group, so dispel-type colouring is the nearest fit.
	style.ColorByDispelType = barOptions.Icons.ColorByCategory
	style.ShowTooltips = barOptions.ShowTooltips ~= false
	return style
end

---12.1 path: acquires (or reuses) and reconfigures a bar's aura display for a tracked plate.
---@param data NameplateData
local function EnsureBarDisplay(data, bar, barOptions)
	local token = data.UnitToken
	local size = BarIconSize(barOptions)
	local spacing = barOptions.Icons.Spacing or DEFAULT_BAR_SPACING
	local maxIcons = barOptions.Icons.MaxIcons or 5
	local style = BarStyle(barOptions)
	local signature = auraContainerDisplay:GetStyleSignature(style, size, spacing)

	local byBar = barDisplays[token]

	if not byBar then
		byBar = {}
		barDisplays[token] = byBar
	end

	-- One display per bar, restyled when the configuration moves. The same token legitimately
	-- alternates between configurations - GetUnitOptions returns Friendly or Enemy for it and a
	-- duel flips that mid-session - so this path is hot enough that it must not build frames.
	local entry = byBar[bar.Key]

	if not entry then
		entry = { Display = CreateBarDisplay(size, spacing, style), Signature = signature }
		byBar[bar.Key] = entry
	elseif entry.Signature ~= signature then
		-- One restyle pass for all three values; the individual setters would each walk every
		-- button. Records the new signature even when the restyle has to defer, because the
		-- display now WANTS this configuration and the retry will finish applying it.
		entry.Display:ApplyConfig(size, spacing, style)
		entry.Signature = signature
	end

	local display = entry.Display

	-- Park whatever this bar was showing if it isn't the display we're about to use.
	local previous = data[bar.DisplayField]

	if previous and previous ~= display then
		ResetBarDisplay(previous)
	end

	data[bar.DisplayField] = display

	display.Frame:SetParent(data.Nameplate)
	display:SetUnit(token)
	auraFilters:ApplyCategoryBudgets(
		display,
		maxIcons,
		barOptions.ShowCC,
		barOptions.ShowDefensives,
		barOptions.ShowImportant
	)

	-- No SetStyle here: the style was applied when the display was built, and a signature change
	-- rebuilds it. Restyling would be a no-op out of combat and impossible inside an arena.
	--
	-- SetEnabled(false -> true) triggers the container's own full refresh, so a display reused
	-- for a recycled unit token still repopulates.
	display:SetEnabled(true)
	display:SetShown(not testModeActive)

	return display
end

---12.1 path: acquires/reconfigures displays for every enabled bar on a tracked plate and
---releases displays of bars that are now disabled.
---@param data NameplateData
local function EnsureBarDisplays(data, unitOptions)
	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		local container = data[bar.DataField]
		if barOptions and barOptions.Enabled and container then
			local display = EnsureBarDisplay(data, bar, barOptions)
			local kickActive = barOptions.ShowCC and kickTracker:GetKick(data.UnitToken) ~= nil
			AnchorBarDisplay(display, container, data.Nameplate, barOptions, kickActive)
		else
			local display = data[bar.DisplayField]
			if display then
				data[bar.DisplayField] = nil
				ResetBarDisplay(display)
			end
		end
	end
end

---@param nameplate table
---@param unitToken string
---@param unitOptions table
---@return IconSlotContainer? bar1Container, IconSlotContainer? bar2Container
local function EnsureContainersForNameplate(nameplate, unitToken, unitOptions)
	-- Each bar shows when its own Enabled flag is set, so both bars can display at once.
	local bar1Container, bar2Container
	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		if barOptions and barOptions.Enabled then
			local container = nameplate[bar.ContainerKey]
			if not container then
				container = iconSlotContainer:New(
					nameplate,
					barOptions.Icons.MaxIcons or 5,
					barOptions.Icons.Size or 35,
					barOptions.Icons.Spacing or 2,
					"Nameplates",
					nil,
					"Nameplates"
				)
				nameplate[bar.ContainerKey] = container
			end

			-- Runs on every container (re)build, so newly-shown nameplates get the current
			-- geometry without waiting for a config refresh.
			ApplyContainerLayout(container, nameplate, barOptions)
			container.Frame:Show()

			if bar.Key == "Bar1" then
				bar1Container = container
			else
				bar2Container = container
			end
		else
			HideAndReset(nameplate[bar.ContainerKey])
		end
	end

	return bar1Container, bar2Container
end

local function GetNameplateBuffList(nameplate)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.buffList and af.buffList.Iterate and not (af.IsForbidden and af:IsForbidden()) then
		return af.buffList
	end
	return nil
end

-- Context for the in-progress GetImportantBuffs iteration. Passed to the hoisted callback via these
-- upvalues rather than a per-call closure, since the buff scan runs on the aura hot path.
local importantIterUnit -- luaconv: context for the hoisted callback below
-- Set for friendly units (including duel opponents, who are same-faction): an extra nameplate aura
-- filter to drop the non-important buffs friendly nameplates list (Blizzard only pre-curates ENEMY
-- buff lists to the important ones), since we can't evaluate importance ourselves
-- (C_Spell.IsSpellImportant is a secret value that can't be compared/filtered). nil for enemies,
-- whose list is already curated.
local importantIterFriendlyFilter -- luaconv: context for the hoisted callback below

local function CollectImportantBuff(auraInstanceID)
	if importantSkipScratch[auraInstanceID] then
		return
	end
	local unit = importantIterUnit
	if importantIterFriendlyFilter
		and C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, importantIterFriendlyFilter) then
		return
	end
	-- Drop purgeable non-defensive buffs: the non-important garbage Blizzard's enemy list bundles in
	-- with the real cooldowns. Purgeable defensives (e.g. magic barriers) are kept.
	if auras:IsPurgeableNonDefensive(unit, auraInstanceID) then
		return
	end
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
		-- Hide non-important survivors via alpha. IsSpellImportant is a secret boolean we can't branch
		-- on, but SetAlphaFromBoolean accepts it directly (same as IsCC/IsDefensive). This catches the
		-- non-important garbage the purgeable filter can't (e.g. for non-dispel specs, where
		-- RAID_PLAYER_DISPELLABLE matches nothing).
		entry.ImportantAlpha = C_Spell.IsSpellImportant(aura.spellId)
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
		importantIterFriendlyFilter = units:IsFriend(data.UnitToken)
			and "HELPFUL|INCLUDE_NAME_PLATE_ONLY|RAID_IN_COMBAT|PLAYER"
			or nil
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
			layerScratch.Color = colorByCategory and DEFENSIVE_COLOR or nil
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
			layerScratch.Alpha = entry.ImportantAlpha
			layerScratch.Glow = iconsGlow
			layerScratch.ReverseCooldown = iconsReverse
			layerScratch.ShowMilliseconds = nil
			layerScratch.FontScale = fontScale
			layerScratch.Color = colorByCategory and IMPORTANT_COLOR or nil
			layerScratch.SpellId = showTooltips and entry.SpellId or nil
			container:SetSlot(slot, layerScratch)
		end
	end

	-- Clear any unused slots beyond the used count
	for i = slot + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

---Shows test icons for one bar, walking TEST_BAR_CATEGORIES in priority order (CC first) and
---dividing the slots with the same distribution as the live path.
local function ShowBarTestIcons(container, barOptions, now)
	if not container or not barOptions then
		return
	end

	local budgets = testBudgetScratch
	budgets[1], budgets[2], budgets[3] = slotDistribution.Calculate(
		container.Count,
		barOptions[TEST_BAR_CATEGORIES[1].Show] and TEST_BAR_CATEGORIES[1].Count or 0,
		barOptions[TEST_BAR_CATEGORIES[2].Show] and TEST_BAR_CATEGORIES[2].Count or 0,
		barOptions[TEST_BAR_CATEGORIES[3].Show] and TEST_BAR_CATEGORIES[3].Count or 0
	)

	local iconsGlow = barOptions.Icons.Glow
	local iconsReverse = barOptions.Icons.ReverseCooldown
	local colorByCategory = barOptions.Icons.ColorByCategory
	local showTooltips = barOptions.ShowTooltips ~= false
	local fontScale = db.FontScale
	local slot = 0

	for index, category in ipairs(TEST_BAR_CATEGORIES) do
		for i = 1, budgets[index] do
			if slot >= container.Count then
				break
			end
			slot = slot + 1
			local spellId = category.Ids[i]
			local tex = C_Spell.GetSpellTexture(spellId)
			if tex then
				layerScratch.Texture = tex
				layerScratch.DurationObject = wowEx:CreateDuration(now - (i - 1) * 0.5, 15 + (i - 1) * 3)
				layerScratch.Alpha = true
				layerScratch.Glow = iconsGlow
				layerScratch.ReverseCooldown = iconsReverse
				layerScratch.FontScale = fontScale
				layerScratch.Color = colorByCategory and (category.Colors and category.Colors[spellId] or category.Color) or nil
				layerScratch.SpellId = showTooltips and spellId or nil
				container:SetSlot(slot, layerScratch)
			end
		end
	end

	-- Clear any unused slots beyond what we just set
	for i = slot + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

---@param data NameplateData
local function ShowDataTestIcons(data, now)
	local options = M:GetUnitOptions(data.UnitToken)
	local barLabels = options == nmModule.Enemy and TEST_BAR_LABELS.Enemy or TEST_BAR_LABELS.Friendly
	for _, bar in ipairs(BARS) do
		local barOptions = options[bar.Key]
		if barOptions and barOptions.Enabled and data[bar.DataField] then
			ShowBarTestIcons(data[bar.DataField], barOptions, now)
			moduleUtil:SetTestLabel(data[bar.DataField].Frame, L[barLabels[bar.Key]])
		end
	end
end

---Which faction's bar options apply to a token. Friendly units can also be enemies in a duel,
---so the enemy check comes first.
function M:GetUnitOptions(unitToken)
	if units:IsEnemy(unitToken) then
		return nmModule.Enemy
	end

	if units:IsFriend(unitToken) then
		return nmModule.Friendly
	end

	return nmModule.Enemy
end

---@return boolean true when any enabled bar on either faction is showing important buffs
function M:ImportantNeeded()
	local enemy = nmModule.Enemy
	local friendly = nmModule.Friendly
	return (enemy.Bar1.Enabled and enemy.Bar1.ShowImportant)
		or (enemy.Bar2.Enabled and enemy.Bar2.ShowImportant)
		or (friendly.Bar1.Enabled and friendly.Bar1.ShowImportant)
		or (friendly.Bar2.Enabled and friendly.Bar2.ShowImportant)
		or false
end

---@return boolean true when any bar on either faction is switched on
function M:AnyEnabled()
	return nmModule.Friendly.Bar1.Enabled
		or nmModule.Friendly.Bar2.Enabled
		or nmModule.Enemy.Bar1.Enabled
		or nmModule.Enemy.Bar2.Enabled
end

---@param unitToken string
---@return NameplateData?
function M:GetData(unitToken)
	return nameplateAnchors[unitToken]
end

---Every tracked token, for the callers that have to sweep them all.
---@return table<string, NameplateData>
function M:GetTrackedPlates()
	return nameplateAnchors
end

---@param value boolean
function M:SetPaused(value)
	paused = value
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

---Builds (or refreshes) everything a tracked plate draws with: the per-bar kick containers, and
---on 12.1 the aura displays and kick icon.
---@param unitToken string
---@param nameplate table
---@param unitOptions table
---@param trackAnyway boolean? track even with no enabled bar, so a duel flip has state to rebuild from
---@return NameplateData? data nil when neither bar is enabled for this token
function M:Track(unitToken, nameplate, unitOptions, trackAnyway)
	-- Reuse containers stored on the nameplate; only create if missing
	local bar1Container, bar2Container =
		EnsureContainersForNameplate(nameplate, unitToken, unitOptions)

	if not bar1Container and not bar2Container and not trackAnyway then
		return nil
	end

	-- Create / update nameplate data. Displays live in the per-token cache rather than on this
	-- table, so a rebuild for an already-tracked token picks them back up on the next Ensure.
	local previous = nameplateAnchors[unitToken]
	if previous and previous.KickTimer then
		previous.KickTimer:Cancel()
	end
	local data = {
		Nameplate = nameplate,
		Bar1Container = bar1Container,
		Bar2Container = bar2Container,
		Bar1Display = previous and previous.Bar1Display or nil,
		Bar2Display = previous and previous.Bar2Display or nil,
		UnitToken = unitToken,
	}
	nameplateAnchors[unitToken] = data

	if USE_AURA_CONTAINERS then
		EnsureBarDisplays(data, unitOptions)
	end

	return data
end

---Hides a tracked plate's containers, parks its displays and forgets it.
---@param unitToken string
function M:Untrack(unitToken)
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	HideAndReset(data.Bar1Container)
	HideAndReset(data.Bar2Container)

	-- 12.1: park this plate's displays; the per-token cache keeps them for its return.
	if USE_AURA_CONTAINERS then
		self:Release(unitToken)
	end

	nameplateAnchors[unitToken] = nil
end

---12.1 path: releases a tracked plate's pooled displays (and its kick timer). Used when the
---plate goes away AND when tracking stops for other reasons (module/pet options turning off
---for an already-tracked token) so displays never linger active outside the pool.
---@param unitToken string
function M:Release(unitToken)
	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	if data.KickTimer then
		data.KickTimer:Cancel()
		data.KickTimer = nil
	end
	-- Parked, not discarded: the cache keeps them for when this token comes back, since a
	-- rebuild per plate spawn would grow frames forever.
	if data.Bar1Display then
		ResetBarDisplay(data.Bar1Display)
		data.Bar1Display = nil
	end
	if data.Bar2Display then
		ResetBarDisplay(data.Bar2Display)
		data.Bar2Display = nil
	end
end

---12.1 path: renders the kick icon into each ShowCC bar's kick container (slot 1) and re-anchors
---the aura displays around it. Schedules a follow-up when the kick expires, since no aura event
---will fire to clear it.
---@param data NameplateData
function M:UpdateKick(data)
	if paused or testModeActive then
		return
	end

	local unitOptions = self:GetUnitOptions(data.UnitToken)
	local kickEntry = kickTracker:GetKick(data.UnitToken)

	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		local container = data[bar.DataField]
		if barOptions and barOptions.Enabled and container then
			if barOptions.ShowCC and kickEntry then
				layerScratch.Texture = kickEntry.Texture
				layerScratch.DurationObject = kickEntry.DurationObject
				layerScratch.Alpha = true
				layerScratch.Glow = barOptions.Icons.Glow
				layerScratch.ReverseCooldown = barOptions.Icons.ReverseCooldown
				layerScratch.ShowMilliseconds = barOptions.Icons.ShowMilliseconds
				layerScratch.FontScale = db.FontScale
				layerScratch.Color = barOptions.Icons.ColorByCategory and kickEntry.Color or nil
				layerScratch.SpellId = nil
				container:SetSlot(1, layerScratch)
			else
				container:SetSlotUnused(1)
			end

			local display = data[bar.DisplayField]
			if display then
				AnchorBarDisplay(display, container, data.Nameplate, barOptions, barOptions.ShowCC and kickEntry ~= nil)
			end
		end
	end

	-- One timer for the plate: the icon is written into every enabled bar above, but they all
	-- clear at the same moment.
	data.KickTimer = kickSlot:ScheduleExpiry(kickEntry, data.KickTimer, function()
		data.KickTimer = nil
		M:UpdateKick(data)
	end)
end

---Legacy path: redraws every enabled bar on a tracked plate from the watcher's aura state.
---@param unitToken string
---@param watcher Watcher?
function M:RenderUnit(unitToken, watcher)
	if paused or not unitToken then
		return
	end

	local data = nameplateAnchors[unitToken]
	if not data then
		return
	end

	if not watcher then
		return
	end

	-- Fetch once and pass down to avoid each Apply function re-traversing the db path
	local unitOptions = self:GetUnitOptions(unitToken)

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

---Draws the test preview on one plate; used when a plate spawns while test mode is on.
---@param data NameplateData
function M:ShowTestIconsFor(data)
	ShowDataTestIcons(data, GetTime())
end

function M:ShowTestIcons()
	local now = GetTime()
	for _, data in pairs(nameplateAnchors) do
		ShowDataTestIcons(data, now)
	end
end

---@param unitToken string
function M:ClearPlate(unitToken)
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

function M:ClearAll()
	for unitToken in pairs(nameplateAnchors) do
		self:ClearPlate(unitToken)
	end
end

function M:RefreshAnchorsAndSizes()
	local ignoreParentScale = not nmModule.ScaleWithNameplate
	for _, data in pairs(nameplateAnchors) do
		if data.Nameplate and data.UnitToken then
			local unitOptions = self:GetUnitOptions(data.UnitToken)

			-- Both bars are independent; reposition each that exists.
			for _, bar in ipairs(BARS) do
				local container = data[bar.DataField]
				local barOptions = unitOptions[bar.Key]
				if container then
					if barOptions and barOptions.Enabled then
						ApplyContainerLayout(container, data.Nameplate, barOptions)

						-- 12.1: re-apply option changes to the bar's aura display too.
						if USE_AURA_CONTAINERS then
							local display = EnsureBarDisplay(data, bar, barOptions)
							local kickActive = barOptions.ShowCC and kickTracker:GetKick(data.UnitToken) ~= nil
							AnchorBarDisplay(display, container, data.Nameplate, barOptions, kickActive)
						end
					else
						container.Frame:ClearAllPoints()
						container.Frame:SetIgnoreParentScale(ignoreParentScale)
					end
				end
			end
		end
	end
end

function M:Teardown()
	for unitToken, data in pairs(nameplateAnchors) do
		self:ClearPlate(unitToken)
		if data.Bar1Display then
			data.Bar1Display:SetEnabled(false)
			data.Bar1Display:Hide()
		end
		if data.Bar2Display then
			data.Bar2Display:SetEnabled(false)
			data.Bar2Display:Hide()
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()
	-- Cache once so all hot-path functions avoid repeatedly traversing db -> Modules -> NameplatesModule
	nmModule = db.Modules.NameplatesModule
end

---@class NameplateData
---@field Nameplate table
---@field Bar1Container IconSlotContainer?
---@field Bar2Container IconSlotContainer?
---@field Bar1Display AuraContainerDisplay? 12.1 path only.
---@field Bar2Display AuraContainerDisplay? 12.1 path only.
---@field KickTimer table? 12.1 path only: timer that clears the kick icon on expiry.
---@field UnitToken string
