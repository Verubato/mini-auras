---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local units = addon.Utils.Units
local kickTracker = addon.Core.KickTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local growAnchors = addon.Core.GrowAnchors
local kickSlot = addon.Core.KickSlot
local slotDistribution = addon.Utils.SlotDistribution
local testSpellData = addon.Core.TestSpells
local GetTime = GetTime

addon.Modules.Nameplates = addon.Modules.Nameplates or {}

---@class NameplatesDisplay
local M = {}
addon.Modules.Nameplates.Display = M

-- Each bar gets its own AuraContainer per nameplate token (reparented to the plate and retargeted
-- with SetUnit as plates come and go) with one group per category; the bar's IconSlotContainer is
-- kept for the kick icon and test icons. Limits forced by aura data being unreadable: no dynamic
-- slot split between categories (each enabled category gets the bar's full MaxIcons budget), and
-- colouring is per category rather than per spell, since the engine tints a whole group.

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

-- Fallback category tints, for a profile saved before the colours were configurable.
local DEFAULT_IMPORTANT_COLOR = { R = 1, G = 0.2, B = 0.2 }
local DEFAULT_DEFENSIVE_COLOR = { R = 0.2, G = 1, B = 0.2 }
-- The configured tints, refilled rather than reallocated. Both shapes are needed: the aura groups
-- read [1..3], the IconSlotContainer test icons read r/g/b.
local importantColor = { 1, 0.2, 0.2, r = 1, g = 0.2, b = 0.2, a = 1 }
local defensiveColor = { 0.2, 1, 0.2, r = 0.2, g = 1, b = 0.2, a = 1 }
-- Group key -> tint, handed to the display at creation and on every re-acquisition. Rewritten per
-- bar, since colouring by category is a per-bar toggle.
local barGroupColors = {}
-- The groups a category tint applies to. CC and disarm are absent on purpose: both are debuffs,
-- and the game's dispel palette already has a colour for them.
local COLORED_GROUP_KEYS = {
	auraFilters.GroupKey.BigDefensive,
	auraFilters.GroupKey.ExternalDefensive,
	auraFilters.GroupKey.Important,
}

-- Per-category test data driving ShowBarTestIcons: the bar option that shows the category, its
-- spell list and precomputed length, and the glow colour (per spell for CC, the configured
-- category tint otherwise).
local TEST_BAR_CATEGORIES = {
	{ Show = "ShowCC", Ids = TEST_CC_NAMEPLATE_SPELL_IDS, Count = TEST_CC_COUNT, Colors = TEST_CC_DISPEL_COLORS },
	{ Show = "ShowDefensives", Ids = TEST_DEFENSIVE_NAMEPLATE_SPELL_IDS, Count = TEST_DEFENSIVE_COUNT, Color = defensiveColor },
	{ Show = "ShowImportant", Ids = TEST_IMPORTANT_NAMEPLATE_SPELL_IDS, Count = TEST_IMPORTANT_COUNT, Color = importantColor },
}
-- Reused per-call slot budgets, parallel to TEST_BAR_CATEGORIES.
local testBudgetScratch = {}

-- Reusable scratch table for SetSlot calls.
-- This avoids creating a new table on every aura update for every nameplate slot,
-- which significantly reduces garbage collection pressure.
local layerScratch = {}

local NAMEPLATE_BAR1_KEY = addonName .. "_Bar1Container"
local NAMEPLATE_BAR2_KEY = addonName .. "_Bar2Container"

-- The two generic nameplate bars. Each bar independently shows CC, defensives, and/or important
-- buffs based on its ShowCC / ShowDefensives / ShowImportant options, and both bars can display
-- at the same time.
local BARS = {
	{ Key = "Bar1", ContainerKey = NAMEPLATE_BAR1_KEY, DataField = "Bar1Container", DisplayField = "Bar1Display" },
	{ Key = "Bar2", ContainerKey = NAMEPLATE_BAR2_KEY, DataField = "Bar2Container", DisplayField = "Bar2Display" },
}

-- One AuraContainer per (nameplate token, bar), built with its bar's full configuration and kept
-- for the session.
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

---Positions a bar's aura display, chaining after the bar's kick container while a kick icon is
---showing.
---
---Every write is compared first. None of them is expensive alone, but this runs for both bars on
---every plate add and again on every kick event, and the answer almost never moves - the plate is
---the same, the options are the same, and re-anchoring invalidates the layout of every button
---under the display for nothing. The remembered state is cleared when the display is parked, since
---parking clears the points it describes.
local function AnchorBarDisplay(display, container, nameplate, barOptions, kickActive)
	local anchorFrame = GetNameplateAnchorFrame(nameplate)
	local frame = display.Frame
	local level = anchorFrame:GetFrameLevel() + 10
	local ignoreScale = not nmModule.ScaleWithNameplate

	if display.NameplateLevel ~= level then
		display.NameplateLevel = level
		frame:SetFrameLevel(level)
	end

	if display.NameplateIgnoreScale ~= ignoreScale then
		display.NameplateIgnoreScale = ignoreScale
		frame:SetIgnoreParentScale(ignoreScale)
	end

	local grow = barOptions.Grow or "CENTER"
	local spacing = barOptions.Icons.Spacing or 2
	local offsetX = barOptions.Offset.X or 0
	local offsetY = barOptions.Offset.Y or 0

	if display.NameplateAnchorFrame == anchorFrame
		and display.NameplateGrow == grow
		and display.NameplateSpacing == spacing
		and display.NameplateOffsetX == offsetX
		and display.NameplateOffsetY == offsetY
		and display.NameplateKickActive == kickActive then
		return
	end

	display.NameplateAnchorFrame = anchorFrame
	display.NameplateGrow = grow
	display.NameplateSpacing = spacing
	display.NameplateOffsetX = offsetX
	display.NameplateOffsetY = offsetY
	display.NameplateKickActive = kickActive

	display:AnchorAfterKick(container.Frame, anchorFrame, grow, spacing, offsetX, offsetY, kickActive)
end

---Builds one pooled bar display with the standard categories (partitioned by
---filter negation, see Core/AuraFilters). Budgets/unit/style are applied per bar on acquisition;
---the size is fixed here because the buttons take it at creation and can't be resized in an arena.
---@param size number
---@param spacing number
---@param style AuraDisplayStyle applied at creation; it cannot be changed while auras are secret
---@param colors table<string, number[]> Category tints, for the same reason as the style.
local function CreateBarDisplay(size, spacing, style, colors)
	return auraContainerDisplay:New(
		UIParent,
		"none",
		-- No spell-ID maps: a plate only exists for a unit the client is drawing, so the
		-- out-of-range filter bug the maps work around cannot reach one.
		auraFilters:BuildCategoryGroups(DEFAULT_BAR_ICONS, true, colors),
		size,
		spacing,
		"Nameplates",
		-- Skinnable because the buttons are built here, while the display is still parked on
		-- UIParent. Once it moves onto a plate its size reads as secret and the skin can no
		-- longer be re-fitted, which is why the size is fixed at creation in the first place.
		{ Style = style, MasqueGroup = "Nameplates" }
	)
end

---Parks a pooled bar display.
local function ResetBarDisplay(display)
	display:SetEnabled(false)
	display:Hide()
	display.Frame:ClearAllPoints()
	display.Frame:SetParent(UIParent)

	-- What AnchorBarDisplay remembered describes points and a parent this display no longer has,
	-- so it must not be believed when the display is picked up again.
	display.NameplateAnchorFrame = nil
	display.NameplateLevel = nil
	display.NameplateIgnoreScale = nil
end

---@return number the icon size a bar's displays must be built at
local function BarIconSize(barOptions)
	return tonumber(barOptions.Icons.Size) or DEFAULT_BAR_SIZE
end

---Refills the category tints from the module options. Kept in the two shared tables the test
---icons already point at, so a colour change reaches them without rebuilding the category list.
local function RefreshCategoryColors()
	moduleUtil:FillColor(importantColor, nmModule and nmModule.ImportantColor, DEFAULT_IMPORTANT_COLOR)
	moduleUtil:FillColor(defensiveColor, nmModule and nmModule.DefensiveColor, DEFAULT_DEFENSIVE_COLOR)
end

---The tints a bar's aura groups take, keyed by group key. CC is never in there: it takes the
---game's dispel type colours, which is what the toggle meant before there was anything to pick.
---@return table<string, number[]> Shared, rewritten per call.
local function BarCategoryColors(barOptions)
	RefreshCategoryColors()

	local colored = barOptions.Icons.ColorByCategory == true

	barGroupColors[auraFilters.GroupKey.Important] = colored and importantColor or nil
	barGroupColors[auraFilters.GroupKey.BigDefensive] = colored and defensiveColor or nil
	barGroupColors[auraFilters.GroupKey.ExternalDefensive] = colored and defensiveColor or nil

	return barGroupColors
end

---Fills the shared style scratch from a bar's options.
---@return AuraDisplayStyle
local function BarStyle(barOptions)
	local style = auraContainerDisplay:BuildStandardStyle(barOptions.Icons)
	-- Nameplates stores the toggle as ColorByCategory, which the standard reader doesn't know. It
	-- drives both halves of the colouring: dispel type for CC, the configured tints for the
	-- categories the game has no dispel colour for (see BarCategoryColors).
	style.ColorByDispelType = barOptions.Icons.ColorByCategory
	-- The bars' untinted groups only hold CC and disarm, and most of that is physical: without
	-- this a stun gets the tinted glow but no ring, which reads as the border being broken.
	style.BorderWithoutDispelType = true
	style.ShowTooltips = barOptions.ShowTooltips ~= false
	return style
end

---Acquires (or reuses) and reconfigures a bar's aura display for a tracked plate.
---@param data NameplateData
local function EnsureBarDisplay(data, bar, barOptions)
	local token = data.UnitToken
	local size = BarIconSize(barOptions)
	local spacing = barOptions.Icons.Spacing or DEFAULT_BAR_SPACING
	local maxIcons = barOptions.Icons.MaxIcons or 5
	local style = BarStyle(barOptions)
	local colors = BarCategoryColors(barOptions)
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
		entry = { Display = CreateBarDisplay(size, spacing, style, colors), Signature = signature }
		byBar[bar.Key] = entry
	elseif entry.Signature ~= signature then
		-- One restyle pass for all three values; the individual setters would each walk every
		-- button. Records the new signature even when the restyle has to defer, because the
		-- display now WANTS this configuration and the retry will finish applying it.
		entry.Display:ApplyConfig(size, spacing, style)
		entry.Signature = signature
	end

	local display = entry.Display

	-- Outside the signature: the tints are not baked into a button, and a display legitimately
	-- swaps between the friendly and enemy configurations for the same token. This is a handful of
	-- comparisons when nothing moved.
	display:SetGroupGlowColors(COLORED_GROUP_KEYS, colors)

	-- Park whatever this bar was showing if it isn't the display we're about to use.
	local previous = data[bar.DisplayField]

	if previous and previous ~= display then
		ResetBarDisplay(previous)
	end

	data[bar.DisplayField] = display

	-- Only when it actually moves. Re-parenting invalidates the layout of every button under the
	-- display, and this runs for each tracked plate on every options refresh - a slider drag was
	-- paying for it once per step per plate with nothing to show for it.
	if display.Frame:GetParent() ~= data.Nameplate then
		display.Frame:SetParent(data.Nameplate)
	end

	display:SetUnit(token)
	auraFilters:ApplyCategoryBudgets(
		display,
		maxIcons,
		barOptions.ShowCC,
		barOptions.ShowDefensives,
		barOptions.ShowImportant,
		-- Disarm rides the CC toggle, but only where the engine actually applies its spell-ID
		-- filter: on an assistable unit the identity gate skips the map and the group would
		-- show every debuff on the plate.
		barOptions.ShowCC and not units:CanAssist(token)
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

---Acquires/reconfigures displays for every enabled bar on a tracked plate and releases displays
---of bars that are now disabled.
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

	-- The category entries point at the shared tint tables, so this is what puts the picked
	-- colours on the test icons.
	RefreshCategoryColors()

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
				layerScratch.Border = true
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

---Builds (or refreshes) everything a tracked plate draws with: the per-bar kick containers, the
---aura displays and the kick icon.
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

	EnsureBarDisplays(data, unitOptions)

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

	-- Park this plate's displays; the per-token cache keeps them for its return.
	self:Release(unitToken)

	nameplateAnchors[unitToken] = nil
end

---Releases a tracked plate's pooled displays (and its kick timer). Used when the
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

---Renders the kick icon into each ShowCC bar's kick container (slot 1) and re-anchors
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
				-- The aura buttons beside this icon draw border and glow together when coloured,
				-- so the kick icon does too or it reads as the odd one out in the row.
				layerScratch.Border = true
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

						-- Re-apply option changes to the bar's aura display too.
						local display = EnsureBarDisplay(data, bar, barOptions)
						local kickActive = barOptions.ShowCC and kickTracker:GetKick(data.UnitToken) ~= nil
						AnchorBarDisplay(display, container, data.Nameplate, barOptions, kickActive)
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
---@field Bar1Display AuraContainerDisplay?
---@field Bar2Display AuraContainerDisplay?
---@field KickTimer table? Timer that clears the kick icon on expiry.
---@field UnitToken string
