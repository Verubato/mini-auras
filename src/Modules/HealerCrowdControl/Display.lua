---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local testSpellData = addon.Core.TestSpells
local units = addon.Utils.UnitUtil
local moduleUtil = addon.Utils.ModuleUtil
local fontUtil = addon.Utils.FontUtil
local wowEx = addon.Utils.WoWEx
local changeStamp = addon.Utils.ChangeStamp

-- Loaded before this file in TOC order.
local sound = addon.Modules.HealerCrowdControl.Sound

addon.Modules.HealerCrowdControl = addon.Modules.HealerCrowdControl or {}

---@class HealerCrowdControlDisplay
local M = {}
addon.Modules.HealerCrowdControl.Display = M

-- Healer CC icons render through one AuraContainer per healer, and the warning text through a
-- second, label-only container per healer (the engine shows the label button while a CC aura is
-- present, so no aura read is needed). Every healer's label anchors to the same point: identical
-- overlapping texts read as one label, which acts as an OR across healers. The IconSlotContainer
-- is kept for test mode.
--
-- There is no battleground 40-yard range gate: skipping merely-far healers would have to happen
-- while rendering, and rendering is the engine's job. Every healer in the raid gets a container,
-- not just the nearby ones. Healers outside the player's visible world are the exception:
-- ApplyUnitGates zeroes their budgets, because the engine cannot filter their auras at all
-- (see Core/AuraFilters).

-- The Masque group these icons are skinned under, and the public MiniCCModule frame tag.
local MASQUE_GROUP = "Healer Crowd Control"
-- Ceiling on the per-healer icon budget, and the one label slot: one CC aura is enough to warrant
-- the text. Containers are built at the ceiling, so the slider only re-budgets what is there.
-- One look per module, so one key each for the icons and for the whole parked-entry test.
local PARKED_STYLE_KEY = "HealerCcParkedStyle"
local PARKED_OPTIONS_KEY = "HealerCcParkedOptions"
local MAX_CC_ICONS = 5
local LABEL_MAX_ICONS = 1
local testModeActive = false
-- Sorted healer-unit scratch so the display chain has a stable order (pairs order would let the
-- healer rows swap places between refreshes).
local healerOrderScratch = {}

---@type Db
local db

---@type table
local healerAnchor

---@type IconSlotContainer
local iconsContainer

-- Healers currently drawn, and the entries parked for reuse. Owned here; the module asks for
-- whole-set operations rather than reaching into them.
---@type table<string, HealerWatchEntry>
local activePool = {}
---@type table<string, HealerWatchEntry>
local discardPool = {}
-- Names the discard-pool slots for entries rejected while styling was restricted, so they park
-- under keys no unit token can collide with (see RefreshHealers).
local staleParkCounter = 0
-- The options the parked entries were last brought onto, latched only when that pass actually
-- ran: a restricted refresh leaves it stale, so the next unrestricted one retries.
local optionsStamp = changeStamp:New()
local parkedOptionsGeneration

---@type TestSpell[]
local testSpells = {}

---How many CC icons one healer may show, from the slider and capped at what the display holds.
---@param options table
---@return number
local function IconBudget(options)
	local budget = tonumber(options.Icons.MaxIcons) or MAX_CC_ICONS

	return math.max(0, math.min(math.floor(budget), MAX_CC_ICONS))
end

local function UpdateAnchorSize()
	if not healerAnchor then
		return
	end

	local options = db.Modules.HealerCrowdControl
	local iconSize = tonumber(options.Icons.Size) or 32
	-- The anchor's own fontstring stands in for the live text: the label containers carry the
	-- same string at the same size, and their (possibly secret) frames must never be read.
	local text = healerAnchor.HealerWarning
	local stringWidth = text and text:GetStringWidth() or 0
	local showText = options.ShowWarningText
	local stringHeight = (showText and text and text:GetStringHeight()) or 0
	local width = math.max(iconSize, stringWidth)
	local height = iconSize + stringHeight

	healerAnchor:SetSize(width, height)
end

---Lays the per-healer aura containers out in a chain under the anchor. Chaining containers to
---each other avoids reading their (possibly secret) sizes; empty containers collapse so the row
---only occupies space for healers that are actually CC'd.
local function LayoutHealerDisplays()
	local options = db.Modules.HealerCrowdControl
	local spacing = options.IconSpacing or 2

	wipe(healerOrderScratch)
	for unit in pairs(activePool) do
		healerOrderScratch[#healerOrderScratch + 1] = unit
	end
	table.sort(healerOrderScratch)

	local previous
	for _, unit in ipairs(healerOrderScratch) do
		local item = activePool[unit]
		local frame = item and item.Display and item.Display.Frame
		if frame then
			frame:ClearAllPoints()
			if previous then
				frame:SetPoint("LEFT", previous, "RIGHT", spacing, 0)
			else
				frame:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
			end
			previous = frame
		end
	end
end

---The look every healer display is built with and restyled to.
---@param options table
---@return AuraDisplayStyle
local function BuildStyle(options)
	local style = auraContainerDisplay:BuildStandardStyle(options.Icons)

	-- The display only ever holds CC, and most of that is physical: without this a stun gets the
	-- tinted glow but no ring, which reads as the border being broken.
	style.BorderWithoutDispelType = true
	style.ShowTooltips = options.ShowTooltips ~= false

	return style
end

---The style for the label-only warning-text displays. The display size doubles as the button
---size, so the font size is passed to ApplyConfig/New separately as well.
---@param options table
---@return AuraDisplayStyle
local function BuildLabelStyle(options)
	local style = auraContainerDisplay:GetStyleScratch()

	style.LabelFontSize = tonumber(options.Font.Size) or 32
	style.LabelFontFlags = options.Font.Flags
	style.ShowTooltips = false

	return style
end

---Whether a parked entry's displays already carry the current options. Asked while aura styling
---is restricted, where a reused entry cannot be restyled and would keep its old look for the
---whole match.
---@param item HealerWatchEntry
---@param options table
---@return boolean
local function ItemCarriesOptions(item, options)
	local display = item.Display
	local label = item.LabelDisplay

	-- One style scratch is shared, so each style is built right before the compare that reads it.
	return (not display or display:CarriesConfig(tonumber(options.Icons.Size) or 32,
			options.IconSpacing or 2, BuildStyle(options)))
		and (not label or label:CarriesConfig(tonumber(options.Font.Size) or 32, 0,
			BuildLabelStyle(options)))
end

---Applies size/style options to every healer display.
local function RefreshHealerDisplays()
	local options = db.Modules.HealerCrowdControl
	local iconSize = tonumber(options.Icons.Size) or 32
	local fontSize = tonumber(options.Font.Size) or 32
	local showText = options.ShowWarningText == true

	for _, item in pairs(activePool) do
		local display = item.Display
		if display then
			-- One pass for all three values; the individual setters would each restyle every button.
			display:ApplyConfig(iconSize, options.IconSpacing or 2, BuildStyle(options))
			display:SetEnabled(options.Icons.Enabled ~= false)
			display:SetShown(options.Icons.Enabled ~= false and not testModeActive)
		end

		local label = item.LabelDisplay
		if label then
			label:ApplyConfig(fontSize, 0, BuildLabelStyle(options))
			label:SetEnabled(showText)
			label:SetShown(showText and not testModeActive)
		end
	end

	-- Parked entries converge on the current look too, so a healer joining under restriction can
	-- reuse one that already matches (ItemCarriesOptions) instead of forcing a mid-combat build.
	-- A handful at most, all hidden, so on the spot rather than staggered. Gated on the options
	-- actually moving, since this runs on every roster event; and skipped, with the latch left
	-- stale, while restricted - the restyle could not land, an unchanged entry may still match
	-- as it is, and the next unrestricted refresh retries.
	-- The label's font rides in the same stamp: it is baked into the parked entries too, and a
	-- change to it has to convert them exactly like a change to the icons.
	optionsStamp:Begin(PARKED_OPTIONS_KEY)
	optionsStamp:Add(auraContainerDisplay:GetStyleGeneration(PARKED_STYLE_KEY, BuildStyle(options),
		iconSize, options.IconSpacing or 2))
	optionsStamp:Add(fontSize)
	optionsStamp:Add(options.Font.Flags)

	local generation = optionsStamp:Commit()

	if parkedOptionsGeneration ~= generation and not wowEx:IsAuraStylingRestricted() then
		parkedOptionsGeneration = generation

		for _, item in pairs(discardPool) do
			if item.Display then
				item.Display:ApplyConfig(iconSize, options.IconSpacing or 2, BuildStyle(options))
			end

			if item.LabelDisplay then
				item.LabelDisplay:ApplyConfig(fontSize, 0, BuildLabelStyle(options))
			end
		end
	end

	LayoutHealerDisplays()
end

---Parks every active healer entry in the discard pool, disabling its displays.
---Clearing a key mid-traversal is legal in Lua (only additions are not), so no staging list.
local function DiscardActiveEntries()
	for unit, item in pairs(activePool) do
		if item.Display then
			item.Display:SetEnabled(false)
			item.Display:Hide()
		end
		if item.LabelDisplay then
			item.LabelDisplay:SetEnabled(false)
			item.LabelDisplay:Hide()
		end
		discardPool[unit] = item
		activePool[unit] = nil
	end
end

local function EnableWatchers()
	for _, item in pairs(activePool) do
		if item.Display then
			item.Display:SetEnabled(true)
		end
	end
end

---Budgets one healer's containers for the unit's current state. Outside the player's visible
---world the engine stops evaluating the CROWD_CONTROL token and both containers fill with
---unrelated debuffs (the spell-id map is identity-gated off on assistable units, so the token is
---the only filter left), so a healer that far away shows nothing - icons and warning text both.
---Visibility has no event of its own, which is why the unit state poller re-asks this.
---Urgent: the unit a gate zeroes emits no aura events, so a budget flip parked for combat would
---keep showing the garbage until regen.
---@param item HealerWatchEntry
local function ApplyUnitGates(item)
	local visible = units:IsVisible(item.Unit)

	if item.Display then
		item.Display:SetMaxIcons(auraFilters.GroupKey.CrowdControl,
			visible and IconBudget(db.Modules.HealerCrowdControl) or 0, true)
	end

	if item.LabelDisplay then
		item.LabelDisplay:SetMaxIcons(auraFilters.GroupKey.CrowdControl, visible and LABEL_MAX_ICONS or 0, true)
	end
end

local function RefreshHealers()
	-- Everyone goes back to the discard pool first, so a healer that stayed is re-acquired
	-- rather than duplicated.
	DiscardActiveEntries()

	local healers = units:FindHealers()
	local options = db.Modules.HealerCrowdControl
	local restricted = wowEx:IsAuraStylingRestricted()

	-- Re-add healers from the new set
	for _, healer in ipairs(healers) do
		local item = discardPool[healer]

		if item and restricted and not ItemCarriesOptions(item, options) then
			-- Re-keyed out of the token's slot: the fresh entry built below lands back in the
			-- discard pool under this token on the next refresh, and must not clobber this one.
			staleParkCounter = staleParkCounter + 1
			discardPool["stale" .. staleParkCounter] = item
			discardPool[healer] = nil
			item = nil
			-- The pool now holds an entry the parked restyle has not seen; unlatch so the next
			-- unrestricted refresh brings it onto the current look.
			parkedOptionsGeneration = nil
		end

		-- Container entries are interchangeable: same groups, retargeted by SetUnit. Taking any
		-- parked one caps the display count at the largest healer set seen at once, where the
		-- same-token match alone builds a new display for every token that ever held a healer
		-- (containers can never be freed). While styling is restricted only an entry already
		-- carrying the current look is taken: a reused one cannot be restyled, so a mismatch
		-- would keep its old look for the whole match.
		if not item then
			for token, parked in pairs(discardPool) do
				if not restricted or ItemCarriesOptions(parked, options) then
					item = parked
					discardPool[token] = nil
					break
				end
			end
		end

		if item then
			if item.Display then
				item.Display:SetUnit(healer)
				item.Display:SetEnabled(true)
			end
			if item.LabelDisplay then
				-- Enabled/shown state follows the ShowWarningText option in RefreshHealerDisplays.
				item.LabelDisplay:SetUnit(healer)
			end
			item.Unit = healer
			activePool[healer] = item
			discardPool[healer] = nil
			-- The budgets a parked entry carries belong to whoever held it last; re-ask the gate
			-- for the healer it tracks now.
			ApplyUnitGates(item)
		else
			item = {
				Unit = healer,
				Display = auraContainerDisplay:New(
					healerAnchor,
					healer,
					{ auraFilters:GroupSpec("CrowdControl", IconBudget(options)) },
					tonumber(options.Icons.Size) or 32,
					options.IconSpacing or 2,
					MASQUE_GROUP,
					-- Seeded at creation, not left to the restyle below. A healer display is
					-- built the moment a healer turns up, which in an arena is mid-match while
					-- auras are secret and every button setter is refused. Its buttons would
					-- then keep the unstyled look, no glow and no border, for the whole game.
					{ Style = BuildStyle(options), MasqueGroup = MASQUE_GROUP }
				),
			}
			-- The warning text: a label-only container on the same CC filter, so the engine
			-- shows the text exactly while this healer has a CC aura. maxIcons 1 - one aura is
			-- enough to warrant the label, and more would repeat it.
			item.LabelDisplay = auraContainerDisplay:New(
				healerAnchor,
				healer,
				{ auraFilters:GroupSpec("CrowdControl", LABEL_MAX_ICONS) },
				tonumber(options.Font.Size) or 32,
				0,
				MASQUE_GROUP,
				{ Label = L["Healer in CC!"], Style = BuildLabelStyle(options) }
			)
			-- Every healer's label lands on this same point on purpose - see the header comment.
			item.LabelDisplay.Frame:SetPoint("TOP", healerAnchor, "TOP", 0, 6)
			activePool[healer] = item
			-- The groups above are built with the full budget; ask the gate right away, or a
			-- display born for a healer already outside the visible world shows unfiltered auras
			-- until the next refresh.
			ApplyUnitGates(item)
		end
	end

	RefreshHealerDisplays()
	sound:Refresh(activePool)
	-- The anchor is the fixed positioning frame for the healer displays; with aura presence
	-- unreadable, it stays shown while the module is active and the icons come and go inside.
	if next(activePool) ~= nil and db.Modules.HealerCrowdControl.Icons.Enabled ~= false then
		healerAnchor:Show()
	else
		healerAnchor:Hide()
	end
end

local function CreateFrames()
	local options = db.Modules.HealerCrowdControl

	healerAnchor = CreateFrame("Frame", addonName .. "HealerContainer")
	healerAnchor:Hide()
	healerAnchor:EnableMouse(false)
	healerAnchor:SetMovable(false)
	healerAnchor:SetIgnoreParentScale(true)
	-- A function rather than the table: a profile switch replaces the options wholesale.
	moduleUtil:MakeMovable(healerAnchor, function()
		return db.Modules.HealerCrowdControl
	end)

	local text = healerAnchor:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	text:SetPoint("TOP", healerAnchor, "TOP", 0, 6)
	-- The template's face is the base Apply keeps, so every language renders when no font is
	-- picked (e.g. Chinese).
	fontUtil:Apply(text, options.Font.Size, options.Font.Flags)
	text:SetText(L["Healer in CC!"])
	text:SetTextColor(1, 0.1, 0.1)
	text:SetShadowColor(0, 0, 0, 1)
	text:SetShadowOffset(1, -1)
	text:Show()

	healerAnchor.HealerWarning = text

	-- give the anchor an initial size so masque borders don't go crazy
	UpdateAnchorSize()

	-- Icons sit at the bottom of the anchor, text sits at the top.
	iconsContainer = iconSlotContainer:New(healerAnchor, MAX_CC_ICONS, tonumber(options.Icons.Size) or 32, options.IconSpacing or 2, MASQUE_GROUP, nil, MASQUE_GROUP)
	iconsContainer.Frame:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
	iconsContainer.Frame:Show()
end

---Every healer the module currently draws, for the unit state poller's visibility scan.
---@param out string[] Filled in place and returned, so the caller can keep one table.
---@return string[]
function M:CollectWatchedUnits(out)
	wipe(out)

	for unit in pairs(activePool) do
		out[#out + 1] = unit
	end

	return out
end

---Sets how many icons one healer's containers may show: the usual count while they are inside the
---player's visible world, none while they are outside it. A token nobody draws is not in the pool.
---@param unit string
function M:ReapplyUnitGates(unit)
	local item = activePool[unit]

	if item then
		ApplyUnitGates(item)
	end
end

---@return HealerCrowdControlModuleOptions?
function M:GetOptions()
	if not db then
		return nil
	end

	return db.Modules.HealerCrowdControl
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

function M:Teardown()
	DiscardActiveEntries()

	if iconsContainer then
		iconsContainer:ResetAllSlots()
	end

	if healerAnchor then
		healerAnchor:Hide()
	end

	sound:Clear()
end

function M:EnsureFrames()
	if not healerAnchor then
		CreateFrames()
	end

	if testModeActive then
		-- Test icons render through the IconSlotContainer and the test text through the anchor's
		-- own fontstring; the live displays are hidden so real and fake don't mix. They are
		-- restyled on the way, or a look they were never told about - a font swapped while the
		-- test was up - would be waiting on them when the test stops.
		RefreshHealerDisplays()

		for _, item in pairs(activePool) do
			if item.Display then
				item.Display:Hide()
			end
			if item.LabelDisplay then
				item.LabelDisplay:Hide()
			end
		end
		return
	end

	-- Only other people's healers are tracked, so the module goes dormant when the player is
	-- the healer.
	if units:IsHealer("player") then
		M:Teardown()
		return
	end

	EnableWatchers()
	RefreshHealers()
end

---@param options HealerCrowdControlModuleOptions
function M:ApplyOptions(options)
	healerAnchor:ClearAllPoints()
	healerAnchor:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	fontUtil:Apply(healerAnchor.HealerWarning, options.Font.Size, options.Font.Flags)
	iconsContainer:SetIconSize(tonumber(options.Icons.Size) or 32)
	iconsContainer:SetSpacing(options.IconSpacing or 2)

	-- The live warning text renders through the per-healer label containers; the anchor's own
	-- fontstring only serves the test-mode preview.
	if options.ShowWarningText and testModeActive then
		healerAnchor.HealerWarning:Show()
	else
		healerAnchor.HealerWarning:Hide()
	end
end

function M:RefreshTestFrame()
	local options = db.Modules.HealerCrowdControl

	if not iconsContainer or not options then
		return
	end

	local size = tonumber(options.Icons.Size) or 32

	iconsContainer:SetIconSize(size)

	if not options.Icons.Enabled then
		iconsContainer:ResetAllSlots()
	else
		local nextSlot = testSpellData:FillContainer(iconsContainer, testSpells, 1, {
			Count = IconBudget(options),
			ReverseCooldown = options.Icons.ReverseCooldown,
			Glow = options.Icons.Glow,
			ColorByDispelType = options.Icons.ColorByDispelType,
			-- The live buttons draw border and glow together, so the preview does too.
			Border = true,
			FontScale = db.FontScale,
			ShowTooltips = options.ShowTooltips ~= false,
			Stagger = true,
		})

		for i = nextSlot, iconsContainer.Count do
			iconsContainer:SetSlotUnused(i)
		end
	end

	UpdateAnchorSize()
end

function M:ResetIcons()
	if iconsContainer then
		iconsContainer:ResetAllSlots()
	end
end

function M:ShowAnchor()
	if healerAnchor then
		healerAnchor:Show()
	end
end

---Visibility is left to Refresh: the anchor has to stay shown while the module is active, so
---hiding it here would blank the live display until the next addon-wide Refresh.
---@param active boolean
function M:SetAnchorInteractive(active)
	if not healerAnchor then
		return
	end

	healerAnchor:EnableMouse(active)
	healerAnchor:SetMovable(active)
	moduleUtil:SetTestLabel(healerAnchor, active and L["Healer"] or nil)

	if active then
		healerAnchor:Show()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	testSpells = testSpellData.CrowdControl
end

---@class HealerWatchEntry
---@field Unit string
---@field Display AuraContainerDisplay?
---@field LabelDisplay AuraContainerDisplay? The label-only warning-text container.
