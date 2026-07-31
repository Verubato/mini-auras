---@type string, Addon
local addonName, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local L = addon.L
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local unitWatcher = addon.Core.UnitAuraWatcher
local units = addon.Utils.Units
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local rc = LibStub("LibRangeCheck-3.0")
-- 12.1 path: healer CC icons render through one AuraContainer per healer. The warning text
-- cannot work there (it requires knowing whether a CC aura is present, which 12.1 makes
-- secret). The sound survives via C_UnitAuras.AddAuraSound: the ENGINE plays a sound when a
-- known CC aura lands on a registered healer, without the addon ever reading aura state -
-- registrations are per (unit, spellId), fed from the generated Core/AuraSoundData CC list.
-- The IconSlotContainer is kept for test mode. TEMPORARY dual path: remove the watcher branch
-- once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local paused = false
-- 12.1 path: handles returned by AddAuraSound, so registrations can be removed on change.
local registeredAuraSounds = {}
-- 12.1 path: sorted healer-unit scratch so the display chain has a stable order (pairs order
-- would let the healer rows swap places between refreshes).
local healerOrderScratch = {}
-- Signature of the last registration set (healers + sound settings), to skip redundant
-- re-registration (each refresh would otherwise re-issue ~1k API calls per healer).
local auraSoundSignature = nil
local testModeActive = false
local previousTestSoundEnabled = false
local soundFile

---@type Db
local db

---@type table
local healerAnchor

---@type IconSlotContainer
local iconsContainer

---@type table<string, HealerWatchEntry>
local activePool = {}
---@type table<string, HealerWatchEntry>
local discardPool = {}
local eventsFrame

---@type TestSpell[]
local testSpells = {}

---@class HealerWatchEntry
---@field Unit string
---@field Watcher Watcher? Legacy path only (nil on 12.1).
---@field Display AuraContainerDisplay? 12.1 path only.

---@class HealerCrowdControlModule : IModule
local M = {}
addon.Modules.HealerCrowdControlModule = M

local function IsInBattleground()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "pvp"
end

local function IsInRange(unit)
	local _, maxRange = rc:GetRange(unit)
	return maxRange ~= nil and maxRange <= 40
end

local function PlaySound()
	-- 12.1: sounds play engine-side via the AddAuraSound registrations (see RegisterAuraSounds);
	-- this legacy transition-based path must not double up.
	if USE_AURA_CONTAINERS then
		return
	end

	local soundFileName = db.Modules.HealerCCModule.Sound.File or "Sonar.ogg"
	soundFile = addon.Config.MediaLocation .. soundFileName
	PlaySoundFile(soundFile, db.Modules.HealerCCModule.Sound.Channel or "Master")
end

local function UpdateAnchorSize()
	if not healerAnchor then
		return
	end

	local options = db.Modules.HealerCCModule
	local iconSize = tonumber(options.Icons.Size) or 32
	local text = healerAnchor.HealerWarning
	local stringWidth = text and text:GetStringWidth() or 0
	-- 12.1: the warning text is disabled (see the header comment) and an AuraContainer's size can
	-- be secret, so only the icon size feeds the anchor size there.
	local showText = not USE_AURA_CONTAINERS and options.ShowWarningText
	local stringHeight = (showText and text and text:GetStringHeight()) or 0
	local containerWidth = iconSize
	if not USE_AURA_CONTAINERS and iconsContainer and iconsContainer.Frame then
		containerWidth = iconsContainer.Frame:GetWidth() or iconSize
	end
	local width = math.max(iconSize, stringWidth, containerWidth)
	local height = iconSize + stringHeight

	healerAnchor:SetSize(width, height)
end

---12.1 path: removes every registered aura sound.
local function ClearAuraSounds()
	for i = #registeredAuraSounds, 1, -1 do
		C_UnitAuras.RemoveAuraSound(registeredAuraSounds[i])
		registeredAuraSounds[i] = nil
	end
	auraSoundSignature = nil
end

---12.1 path: registers an engine-side sound for every known player CC spell on every active
---healer. Skipped (cheaply) when the healer set and sound settings are unchanged.
local function RegisterAuraSounds()
	local options = db.Modules.HealerCCModule
	local enabled = options.Sound.Enabled
		and moduleUtil:IsModuleEnabled(ModuleName.HealerCrowdControl)
		and next(activePool) ~= nil

	if not enabled then
		ClearAuraSounds()
		return
	end

	local soundFilePath = addon.Config.MediaLocation .. (options.Sound.File or "Sonar.ogg")
	local channel = options.Sound.Channel or "Master"

	local healerUnits = {}
	for unit in pairs(activePool) do
		healerUnits[#healerUnits + 1] = unit
	end
	table.sort(healerUnits)
	local signature = table.concat(healerUnits, ",") .. "|" .. soundFilePath .. "|" .. channel
	if signature == auraSoundSignature then
		return
	end

	ClearAuraSounds()
	auraSoundSignature = signature

	local soundInfo = { unitToken = nil, spellID = nil, soundFileName = soundFilePath, outputChannel = channel }
	for _, unit in ipairs(healerUnits) do
		soundInfo.unitToken = unit
		for spellId in pairs(addon.Core.AuraSoundData.CC) do
			soundInfo.spellID = spellId
			local soundId = C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, soundInfo)
			if soundId then
				registeredAuraSounds[#registeredAuraSounds + 1] = soundId
			end
		end
	end
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

---12.1 path: applies size/style options to every healer display.
local function RefreshHealerDisplays()
	local options = db.Modules.HealerCCModule
	local iconSize = tonumber(options.Icons.Size) or 32

	for _, item in pairs(activePool) do
		local display = item.Display
		if display then
			display:SetIconSize(iconSize)
			display:SetSpacing(options.IconSpacing or 2)
			display:SetStyle({
				ReverseCooldown = options.Icons.ReverseCooldown,
				ColorByDispelType = options.Icons.ColorByDispelType,
				Glow = options.Icons.Glow,
				FontScale = db.FontScale,
				ShowTooltips = options.ShowTooltips ~= false,
			})
			display:SetEnabled(options.Icons.Enabled ~= false)
			display.Frame:SetShown(options.Icons.Enabled ~= false and not testModeActive)
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
			PlaySound()
		end
	else
		healerAnchor:Hide()
	end
end

local function DisableWatchers()
	local toDiscard = {}
	for unit in pairs(activePool) do
		toDiscard[#toDiscard + 1] = unit
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		if item then
			if item.Watcher then
				item.Watcher:Disable()
			end
			if item.Display then
				item.Display:SetEnabled(false)
				item.Display.Frame:Hide()
			end
			discardPool[unit] = item
			activePool[unit] = nil
		end
	end

	if iconsContainer then
		iconsContainer:ResetAllSlots()
	end

	if healerAnchor then
		healerAnchor:Hide()
	end

	if USE_AURA_CONTAINERS then
		ClearAuraSounds()
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
	-- Remove all active healers from the pool to avoid duplicates
	local toDiscard = {}
	for unit in pairs(activePool) do
		toDiscard[#toDiscard + 1] = unit
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		if item then
			if item.Watcher then
				item.Watcher:Disable()
			end
			if item.Display then
				item.Display:SetEnabled(false)
				item.Display.Frame:Hide()
			end
			discardPool[unit] = item
			activePool[unit] = nil
		end
	end

	local healers = units:FindHealers()

	-- Re-add healers from the new set
	for _, healer in ipairs(healers) do
		local item = discardPool[healer]

		if item then
			if item.Watcher then
				item.Watcher:Enable()
			end
			if item.Display then
				item.Display:SetUnit(healer)
				item.Display:SetEnabled(true)
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
					{ { Key = "cc", FilterString = "HARMFUL|CROWD_CONTROL", MaxIcons = 5 } },
					tonumber(options.Icons.Size) or 32,
					options.IconSpacing or 2,
					"Healer CC"
				),
			}
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
		RegisterAuraSounds()
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
	local now = GetTime()

	iconsContainer:SetIconSize(size)

	if not options.Icons.Enabled then
		iconsContainer:ResetAllSlots()
	else
		for i, spell in ipairs(testSpells) do
			local texture = C_Spell.GetSpellTexture(spell.SpellId)

			if texture then
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5

				iconsContainer:SetSlot(i, {
					Texture = texture,
					DurationObject = wowEx:CreateDuration(startTime, duration),
					Alpha = true,
					ReverseCooldown = options.Icons.ReverseCooldown,
					Glow = options.Icons.Glow,
					Color = options.Icons.ColorByDispelType and spell.DispelColor,
					FontScale = db.FontScale,
					SpellId = options.ShowTooltips ~= false and spell.SpellId or nil,
				})
			end
		end

		-- Clear any unused slots beyond the test spell count
		for i = #testSpells + 1, iconsContainer.Count do
			iconsContainer:SetSlotUnused(i)
		end
	end

	UpdateAnchorSize()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		C_Timer.After(0, function()
			M:Refresh()
		end)
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
	OnAuraStateUpdated()
end

local function EnableDisable()
	local options = db.Modules.HealerCCModule
	local moduleEnabled = moduleUtil:IsModuleEnabled(ModuleName.HealerCrowdControl)

	if testModeActive then
		if not moduleEnabled then
			healerAnchor:Hide()
			return
		end

		-- 12.1: test icons render through the IconSlotContainer; hide the live aura displays
		-- so real and fake icons don't mix.
		for _, item in pairs(activePool) do
			if item.Display then
				item.Display.Frame:Hide()
			end
		end

		healerAnchor:Show()
		RefreshTestFrame()

		if previousTestSoundEnabled ~= options.Sound.Enabled and options.Sound.Enabled then
			if USE_AURA_CONTAINERS then
				-- The transition-based PlaySound is disabled on 12.1 (engine-side AddAuraSound
				-- covers live auras), but the config preview still needs to demo the file.
				PlaySoundFile(addon.Config.MediaLocation .. (options.Sound.File or "Sonar.ogg"), options.Sound.Channel or "Master")
			else
				PlaySound()
			end
		end

		previousTestSoundEnabled = options.Sound.Enabled
		return
	end

	if units:IsHealer("player") then
		DisableWatchers()
		return
	end

	if not moduleEnabled then
		DisableWatchers()
		return
	end

	-- Module is enabled, ensure watchers are enabled
	EnableWatchers()
	RefreshHealers()
end

function M:StartTesting()
	testModeActive = true
	Pause()
	M:Refresh()

	if not healerAnchor then
		return
	end

	healerAnchor:EnableMouse(true)
	healerAnchor:SetMovable(true)
	healerAnchor:Show()
end

function M:StopTesting()
	testModeActive = false
	Resume()

	if not healerAnchor then
		return
	end

	healerAnchor:EnableMouse(false)
	healerAnchor:SetMovable(false)
	healerAnchor:Hide()
end

function M:Refresh()
	if not healerAnchor then
		return
	end

	local options = db.Modules.HealerCCModule

	-- update anchor positions and sizes
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

	-- 12.1: the warning text needs to know whether a CC aura is present, which is secret there,
	-- so it is disabled outright.
	if options.ShowWarningText and not USE_AURA_CONTAINERS then
		healerAnchor.HealerWarning:Show()
	else
		healerAnchor.HealerWarning:Hide()
	end

	EnableDisable()
end

function M:Init()
	db = mini:GetSavedVars()

	previousTestSoundEnabled = db.Modules.HealerCCModule.Sound.Enabled

	-- Initialize test spells
	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	testSpells = { kidneyShot, fear, hex }

	local options = db.Modules.HealerCCModule

	healerAnchor = CreateFrame("Frame", addonName .. "HealerContainer")
	healerAnchor:Hide()
	healerAnchor:EnableMouse(false)
	healerAnchor:SetMovable(false)
	healerAnchor:SetClampedToScreen(true)
	healerAnchor:RegisterForDrag("LeftButton")
	healerAnchor:SetIgnoreParentScale(true)
	healerAnchor:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	healerAnchor:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		db.Modules.HealerCCModule.Point = point
		db.Modules.HealerCCModule.RelativePoint = relativePoint
		db.Modules.HealerCCModule.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		db.Modules.HealerCCModule.Offset.X = x
		db.Modules.HealerCCModule.Offset.Y = y
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

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	EnableDisable()
end
