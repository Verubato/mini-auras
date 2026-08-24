---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local units = addon.Utils.UnitUtil
local kickTracker = addon.Core.KickTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local growAnchors = addon.Core.GrowAnchors
local kickSlot = addon.Core.KickSlot
local slotDistribution = addon.Utils.SlotDistribution
local testSpellData = addon.Core.TestSpells
local sweep = addon.Core.Sweep
local GetTime = GetTime

addon.Modules.Nameplates = addon.Modules.Nameplates or {}

---@class NameplatesDisplay
local M = {}
addon.Modules.Nameplates.Display = M

-- One AuraContainer per plate and bar, with a group per category, and an IconSlotContainer
-- alongside it for the kick icon and the test icons.

-- How a bar tints its icons, stored on its Icons.ColorMode. Dispel puts CC and disarm on the
-- game's debuff type palette and Custom puts them on the module's CrowdControlColor. That is the
-- only way the two differ, since defensives and importants take their own tints under both.
local COLOR_MODE_NONE = "NONE"
local COLOR_MODE_DISPEL = "DISPEL"
local COLOR_MODE_CUSTOM = "CUSTOM"

-- For the options page and the migration that fills the field.
M.ColorMode = { None = COLOR_MODE_NONE, Dispel = COLOR_MODE_DISPEL, Custom = COLOR_MODE_CUSTOM }

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
-- These lists never change at runtime, so recalculating #list on every test-mode call is waste.
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
local DEFAULT_CC_COLOR = { R = 0.64, G = 0.21, B = 0.93 }
-- The configured tints, refilled rather than reallocated. Both shapes are needed: the aura groups
-- read [1..3], the IconSlotContainer test icons read r/g/b.
local importantColor = { 1, 0.2, 0.2, r = 1, g = 0.2, b = 0.2, a = 1 }
local defensiveColor = { 0.2, 1, 0.2, r = 0.2, g = 1, b = 0.2, a = 1 }
local ccColor = { 0.64, 0.21, 0.93, r = 0.64, g = 0.21, b = 0.93, a = 1 }
-- Group key -> tint, handed to the display at creation and on every re-acquisition. Rewritten per
-- bar, since colouring by category is a per-bar toggle.
local barGroupColors = {}
-- The groups a category tint can apply to. CC and disarm only take one when the dispel palette is
-- switched off, but they still have to be listed: a group going back to the palette is a nil in
-- the colour map, which SetGroupGlowColors can only see through this list.
local COLORED_GROUP_KEYS = {
	auraFilters.GroupKey.CrowdControl,
	auraFilters.GroupKey.Disarm,
	auraFilters.GroupKey.BigDefensive,
	auraFilters.GroupKey.ExternalDefensive,
	auraFilters.GroupKey.Important,
}

-- Per-category test data driving ShowBarTestIcons: the bar option that shows the category, its
-- spell list and precomputed length, and the glow colour. Colors is the per spell dispel palette,
-- used in place of Color while the dispel colours are on.
local TEST_BAR_CATEGORIES = {
	{ Show = "ShowCrowdControl", Ids = TEST_CC_NAMEPLATE_SPELL_IDS, Count = TEST_CC_COUNT, Colors = TEST_CC_DISPEL_COLORS, Color = ccColor },
	{ Show = "ShowDefensives", Ids = TEST_DEFENSIVE_NAMEPLATE_SPELL_IDS, Count = TEST_DEFENSIVE_COUNT, Color = defensiveColor },
	{ Show = "ShowImportant", Ids = TEST_IMPORTANT_NAMEPLATE_SPELL_IDS, Count = TEST_IMPORTANT_COUNT, Color = importantColor },
}
-- Reused per-call slot budgets, parallel to TEST_BAR_CATEGORIES.
local testBudgetScratch = {}

-- Reusable scratch for SetSlot calls, so an aura update doesn't build a table per nameplate slot.
local layerScratch = {}

local NAMEPLATE_BAR1_KEY = addonName .. "_Bar1Container"
local NAMEPLATE_BAR2_KEY = addonName .. "_Bar2Container"

-- The two generic nameplate bars. Each shows CC, defensives, or important buffs from its own
-- toggles, and both can display at the same time.
local BARS = {
	{
		Key = "Bar1",
		ContainerKey = NAMEPLATE_BAR1_KEY,
		DataField = "Bar1Container",
		DisplayField = "Bar1Display",
		CacheKey = { Enemy = "Bar1Enemy", Friendly = "Bar1Friendly" },
	},
	{
		Key = "Bar2",
		ContainerKey = NAMEPLATE_BAR2_KEY,
		DataField = "Bar2Container",
		DisplayField = "Bar2Display",
		CacheKey = { Enemy = "Bar2Enemy", Friendly = "Bar2Friendly" },
	},
}

-- One AuraContainer per (nameplate frame, bar, faction), bound to that plate the first time it
-- wants one and kept there for the session.
--
-- Keyed on the plate rather than the unit token because the client pairs the two arbitrarily, so
-- a token-keyed display would be re-parented onto a different plate on nearly every spawn, and
-- re-parenting invalidates the layout of every button under it. Plate frames come from the
-- client's own pool and are a small fixed set, so this stays bounded, which matters because WoW
-- frames can never be freed.
--
-- Not pooled generically. StyleButton bakes size, swipe, countdown, glow, and the dispel textures
-- into a button when the frame pool creates it, and only a restyle can change them, which is
-- blocked for as long as C_Secrets.ShouldAurasBeSecret is true. A generic pool hands out displays
-- built for some other bar's configuration, which then cannot be corrected. Exactly one display
-- per (plate, bar, faction), so a configuration change restyles it in place.
--
-- Faction is part of the key because the same plate alternates between the Friendly and Enemy
-- configurations as plates recycle, and when the two differ that alternation is a restyle. Inside
-- an arena it would show a plate at the other faction's icon size for the rest of the match, so
-- swapping between two bound displays makes the flip a park-and-reacquire instead.
--
-- A restyle blocked while auras are secret is already handled: ApplyConfig stores the new values
-- and flags the display, and AuraContainerDisplay's retry settles the buttons when the restriction
-- lifts. The cost is that a change made inside an arena shows late.
---@type table<table, table<string, BarDisplayEntry>>
local barDisplays = {}
-- Displays built ahead of any plate wanting them, keyed by (bar, faction). A plate takes one on
-- first sight instead of building its own there and then; see Prewarm.
---@type table<string, BarDisplayEntry[]>
local freeDisplays = {}
-- How many displays exist per (bar, faction), bound and free together, so a repeated Prewarm tops
-- the set up instead of building a second one.
---@type table<string, number>
local builtCounts = {}
-- Background walker converting parked bar displays after a look change; see QueueParkedRestyles.
local parkedSweep = sweep:New()
-- Background walker filling the free lists, a display at a time.
local prewarmSweep = sweep:New()
-- The same walker for displays a plate is already holding. Urgent, because a plate on screen is
-- waiting on these while the lane above is only working ahead of anyone asking.
local demandSweep = sweep:New(true)
-- One reusable queue entry per (bar, faction), since the queue is the same pair repeated: the
-- walker re-reads the options through it at fire time, so there is nothing per-item to carry.
local prewarmItems = {}
-- The entry the walker is part way through building, held across its turns. One lane, one build
-- at a time, so a single field covers it.
---@type BarDisplayEntry?
local prewarmBuilding = nil
-- What each (bar, faction) look was resolved to, keyed by cache key; see BarLook.
local barLooks = {}
-- Bumped whenever the options reach this file, which is the only thing that can move a look.
local optionsGeneration = 0
-- Fallbacks for a bar with no configured geometry.
local DEFAULT_BAR_ICONS = 5
local DEFAULT_BAR_SIZE = 35
local DEFAULT_BAR_SPACING = 2
-- How many displays to prepare per bar and faction ahead of any plate wanting one, so no plate has
-- to build a container mid-fight. Well short of the 40 plates a full battleground can put up,
-- because every prepared display is frame creation the client can never take back and the count
-- multiplies per bar and faction. Anything past it builds on first sight.
--
-- On the module table rather than a local so the tests can lower it, where preparing forty per
-- refresh is slow against the mock.
M.PrewarmCount = 15
-- The ceiling on what an instance's own size can ask for. The client draws no more plates than
-- this however many players a side holds, and every prepared display is frames it can never free.
M.MaxPrewarmCount = 40
-- What an arena gets. Three enemies and their pets is the whole of it, so the rest of the set
-- would be displays nothing can ever ask for, and the client never takes a frame back.
M.ArenaPrewarmCount = 10
-- Both sides get prepared, since a plate's faction is not known until it spawns and a duel or a
-- mind control flips it afterwards. Only bars actually switched on are queued (see Prewarm).
local PREWARM_FACTIONS = { "Enemy", "Friendly" }

---@param container IconSlotContainer?
local function HideAndReset(container)
	if not container then
		return
	end
	container:ResetAllSlots()
	container.Frame:Hide()
end

---The effective anchor frame for a nameplate. For ThreatPlates it is TPFrame, or its GetAnchor
---result, so icons scale and move with the target-highlight scaling rather than the base frame.
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
	-- Optionally anchor to the health bar container, because addons that resize plates do it by
	-- shrinking HealthBarsContainer, which the base nameplate frame doesn't follow. Not
	-- HealthBarsContainer.healthBar, which shifts around inside the container with the anti-heal
	-- display.
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
	-- Grow LEFT mirrors the slots so slot 1, the highest priority, sits at the rightmost icon,
	-- nearest the nameplate. RIGHT and DOWN already place slot 1 nearest the anchor.
	container:SetRows(nil, "CENTER", barOptions.Grow == "LEFT")
end

---Positions a bar's aura display, chaining after the bar's kick container while a kick icon is
---showing.
---
---Every write is compared first, because this runs for both bars on every plate add and again on
---every kick event, and re-anchoring invalidates the layout of every button under the display. The
---remembered state is cleared when the display is parked, since parking clears the points it
---describes.
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

---Whether the disarm group is worth building for this side. Its only real filter is the spell-ID
---map, which the identity gate skips on a unit the player can assist, so a friendly bar can never
---show it.
---@param factionKey "Enemy"|"Friendly"
---@return boolean
local function DisarmPossible(barOptions, factionKey)
	return barOptions.ShowCrowdControl == true and factionKey == "Enemy"
end

---The categories a bar's displays are built with, from its toggles.
---@param factionKey "Enemy"|"Friendly"
---@return table<string, boolean>
local function BarCategorySet(barOptions, factionKey)
	return auraFilters:CategorySet(
		barOptions.ShowCrowdControl,
		barOptions.ShowDefensives,
		barOptions.ShowImportant,
		DisarmPossible(barOptions, factionKey)
	)
end

---Builds one pooled bar display with the standard categories, partitioned by filter negation in
---Core/AuraFilters. Budgets, unit, and style are applied per bar on acquisition. The size is fixed
---here because the buttons take it at creation and can't be resized in an arena.
---@param size number
---@param spacing number
---@param style AuraDisplayStyle applied at creation, since it cannot be changed while auras are secret
---@param colors table<string, number[]> Category tints, for the same reason as the style.
local function CreateBarDisplay(barOptions, factionKey, size, spacing, style, colors, defer)
	return auraContainerDisplay:New(
		UIParent,
		"none",
		-- No spell-ID maps: a plate only exists for a unit the client is drawing, so the
		-- out-of-range filter bug the maps work around cannot reach one.
		--
		-- Only the categories this bar can show: the engine allocates a batch of buttons per
		-- group whatever the budget, so a group for a switched-off category is that batch wasted.
		-- Switching one on rebuilds the bar's displays, which is what BarLook's signature carries.
		auraFilters:BuildCategoryGroups(DEFAULT_BAR_ICONS, true, colors, BarCategorySet(barOptions, factionKey)),
		size,
		spacing,
		"Nameplates",
		-- Skinnable because the buttons are built here, while the display is still parked on
		-- UIParent. Once it moves onto a plate its size reads as secret and the skin can no
		-- longer be re-fitted, which is why the size is fixed at creation in the first place.
		{ Style = style, MasqueGroup = "Nameplates", DeferGroups = defer }
	)
end

---Parks a pooled bar display, hidden and still on the plate it was drawing on. Re-parenting
---invalidates the layout of every button underneath, and a camera sweep through a crowd would pay
---for that twice per plate. Only a restyle is worth taking it off, which MoveOffPlate does there.
local function ResetBarDisplay(display)
	display:SetEnabled(false)
	display:Hide()
end

---Moves a display back to UIParent, where its geometry can be read: a restyle cannot re-fit
---buttons whose size is secret, which it is anywhere inside a plate.
local function MoveOffPlate(display)
	local frame = display.Frame

	if frame:GetParent() == UIParent then
		return
	end

	frame:ClearAllPoints()
	frame:SetParent(UIParent)

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
	moduleUtil:FillColor(ccColor, nmModule and nmModule.CrowdControlColor, DEFAULT_CC_COLOR)
end

---The tints a bar's aura groups take, keyed by group key. The engine tints a whole group, so the
---colouring is per category rather than per spell. CC and disarm stay out under Dispel, since a
---tinted group opts out of the game's palette and a colour there would replace it.
---@return table<string, number[]> Shared, rewritten per call.
local function BarCategoryColors(barOptions)
	RefreshCategoryColors()

	local mode = M:ResolveColorMode(barOptions.Icons)
	local colored = mode ~= COLOR_MODE_NONE
	local flatCc = mode == COLOR_MODE_CUSTOM and ccColor or nil

	barGroupColors[auraFilters.GroupKey.CrowdControl] = flatCc
	barGroupColors[auraFilters.GroupKey.Disarm] = flatCc
	barGroupColors[auraFilters.GroupKey.Important] = colored and importantColor or nil
	barGroupColors[auraFilters.GroupKey.BigDefensive] = colored and defensiveColor or nil
	barGroupColors[auraFilters.GroupKey.ExternalDefensive] = colored and defensiveColor or nil

	return barGroupColors
end

---Fills the shared style scratch from a bar's options.
---@return AuraDisplayStyle
local function BarStyle(barOptions)
	local style = auraContainerDisplay:BuildStandardStyle(barOptions.Icons)
	-- Nameplates keep the colour choice in ColorMode, which the standard reader doesn't know. Any
	-- mode but None wants the paint code's coloured path, whether the tints come from the game's
	-- palette or from BarCategoryColors.
	style.ColorByDispelType = M:ResolveColorMode(barOptions.Icons) ~= COLOR_MODE_NONE
	-- The bars' untinted groups only hold CC and disarm, and most of that is physical: without
	-- this a stun gets the tinted glow but no ring, which reads as the border being broken.
	style.BorderWithoutDispelType = true
	style.ShowTooltips = barOptions.ShowTooltips ~= false
	return style
end

---An own copy of the shared style scratch, which the next caller refills. Colours are copied out
---too, since those come from scratch tables of their own.
---@param style AuraDisplayStyle
---@return AuraDisplayStyle
local function CopyStyle(style)
	local copy = {}

	for key, value in pairs(style) do
		if type(value) == "table" then
			copy[key] = { value[1], value[2], value[3], value[4] }
		else
			copy[key] = value
		end
	end

	return copy
end

---The look one bar and faction wears: its size, spacing, style, and the generation those add up
---to. Resolved when the options move rather than per plate, since none of it can change between
---two plates.
---@param factionKey "Enemy"|"Friendly"
---@return table
local function BarLook(bar, barOptions, factionKey)
	local cacheKey = bar.CacheKey[factionKey]
	local look = barLooks[cacheKey]

	if look and look.Generation == optionsGeneration then
		return look
	end

	local size = BarIconSize(barOptions)
	local spacing = barOptions.Icons.Spacing or DEFAULT_BAR_SPACING
	local style = CopyStyle(BarStyle(barOptions))

	look = {
		Generation = optionsGeneration,
		Size = size,
		Spacing = spacing,
		Style = style,
		Signature = auraContainerDisplay:GetStyleGeneration(cacheKey, style, size, spacing),
		-- Kept apart from the signature because the two are answered differently: a look a
		-- display no longer matches is restyled, while a category it was not built with can only
		-- be had by building another one.
		Categories = auraFilters:CategoryGeneration(
			barOptions.ShowCrowdControl,
			barOptions.ShowDefensives,
			barOptions.ShowImportant,
			DisarmPossible(barOptions, factionKey)
		),
	}
	barLooks[cacheKey] = look

	return look
end

---Brings one entry onto the current look. The display has to leave its plate to do it, since a
---restyle cannot re-fit buttons whose size is secret, which it is anywhere inside a plate.
---
---Records the new signature even when the restyle has to defer, because the display is already
---asking for this configuration and the retry will finish applying it.
---@param entry BarDisplayEntry
local function RestyleEntry(entry, size, spacing, style, signature)
	MoveOffPlate(entry.Display)
	entry.Display:ApplyConfig(size, spacing, style)
	entry.Signature = signature

	if entry.Plate then
		entry.Display.Frame:SetParent(entry.Plate)
	end
end

---A prepared display for this bar and faction, if one is waiting that already wears the look being
---asked for. A stale one is left alone rather than handed over and restyled, because the restyle
---is blocked while auras are secret, which would leave a plate wearing the old size for the match.
---The sweep converts the stale ones in the background so later plates find a match.
---@return BarDisplayEntry?
local function TakeFreeDisplay(cacheKey, signature, categories, size, spacing, style)
	local free = freeDisplays[cacheKey]

	if not free then
		return
	end

	for i = #free, 1, -1 do
		if free[i].Signature == signature and free[i].Categories == categories then
			return table.remove(free, i)
		end
	end

	-- A look that changed and changed back reads as a new generation, so an entry parked under the
	-- old one stops matching by number even though its buttons wear exactly this. Ask the display
	-- what it carries before building a frame the client can never free. Second, because the number
	-- is one compare and this walks the style.
	for i = #free, 1, -1 do
		local entry = free[i]

		if entry.Categories == categories and entry.Display:CarriesConfig(size, spacing, style) then
			entry.Signature = signature
			return table.remove(free, i)
		end
	end
end

---One display's next group, from the walker.
---@param display AuraContainerDisplay
---@return SweepVerdict?
local function DeclareNextGroup(display)
	if display:AddNextGroup() then
		return sweep.Verdict.Unfinished
	end
end

---The display one (plate, bar, faction) owns, bound on first ask and restyled when that faction's
---own configuration moves. The bind is the only time it is ever re-parented.
---@param nameplate table
---@param factionKey "Enemy"|"Friendly" which side of the options the bar came from
---@return AuraContainerDisplay
local function GetOrCreateBarDisplay(nameplate, bar, barOptions, factionKey)
	local look = BarLook(bar, barOptions, factionKey)
	local size, spacing, style = look.Size, look.Spacing, look.Style
	local cacheKey = bar.CacheKey[factionKey]
	local signature = look.Signature
	local categories = look.Categories

	local byBar = barDisplays[nameplate]

	if not byBar then
		byBar = {}
		barDisplays[nameplate] = byBar
	end

	local entry = byBar[cacheKey]

	-- A category switched on since this display was built is one it has no group for, and groups
	-- cannot be added to a container. The old one is parked, its frames gone for good, and a display
	-- carrying the new set takes over.
	if entry and entry.Categories ~= categories then
		ResetBarDisplay(entry.Display)
		builtCounts[cacheKey] = (builtCounts[cacheKey] or 1) - 1
		byBar[cacheKey] = nil
		entry = nil
	end

	if not entry then
		entry = TakeFreeDisplay(cacheKey, signature, categories, size, spacing, style)

		if not entry then
			-- Built without its groups like a prepared one, because a crowd of plates arriving at
			-- once is exactly when the free list runs dry: a zone-in puts every plate up in the
			-- same frame, and the walker cannot have run yet because nothing ticks behind a
			-- loading screen. The icons of a category appear as its group lands.
			entry = {
				Display = CreateBarDisplay(barOptions, factionKey, size, spacing, style,
					BarCategoryColors(barOptions), true),
				Signature = signature,
				Categories = categories,
			}
			builtCounts[cacheKey] = (builtCounts[cacheKey] or 0) + 1
		end

		byBar[cacheKey] = entry
		entry.Plate = nameplate

		-- The one re-parent this display will ever see. Built on UIParent so its buttons could be
		-- skinned while their size was still readable, and it lives on this plate from here.
		entry.Display.Frame:SetParent(nameplate)
	elseif entry.Signature ~= signature then
		RestyleEntry(entry, size, spacing, style, signature)
	end

	-- Whatever this display still owes goes on the urgent lane, ahead of the spares, because a plate
	-- is holding it now. Asked every time rather than only on the first bind, since a teardown stops
	-- the lane and an entry the walker had not finished comes back here still owing its groups.
	if entry.Display:HasPendingGroups() then
		demandSweep:Append(entry.Display, DeclareNextGroup)
	end

	return entry.Display
end

---How many displays each switched-on (bar, faction) is prepared for, so the set matches the fight
---instead of a guess.
---@return number
local function PrewarmTarget()
	return moduleUtil:PrewarmTarget(M.ArenaPrewarmCount, M.MaxPrewarmCount, M.PrewarmCount)
end

---Builds one (bar, faction) display ahead of the plate that will want it, and parks it on the free
---list. Nothing already bound to a plate is touched: one of those may be drawing right now.
---The container comes back with none of its groups declared; the walker adds them one at a time.
---@param factionKey "Enemy"|"Friendly"
---@return BarDisplayEntry
local function PrewarmOneBarDisplay(bar, barOptions, factionKey)
	local cacheKey = bar.CacheKey[factionKey]
	local look = BarLook(bar, barOptions, factionKey)

	local entry = {
		Display = CreateBarDisplay(barOptions, factionKey, look.Size, look.Spacing, look.Style,
			BarCategoryColors(barOptions), true),
		Signature = look.Signature,
		Categories = look.Categories,
	}
	ResetBarDisplay(entry.Display)

	local free = freeDisplays[cacheKey]

	if not free then
		free = {}
		freeDisplays[cacheKey] = free
	end

	free[#free + 1] = entry
	builtCounts[cacheKey] = (builtCounts[cacheKey] or 0) + 1

	return entry
end

---One queued display, spread over several turns of the walker: the container on the first, then a
---group on each turn after. The engine allocates a batch of buttons the moment a group is
---declared, so a group is the smallest piece a build can be cut into.
---
---Everything is re-read at fire time: the walk runs over seconds, in which a bar can be switched
---off, the look can move, and plates can build displays of their own that count towards the same
---target.
---@param item table {Bar, Faction}
---@return SweepVerdict?
local function PrewarmQueuedBarDisplay(item)
	if prewarmBuilding then
		if prewarmBuilding.Display:AddNextGroup() then
			return sweep.Verdict.Unfinished
		end

		prewarmBuilding = nil

		return
	end

	local unitOptions = nmModule and nmModule[item.Faction]
	local barOptions = unitOptions and unitOptions[item.Bar.Key]

	if not barOptions or not barOptions.Enabled then
		return
	end

	if (builtCounts[item.Bar.CacheKey[item.Faction]] or 0) >= PrewarmTarget() then
		return
	end

	prewarmBuilding = PrewarmOneBarDisplay(item.Bar, barOptions, item.Faction)

	return sweep.Verdict.Unfinished
end

---One (bar, faction) display brought onto the current look, from the background sweep. Everything
---is re-resolved at fire time: the sweep runs over seconds, and options, plates and the shared
---style scratch all move underneath it.
---@param item table {Entry, Bar, FactionKey}
---@return boolean? keepGoing
local function RestyleParkedEntry(item)
	-- A restricted restyle cannot reach the buttons. Abandon and let the on-demand path cope.
	if wowEx:IsAuraStylingRestricted() then
		return false
	end

	local unitOptions = nmModule and nmModule[item.FactionKey]
	local barOptions = unitOptions and unitOptions[item.Bar.Key]

	if not barOptions or not barOptions.Enabled then
		return
	end

	local look = BarLook(item.Bar, barOptions, item.FactionKey)
	local signature = look.Signature

	-- An entry a plate has taken since the queue was built was restyled by its own ensure path,
	-- so this lands as a no-op diff. The tints ride along because they are outside the signature,
	-- and a display reused while auras are secret needs them already on the buttons.
	if item.Entry.Signature ~= signature then
		RestyleEntry(item.Entry, look.Size, look.Spacing, look.Style, signature)
	end

	item.Entry.Display:SetGroupGlowColors(COLORED_GROUP_KEYS, BarCategoryColors(barOptions))
end

---Adds every entry of one bar's cache still wearing an old look to the queue, building it on
---first need.
---@param queue table[]?
---@param bar table
---@param factionKey "Enemy"|"Friendly"
---@param barOptions table
---@return table[]? queue
local function QueueStaleForBar(queue, bar, factionKey, barOptions)
	local cacheKey = bar.CacheKey[factionKey]
	local look = BarLook(bar, barOptions, factionKey)
	local signature = look.Signature
	local categories = look.Categories

	for _, byBar in pairs(barDisplays) do
		local entry = byBar[cacheKey]

		-- Only a look: a group set that no longer matches is settled by the plate's own ensure
		-- pass, which swaps the display rather than restyling it.
		if entry and entry.Signature ~= signature and entry.Categories == categories then
			queue = queue or {}
			queue[#queue + 1] = { Entry = entry, Bar = bar, FactionKey = factionKey }
		end
	end

	-- Parked entries built for another set of categories can never serve this bar again: a
	-- restyle reaches buttons, not groups. Dropped here so the prewarm tops the set back up with
	-- the shape the options now describe.
	local free = freeDisplays[cacheKey]

	if free then
		for index = #free, 1, -1 do
			local entry = free[index]

			if entry.Categories ~= categories then
				builtCounts[cacheKey] = (builtCounts[cacheKey] or 1) - 1
				table.remove(free, index)
			elseif entry.Signature ~= signature then
				-- The rest ride the sweep, so a plate spawning after a settings change finds a
				-- display already wearing the new look rather than having to build one.
				queue = queue or {}
				queue[#queue + 1] = { Entry = entry, Bar = bar, FactionKey = factionKey }
			end
		end
	end

	return queue
end

---Queues every parked bar display whose baked look no longer matches the options, for the
---background sweep to convert a couple at a time. Without this a plate spawning once auras are
---secret cannot be restyled, so it wears the old look for the rest of the encounter.
---
---The queue is rebuilt from the entries' own signatures on every pass, with no done-marker, so a
---run abandoned under restriction or replaced by a later change self-heals on the next refresh.
local function QueueParkedRestyles()
	if not nmModule then
		return
	end

	local queue

	for _, factionKey in ipairs(PREWARM_FACTIONS) do
		local unitOptions = nmModule[factionKey]

		for _, bar in ipairs(BARS) do
			local barOptions = unitOptions and unitOptions[bar.Key]

			if barOptions and barOptions.Enabled then
				queue = QueueStaleForBar(queue, bar, factionKey, barOptions)
			end
		end
	end

	if queue then
		parkedSweep:Run(queue, RestyleParkedEntry)
	end
end

---Acquires (or reuses) and reconfigures a bar's aura display for a tracked plate.
---@param data NameplateData
---@param factionKey "Enemy"|"Friendly" which side of the options the bar came from
local function EnsureBarDisplay(data, bar, barOptions, factionKey)
	local token = data.UnitToken
	local maxIcons = barOptions.Icons.MaxIcons or 5
	local colors = BarCategoryColors(barOptions)
	local display = GetOrCreateBarDisplay(data.Nameplate, bar, barOptions, factionKey)

	-- Outside the signature: the tints are not baked into a button, and a display legitimately
	-- swaps between the friendly and enemy configurations for the same plate. This is a handful of
	-- comparisons when nothing moved.
	display:SetGroupGlowColors(COLORED_GROUP_KEYS, colors)

	local previous = data[bar.DisplayField]

	if previous and previous ~= display then
		ResetBarDisplay(previous)
	end

	data[bar.DisplayField] = display
	display:SetUnit(token)
	-- Every switched-on category gets the bar's whole budget. Aura data cannot be read, so there is
	-- nothing to split the slots between them by.
	auraFilters:ApplyCategoryBudgets(
		display,
		maxIcons,
		barOptions.ShowCrowdControl,
		barOptions.ShowDefensives,
		barOptions.ShowImportant,
		-- Disarm rides the CC toggle, but only where the engine actually applies its spell-ID
		-- filter: on an assistable unit the identity gate skips the map and the group would
		-- show every debuff on the plate.
		barOptions.ShowCrowdControl and not units:CanAssist(token)
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
	-- GetUnitOptions hands out one of the two module tables, so identity answers which side
	-- these options are.
	local factionKey = unitOptions == nmModule.Friendly and "Friendly" or "Enemy"
	for _, bar in ipairs(BARS) do
		local barOptions = unitOptions[bar.Key]
		local container = data[bar.DataField]
		if barOptions and barOptions.Enabled and container then
			local display = EnsureBarDisplay(data, bar, barOptions, factionKey)
			local kickActive = barOptions.ShowCrowdControl and kickTracker:GetKick(data.UnitToken) ~= nil
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
	local mode = M:ResolveColorMode(barOptions.Icons)
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
				local perSpell = mode == COLOR_MODE_DISPEL and category.Colors and category.Colors[spellId]
				layerScratch.Color = mode ~= COLOR_MODE_NONE and (perSpell or category.Color) or nil
				layerScratch.Border = true
				layerScratch.SpellId = showTooltips and spellId or nil
				container:SetSlot(slot, layerScratch)
			end
		end
	end

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

---A bar's colour mode, with anything unrecognised read as the shipped default. Public so the
---options page reads the same answer the bars do.
---@param iconOptions table A bar's Icons options table.
---@return string one of M.ColorMode
function M:ResolveColorMode(iconOptions)
	local mode = iconOptions.ColorMode

	return (mode == COLOR_MODE_NONE or mode == COLOR_MODE_CUSTOM) and mode or COLOR_MODE_DISPEL
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
	local bar1Container, bar2Container =
		EnsureContainersForNameplate(nameplate, unitToken, unitOptions)

	if not bar1Container and not bar2Container and not trackAnyway then
		return nil
	end

	-- Displays live in the per-token cache rather than on this table, so a rebuild for an
	-- already-tracked token picks them back up on the next Ensure.
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

	-- The displays stay bound to the plate for whatever it shows next.
	self:Release(unitToken)

	nameplateAnchors[unitToken] = nil
end

---Releases a tracked plate's pooled displays and its kick timer. Used when the plate goes away and
---when tracking stops for other reasons, so displays never linger active outside the pool.
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
	-- Parked, not discarded: they stay bound to their plate for the next unit it shows, since a
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

---Fills the free list for every (bar, faction) the current options actually switch on, so a plate
---spawning mid-fight takes a ready display instead of paying to build one there and then.
---
---Nothing is built here. The whole set is hundreds of displays, and a loading screen does not pay
---for it, because the client draws nothing while the screen is up and the cost would land on the
---frame it drops. The walker builds them one per tick instead. Cheap to repeat, since it counts
---what exists first.
function M:Prewarm()
	local target = PrewarmTarget()
	local queue = {}

	for _, faction in ipairs(PREWARM_FACTIONS) do
		local unitOptions = nmModule and nmModule[faction]

		for _, bar in ipairs(BARS) do
			local barOptions = unitOptions and unitOptions[bar.Key]

			if barOptions and barOptions.Enabled then
				local cacheKey = bar.CacheKey[faction]
				local item = prewarmItems[cacheKey]

				if not item then
					item = { Bar = bar, Faction = faction }
					prewarmItems[cacheKey] = item
				end

				-- Bound displays count towards the target: they are already doing the job the
				-- prepared ones are held for, and only the plates yet to appear need covering.
				for _ = (builtCounts[cacheKey] or 0) + 1, target do
					queue[#queue + 1] = item
				end
			end
		end
	end

	prewarmBuilding = nil
	prewarmSweep:Run(queue, PrewarmQueuedBarDisplay)
end

---Renders the kick icon into each ShowCrowdControl bar's kick container (slot 1) and re-anchors
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
			if barOptions.ShowCrowdControl and kickEntry then
				layerScratch.Texture = kickEntry.Texture
				layerScratch.DurationObject = kickEntry.DurationObject
				layerScratch.Alpha = true
				layerScratch.Glow = barOptions.Icons.Glow
				layerScratch.ReverseCooldown = barOptions.Icons.ReverseCooldown
				layerScratch.ShowMilliseconds = barOptions.Icons.ShowMilliseconds
				layerScratch.FontScale = db.FontScale
				layerScratch.Color = self:ResolveColorMode(barOptions.Icons) ~= COLOR_MODE_NONE
					and kickEntry.Color or nil
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
				AnchorBarDisplay(display, container, data.Nameplate, barOptions, barOptions.ShowCrowdControl and kickEntry ~= nil)
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
	-- The one path options arrive on, so it is where the looks are marked for re-resolving.
	optionsGeneration = optionsGeneration + 1

	local ignoreParentScale = not nmModule.ScaleWithNameplate
	for _, data in pairs(nameplateAnchors) do
		if data.Nameplate and data.UnitToken then
			local unitOptions = self:GetUnitOptions(data.UnitToken)
			local factionKey = unitOptions == nmModule.Friendly and "Friendly" or "Enemy"

			-- Both bars are independent, so reposition each that exists.
			for _, bar in ipairs(BARS) do
				local container = data[bar.DataField]
				local barOptions = unitOptions[bar.Key]
				if container then
					if barOptions and barOptions.Enabled then
						-- The container carries the test icons, so it is laid out either way.
						ApplyContainerLayout(container, data.Nameplate, barOptions)

						-- The aura display is hidden while test mode draws, so re-fitting it now is work
						-- nobody can see. Its look is left stale and the refresh ending test mode settles it.
						if not testModeActive then
							local display = EnsureBarDisplay(data, bar, barOptions, factionKey)
							local kickActive = barOptions.ShowCrowdControl and kickTracker:GetKick(data.UnitToken) ~= nil

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

	-- After the tracked plates: their ensure path has just updated their entries' signatures,
	-- so the queue that remains is exactly the parked cache, and none of the walker's budget is
	-- spent on entries the loop above already restyled. Skipped in test mode, where the loop above
	-- restyled nothing and the whole cache would be queued for a look nobody is looking at.
	if not testModeActive then
		QueueParkedRestyles()
	end
end

function M:Teardown()
	-- A disabled module has no business converting its cache or filling it further. The next enable
	-- re-queues whatever still diffs, and the next loading screen tops the set back up.
	parkedSweep:Stop()
	prewarmSweep:Stop()
	demandSweep:Stop()

	-- Whatever the walk was part way through keeps the groups it has; a plate taking it finishes
	-- the rest. Only the walker's own place in it is dropped.
	prewarmBuilding = nil

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
	-- Cache once so all hot-path functions avoid repeatedly traversing db -> Modules -> Nameplates
	nmModule = db.Modules.Nameplates
end

---@class BarDisplayEntry
---@field Display AuraContainerDisplay
---@field Signature number The look baked into its buttons, diffed to decide a restyle.
---@field Categories number The category toggles it was built for, diffed to decide a swap: a
---restyle reaches buttons, and a group can never be added to a container.
---@field Plate table? The nameplate it is bound to; nil while it is still on the free list.

---@class NameplateData
---@field Nameplate table
---@field Bar1Container IconSlotContainer?
---@field Bar2Container IconSlotContainer?
---@field Bar1Display AuraContainerDisplay?
---@field Bar2Display AuraContainerDisplay?
---@field KickTimer table? Timer that clears the kick icon on expiry.
---@field UnitToken string
