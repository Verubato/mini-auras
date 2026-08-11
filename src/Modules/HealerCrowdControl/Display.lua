---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local L = addon.L
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local unitWatcher = addon.Core.UnitAuraWatcher
local testSpellData = addon.Core.TestSpells
local units = addon.Utils.Units
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local rc = LibStub("LibRangeCheck-3.0")

-- Loaded before this file in TOC order.
local sound = addon.Modules.HealerCrowdControl.Sound

addon.Modules.HealerCrowdControl = addon.Modules.HealerCrowdControl or {}

---@class HealerCrowdControlDisplay
local M = {}
addon.Modules.HealerCrowdControl.Display = M

-- 12.1 path: healer CC icons render through one AuraContainer per healer, and the warning text
-- through a second, label-only container per healer (the engine shows the label button while a
-- CC aura is present, so no aura read is needed). Every healer's label anchors to the same
-- point: identical overlapping texts read as one label, which acts as an OR across healers.
-- The IconSlotContainer is kept for test mode.
--
-- The battleground 40-yard range gate (IsInRange, below) is also dropped on 12.1: it works by
-- skipping healers when rendering, and rendering is the engine's job there. In a battleground
-- every healer in the raid now gets a container, not just the nearby ones. Re-adding it would
-- mean SetEnabled(false) on out-of-range healers' displays on a range poll - possible, but it
-- was never wired up, so don't read the missing gate as an oversight in the sound/display code.
-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local paused = false
local testModeActive = false
-- 12.1 path: sorted healer-unit scratch so the display chain has a stable order (pairs order
-- would let the healer rows swap places between refreshes).
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

---@type TestSpell[]
local testSpells = {}

-- TEMPORARY: both only serve the legacy renderer's battleground range gate (see the header
-- comment); they and the LibRangeCheck import die with the 12.0 path.
local function IsInBattleground()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "pvp"
end

local function IsInRange(unit)
	local _, maxRange = rc:GetRange(unit)
	return maxRange ~= nil and maxRange <= 40
end

local function UpdateAnchorSize()
	if not healerAnchor then
		return
	end

	local options = db.Modules.HealerCCModule
	local iconSize = tonumber(options.Icons.Size) or 32
	-- The anchor's own fontstring is measured on both paths: on 12.1 the live text renders
	-- through the label containers, but those carry the same string at the same size, and their
	-- (possibly secret) frames must never be read.
	local text = healerAnchor.HealerWarning
	local stringWidth = text and text:GetStringWidth() or 0
	local showText = options.ShowWarningText
	local stringHeight = (showText and text and text:GetStringHeight()) or 0
	local containerWidth = iconSize
	if not USE_AURA_CONTAINERS and iconsContainer and iconsContainer.Frame then
		containerWidth = iconsContainer.Frame:GetWidth() or iconSize
	end
	local width = math.max(iconSize, stringWidth, containerWidth)
	local height = iconSize + stringHeight

	healerAnchor:SetSize(width, height)
end

---12.1 path: lays the per-healer aura containers out in a chain under the anchor. Chaining
---containers to each other avoids reading their (possibly secret) sizes; empty containers
---collapse so the row only occupies space for healers that are actually CC'd.
local function LayoutHealerDisplays()
	local options = db.Modules.HealerCCModule
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

---12.1 path: applies size/style options to every healer display.
local function RefreshHealerDisplays()
	local options = db.Modules.HealerCCModule
	local iconSize = tonumber(options.Icons.Size) or 32
	local fontSize = tonumber(options.Font.Size) or 32
	local showText = options.ShowWarningText == true

	for _, item in pairs(activePool) do
		local display = item.Display
		if display then
			display:SetIconSize(iconSize)
			display:SetSpacing(options.IconSpacing or 2)
			display:SetStyle(BuildStyle(options))
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

	LayoutHealerDisplays()
end

local function OnAuraStateUpdated()
	-- 12.1: rendering is container-driven and pool entries carry no Watcher - this legacy
	-- re-render would nil-index watcher.Watcher below.
	if USE_AURA_CONTAINERS then
		return
	end

	if paused then
		return
	end

	if not healerAnchor or not iconsContainer or not moduleUtil:IsModuleEnabled(ModuleName.HealerCrowdControl) then
		return
	end

	local options = db.Modules.HealerCCModule
	local iconsEnabled = options.Icons.Enabled
	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local colorByDispelType = options.Icons.ColorByDispelType
	local showTooltips = options.ShowTooltips ~= false

	UpdateAnchorSize()

	---@type AuraInfo[]
	local allCcAuraData = {}
	local slot = 0
	local checkRange = IsInBattleground()

	for _, watcher in pairs(activePool) do
		if not checkRange or IsInRange(watcher.Unit) then
			local ccState = watcher.Watcher:GetCcState()
			mini:Append(ccState, allCcAuraData)

			if iconsEnabled then
				for _, aura in ipairs(ccState) do
					slot = slot + 1
					iconsContainer:SetSlot(slot, {
						Texture = aura.SpellIcon,
						DurationObject = aura.DurationObject,
						Alpha = aura.IsCC,
						ReverseCooldown = iconsReverse,
						Glow = iconsGlow,
						Color = colorByDispelType and aura.DispelColor,
						FontScale = db.FontScale,
						SpellId = showTooltips and aura.SpellId or nil,
					})
				end
			end
		end
	end

	-- Clear any unused slots beyond the aura count
	for i = slot + 1, iconsContainer.Count do
		iconsContainer:SetSlotUnused(i)
	end

	local show = #allCcAuraData > 0
	local soundEnabled = db.Modules.HealerCCModule.Sound.Enabled

	if show then
		if healerAnchor:IsVisible() then
			return
		end

		healerAnchor:Show()

		if soundEnabled then
			sound:Play()
		end
	else
		healerAnchor:Hide()
	end
end

---Parks every active healer entry in the discard pool, disabling its watcher and display.
---Clearing a key mid-traversal is legal in Lua (only additions are not), so no staging list.
local function DiscardActiveEntries()
	for unit, item in pairs(activePool) do
		if item.Watcher then
			item.Watcher:Disable()
		end
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

local function Teardown()
	DiscardActiveEntries()

	if iconsContainer then
		iconsContainer:ResetAllSlots()
	end

	if healerAnchor then
		healerAnchor:Hide()
	end

	if USE_AURA_CONTAINERS then
		sound:Clear()
	end

	paused = true
end

local function EnableWatchers()
	paused = false
	for _, item in pairs(activePool) do
		if item.Watcher then
			item.Watcher:Enable()
		end
		if item.Display then
			item.Display:SetEnabled(true)
		end
	end
end

local function RefreshHealers()
	-- Everyone goes back to the discard pool first, so a healer that stayed is re-acquired
	-- rather than duplicated.
	DiscardActiveEntries()

	local healers = units:FindHealers()

	-- Re-add healers from the new set
	for _, healer in ipairs(healers) do
		local item = discardPool[healer]

		-- Container entries are interchangeable: same groups, retargeted by SetUnit. Taking any
		-- parked one caps the display count at the largest healer set seen at once, where the
		-- same-token match alone builds a new display for every token that ever held a healer
		-- (containers can never be freed). Legacy entries carry a unit-bound watcher and only
		-- fit their own token, so they keep the strict match.
		if not item and USE_AURA_CONTAINERS then
			local token, parked = next(discardPool)

			if parked then
				item = parked
				discardPool[token] = nil
			end
		end

		if item then
			if item.Watcher then
				item.Watcher:Enable()
			end
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
		elseif USE_AURA_CONTAINERS then
			local options = db.Modules.HealerCCModule
			item = {
				Unit = healer,
				Display = auraContainerDisplay:New(
					healerAnchor,
					healer,
					{ auraFilters:GroupSpec("CrowdControl", 5) },
					tonumber(options.Icons.Size) or 32,
					options.IconSpacing or 2,
					"Healer CC",
					-- Seeded at creation, not left to the restyle below. A healer display is
					-- built the moment a healer turns up, which in an arena is mid-match while
					-- auras are secret and every button setter is refused. Its buttons would
					-- then keep the unstyled look, no glow and no border, for the whole game.
					{ Style = BuildStyle(options), MasqueGroup = "Healer CC" }
				),
			}
			-- The warning text: a label-only container on the same CC filter, so the engine
			-- shows the text exactly while this healer has a CC aura. maxIcons 1 - one aura is
			-- enough to warrant the label, and more would repeat it.
			item.LabelDisplay = auraContainerDisplay:New(
				healerAnchor,
				healer,
				{ auraFilters:GroupSpec("CrowdControl", 1) },
				tonumber(options.Font.Size) or 32,
				0,
				"Healer CC",
				{ Label = L["Healer in CC!"], Style = BuildLabelStyle(options) }
			)
			-- Where the legacy warning fontstring sat. Every healer's label lands on this same
			-- point on purpose - see the header comment.
			item.LabelDisplay.Frame:SetPoint("TOP", healerAnchor, "TOP", 0, 6)
			activePool[healer] = item
		else
			item = {
				Unit = healer,
				Watcher = unitWatcher:New(healer, nil, {
					CC = true,
				}),
			}

			item.Watcher:RegisterCallback(OnAuraStateUpdated)
			activePool[healer] = item
		end
	end

	if USE_AURA_CONTAINERS then
		RefreshHealerDisplays()
		sound:Refresh(activePool)
		-- The anchor is the fixed positioning frame for the healer displays; with aura presence
		-- unreadable, it stays shown while the module is active and the icons come and go inside.
		if next(activePool) ~= nil and db.Modules.HealerCCModule.Icons.Enabled ~= false then
			healerAnchor:Show()
		else
			healerAnchor:Hide()
		end
		return
	end

	OnAuraStateUpdated()
end

local function RefreshTestFrame()
	local options = db.Modules.HealerCCModule

	if not iconsContainer or not options then
		return
	end

	local size = tonumber(options.Icons.Size) or 32

	iconsContainer:SetIconSize(size)

	if not options.Icons.Enabled then
		iconsContainer:ResetAllSlots()
	else
		local nextSlot = testSpellData:FillContainer(iconsContainer, testSpells, 1, {
			ReverseCooldown = options.Icons.ReverseCooldown,
			Glow = options.Icons.Glow,
			ColorByDispelType = options.Icons.ColorByDispelType,
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

local function EnsureFrames()
	if testModeActive then
		-- 12.1: test icons render through the IconSlotContainer and the test text through the
		-- anchor's own fontstring; hide the live displays so real and fake don't mix.
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

	-- Watchers only cover other people's healers, so the module goes dormant when the player
	-- is the healer.
	if units:IsHealer("player") then
		Teardown()
		return
	end

	EnableWatchers()
	RefreshHealers()
end

---@param options HealerCCModuleOptions
local function ApplyOptions(options)
	healerAnchor:ClearAllPoints()
	healerAnchor:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	local currentFont, _, _ = healerAnchor.HealerWarning:GetFont()
	healerAnchor.HealerWarning:SetFont(currentFont, options.Font.Size, options.Font.Flags)
	iconsContainer:SetIconSize(tonumber(options.Icons.Size) or 32)
	iconsContainer:SetSpacing(options.IconSpacing or 2)

	-- 12.1: the live warning text renders through the per-healer label containers; the anchor's
	-- own fontstring only serves the legacy path and the test-mode preview.
	if options.ShowWarningText and (not USE_AURA_CONTAINERS or testModeActive) then
		healerAnchor.HealerWarning:Show()
	else
		healerAnchor.HealerWarning:Hide()
	end
end

local function CreateFrames()
	local options = db.Modules.HealerCCModule

	healerAnchor = CreateFrame("Frame", addonName .. "HealerContainer")
	healerAnchor:Hide()
	healerAnchor:EnableMouse(false)
	healerAnchor:SetMovable(false)
	healerAnchor:SetIgnoreParentScale(true)
	-- A function rather than the table: a profile switch replaces the options wholesale.
	moduleUtil:MakeMovable(healerAnchor, function()
		return db.Modules.HealerCCModule
	end)

	local text = healerAnchor:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	text:SetPoint("TOP", healerAnchor, "TOP", 0, 6)
	-- Use the system default font to support all languages (e.g., Chinese)
	local defaultFont, _, _ = text:GetFont()
	text:SetFont(defaultFont, options.Font.Size, options.Font.Flags)
	text:SetText(L["Healer in CC!"])
	text:SetTextColor(1, 0.1, 0.1)
	text:SetShadowColor(0, 0, 0, 1)
	text:SetShadowOffset(1, -1)
	text:Show()

	healerAnchor.HealerWarning = text

	-- give the anchor an initial size so masque borders don't go crazy
	UpdateAnchorSize()

	-- Icons sit at the bottom of the anchor, text sits at the top.
	iconsContainer = iconSlotContainer:New(healerAnchor, 5, tonumber(options.Icons.Size) or 32, options.IconSpacing or 2, "Healer CC", nil, "Healer CC")
	iconsContainer.Frame:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
	iconsContainer.Frame:Show()
end

---@return HealerCCModuleOptions?
function M:GetOptions()
	-- The anchor is built in Init; without it there is nothing to configure.
	if not db or not healerAnchor then
		return nil
	end

	return db.Modules.HealerCCModule
end

---@param value boolean
function M:SetPaused(value)
	paused = value
end

---@param value boolean
function M:SetTestMode(value)
	testModeActive = value
end

function M:Teardown()
	Teardown()
end

function M:EnsureFrames()
	EnsureFrames()
end

---@param options HealerCCModuleOptions
function M:ApplyOptions(options)
	ApplyOptions(options)
end

function M:RefreshTestFrame()
	RefreshTestFrame()
end

function M:OnAuraStateUpdated()
	OnAuraStateUpdated()
end

function M:ResetIcons()
	if iconsContainer then
		iconsContainer:ResetAllSlots()
	end
end

function M:ShowAnchor()
	healerAnchor:Show()
end

---Visibility is left to Refresh: on 12.1 the anchor has to stay shown while the module is
---active, so hiding it here would blank the live display until the next addon-wide Refresh.
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

	CreateFrames()
end

---@class HealerWatchEntry
---@field Unit string
---@field Watcher Watcher? Legacy path only (nil on 12.1).
---@field Display AuraContainerDisplay? 12.1 path only.
---@field LabelDisplay AuraContainerDisplay? 12.1 path only: the label-only warning-text container.
