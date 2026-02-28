---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local units = addon.Utils.Units
local testModeActive = false
local paused = false
local inPrepRoom = false
local eventsFrame
local soundFile
---@type Db
local db

---@type table<number, boolean>
local previousImportantAuras = {}
---@type table<number, boolean>
local previousDefensiveAuras = {}

local cachedVoiceID
local cachedTTSVolume
local cachedTTSSpeechRate
local cachedTTSImportantEnabled
local cachedTTSDefensiveEnabled
---@type IconSlotContainer
local container
---@type Watcher[]
local arenaWatchers
---@type table<string, Watcher>
local nameplateWatchers = {}
---@type Watcher?
local targetWatcher
---@type Watcher?
local focusWatcher

---@class AlertsModule : IModule
local M = {}
addon.Modules.AlertsModule = M

local function PlaySound(spellType)
	local soundConfig
	if spellType == "important" then
		soundConfig = db.Modules.AlertsModule.Sound.Important
	elseif spellType == "defensive" then
		soundConfig = db.Modules.AlertsModule.Sound.Defensive
	else
		return
	end

	if not soundConfig.Enabled then
		return
	end

	local soundFileName = soundConfig.File or "Sonar.ogg"
	soundFile = addon.Config.MediaLocation .. soundFileName
	PlaySoundFile(soundFile, soundConfig.Channel or "Master")
end

local function AnnounceTTS(spellName, spellType)
	if not db.Modules.AlertsModule.TTS then
		return
	end

	if not spellName then
		return
	end

	local enabled = false
	if spellType == "important" and cachedTTSImportantEnabled then
		enabled = true
	elseif spellType == "defensive" and cachedTTSDefensiveEnabled then
		enabled = true
	end

	if not enabled then
		return
	end

	pcall(function()
		local speechRate = cachedTTSSpeechRate or 0
		C_VoiceChat.SpeakText(cachedVoiceID, spellName, speechRate, cachedTTSVolume, true)
	end)
end

local hadImportantAlerts = false
local hadDefensiveAlerts = false
local pendingAuraUpdate = false

local function ProcessWatcherData(
	watcher,
	slot,
	iconsEnabled,
	iconsGlow,
	iconsReverse,
	colorByClass,
	currentImportantAuras,
	currentDefensiveAuras
)
	local unit = watcher:GetUnit()

	-- when units go stealth, we can't get their aura data anymore
	if not unit or not UnitExists(unit) then
		return slot
	end

	local color = nil

	-- Get class color if the option is enabled
	if colorByClass then
		local _, class = UnitClass(unit)
		if class then
			local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
			if classColor then
				color = { r = classColor.r, g = classColor.g, b = classColor.b, a = 1 }
			end
		end
	end

	local defensivesData = watcher:GetDefensiveState()
	local importantData = watcher:GetImportantState()

	-- Process important spells
	if #importantData > 0 then
		for _, data in ipairs(importantData) do
			if iconsEnabled then
				-- prevent overflowing the container
				if slot >= container.Count then
					break
				end

				slot = slot + 1
				container:SetSlot(slot, {
					Texture = data.SpellIcon,
					StartTime = data.StartTime,
					Duration = data.TotalDuration,
					Alpha = data.IsImportant,
					Glow = iconsGlow,
					ReverseCooldown = iconsReverse,
					Color = color,
					FontScale = db.FontScale,
				})
			end

			-- Track and announce new important auras
			if data.AuraInstanceID then
				currentImportantAuras[data.AuraInstanceID] = true
				if not previousImportantAuras[data.AuraInstanceID] then
					AnnounceTTS(data.SpellName, "important")
				end
			end
		end
	end

	-- Process defensive spells
	if #defensivesData > 0 then
		for _, data in ipairs(defensivesData) do
			if iconsEnabled then
				-- prevent overflowing the container
				if slot >= container.Count then
					break
				end

				slot = slot + 1
				container:SetSlot(slot, {
					Texture = data.SpellIcon,
					StartTime = data.StartTime,
					Duration = data.TotalDuration,
					Alpha = data.IsDefensive,
					Glow = iconsGlow,
					ReverseCooldown = iconsReverse,
					Color = color,
					FontScale = db.FontScale,
				})
			end

			-- Track and announce new defensive auras
			if data.AuraInstanceID then
				currentDefensiveAuras[data.AuraInstanceID] = true
				if not previousDefensiveAuras[data.AuraInstanceID] then
					AnnounceTTS(data.SpellName, "defensive")
				end
			end
		end
	end

	return slot
end

local function OnAuraDataChanged()
	if paused then
		return
	end

	if not moduleUtil:IsModuleEnabled(moduleName.Alerts) then
		return
	end

	if inPrepRoom then
		-- don't know why it picks up garbage in the starting room
		container:ResetAllSlots()
		return
	end

	local iconsEnabled = db.Modules.AlertsModule.Icons.Enabled
	local iconsGlow = db.Modules.AlertsModule.Icons.Glow
	local iconsReverse = db.Modules.AlertsModule.Icons.ReverseCooldown
	local colorByClass = db.Modules.AlertsModule.Icons.ColorByClass
	local slot = 0
	local hasImportantAlerts = false
	local hasDefensiveAlerts = false
	local currentImportantAuras = {}
	local currentDefensiveAuras = {}

	local inInstance, instanceType = IsInInstance()

	-- Process arena watchers (for JJC) - only if in arena
	if instanceType == "arena" then
		for _, watcher in ipairs(arenaWatchers) do
			if slot >= container.Count then
				break
			end
			slot = ProcessWatcherData(
				watcher,
				slot,
				iconsEnabled,
				iconsGlow,
				iconsReverse,
				colorByClass,
				currentImportantAuras,
				currentDefensiveAuras
			)
		end
	end

	-- Process watchers for World/BG
	if instanceType == "pvp" or not inInstance then
		-- In battlegrounds, check if we should only track target/focus
		if instanceType == "pvp" then
			-- Process target watcher if exists
			if targetWatcher and targetWatcher:IsEnabled() and UnitExists("target") and units:IsEnemy("target") then
				if slot >= container.Count then
					-- Skip if full, but continue to check for TTS
					ProcessWatcherData(
						targetWatcher,
						slot,
						false,
						iconsGlow,
						iconsReverse,
						colorByClass,
						currentImportantAuras,
						currentDefensiveAuras
					)
				else
					slot = ProcessWatcherData(
						targetWatcher,
						slot,
						iconsEnabled,
						iconsGlow,
						iconsReverse,
						colorByClass,
						currentImportantAuras,
						currentDefensiveAuras
					)
				end
			end
			-- Process focus watcher if exists
			if focusWatcher and focusWatcher:IsEnabled() and UnitExists("focus") and units:IsEnemy("focus") then
				if slot >= container.Count then
					-- Skip if full, but continue to check for TTS
					ProcessWatcherData(
						focusWatcher,
						slot,
						false,
						iconsGlow,
						iconsReverse,
						colorByClass,
						currentImportantAuras,
						currentDefensiveAuras
					)
				else
					slot = ProcessWatcherData(
						focusWatcher,
						slot,
						iconsEnabled,
						iconsGlow,
						iconsReverse,
						colorByClass,
						currentImportantAuras,
						currentDefensiveAuras
					)
				end
			end
			-- Process all nameplate watchers (if not using target/focus mode)
			if targetWatcher and not targetWatcher:IsEnabled() then
				for unitToken, watcher in pairs(nameplateWatchers) do
					if slot >= container.Count then
						break
					end
					slot = ProcessWatcherData(
						watcher,
						slot,
						iconsEnabled,
						iconsGlow,
						iconsReverse,
						colorByClass,
						currentImportantAuras,
						currentDefensiveAuras
					)
				end
			end
		else
			-- World: process all nameplate watchers
			for unitToken, watcher in pairs(nameplateWatchers) do
				if slot >= container.Count then
					break
				end
				slot = ProcessWatcherData(
					watcher,
					slot,
					iconsEnabled,
					iconsGlow,
					iconsReverse,
					colorByClass,
					currentImportantAuras,
					currentDefensiveAuras
				)
			end
		end
	end

	-- Check if we have alerts for sound playback
	hasImportantAlerts = next(currentImportantAuras) ~= nil
	hasDefensiveAlerts = next(currentDefensiveAuras) ~= nil

	-- Play sound only when transitioning from no alerts to having alerts for each type
	if hasImportantAlerts and not hadImportantAlerts then
		PlaySound("important")
	end

	if hasDefensiveAlerts and not hadDefensiveAlerts then
		PlaySound("defensive")
	end

	hadImportantAlerts = hasImportantAlerts
	hadDefensiveAlerts = hasDefensiveAlerts

	-- Update previous aura tracking for next cycle
	previousImportantAuras = currentImportantAuras
	previousDefensiveAuras = currentDefensiveAuras

	-- If icons are disabled, keep sounds/TTS logic but don't show anything.
	if not iconsEnabled then
		container:ResetAllSlots()
		return
	end

	-- advance forward by 1 for clearing
	if slot > 0 then
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

local function ScheduleAuraDataUpdate()
	if pendingAuraUpdate then
		return
	end
	pendingAuraUpdate = true
	C_Timer.After(0, function()
		pendingAuraUpdate = false
		OnAuraDataChanged()
	end)
end

local function OnMatchStateChanged()
	local matchState = C_PvP.GetActiveMatchState()

	inPrepRoom = matchState == Enum.PvPMatchState.StartUp

	if not inPrepRoom then
		return
	end

	for _, watcher in ipairs(arenaWatchers) do
		watcher:ClearState(true)
	end

	for unitToken, watcher in pairs(nameplateWatchers) do
		if watcher then
			watcher:ClearState(true)
		end
	end

	if targetWatcher then
		targetWatcher:ClearState(true)
	end

	if focusWatcher then
		focusWatcher:ClearState(true)
	end

	container:ResetAllSlots()
	hadImportantAlerts = false
	hadDefensiveAlerts = false
	previousImportantAuras = {}
	previousDefensiveAuras = {}
end

local function RefreshTestAlerts()
	if not db.Modules.AlertsModule.Icons.Enabled then
		container:ResetAllSlots()
		return
	end

	local testAlertSpellIds = {
		190319, -- Combustion
		121471, -- Shadow Blades
		107574, -- Avatar
	}

	-- Test class colors for demo purposes
	local testClassColors = {
		"MAGE",
		"ROGUE",
		"WARRIOR",
	}

	local count = math.min(#testAlertSpellIds, container.Count or #testAlertSpellIds)
	local now = GetTime()
	local colorByClass = db.Modules.AlertsModule.Icons.ColorByClass
	local iconsGlow = db.Modules.AlertsModule.Icons.Glow

	for i = 1, count do
		local spellId = testAlertSpellIds[i]
		local tex = spellCache:GetSpellTexture(spellId)

		if tex then
			local duration = 12 + (i - 1) * 3
			local startTime = now - (i - 1) * 1.25

			local glowColor = nil
			if colorByClass and testClassColors[i] then
				local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[testClassColors[i]]
				if classColor then
					glowColor = { r = classColor.r, g = classColor.g, b = classColor.b, a = 1 }
				end
			end

			container:SetSlot(i, {
				Texture = tex,
				StartTime = startTime,
				Duration = duration,
				Alpha = true,
				Glow = iconsGlow,
				ReverseCooldown = db.Modules.AlertsModule.Icons.ReverseCooldown,
				Color = glowColor,
				FontScale = db.FontScale,
			})
		end
	end

	-- Clear any unused slots beyond test alert count
	for i = count + 1, container.Count do
		container:SetSlotUnused(i)
	end
end

local function OnNamePlateAdded(unitToken)
	-- Clean up any existing watcher for this unit token
	if nameplateWatchers[unitToken] then
		nameplateWatchers[unitToken]:Dispose()
		nameplateWatchers[unitToken] = nil
	end

	-- Only track enemy nameplates
	if not units:IsEnemy(unitToken) then
		return
	end

	-- Always create watcher with all types
	local watcherFilter = {
		CC = true,
		Defensive = true,
		Important = true,
	}

	local watcher = unitWatcher:New(unitToken, nil, watcherFilter)
	watcher:RegisterCallback(OnAuraDataChanged)
	nameplateWatchers[unitToken] = watcher

	-- Initial update
	ScheduleAuraDataUpdate()
end

local function OnNamePlateRemoved(unitToken)
	if nameplateWatchers[unitToken] then
		nameplateWatchers[unitToken]:Dispose()
		nameplateWatchers[unitToken] = nil
		ScheduleAuraDataUpdate()
	end
end

local function ClearNamePlateWatchers()
	for unitToken, watcher in pairs(nameplateWatchers) do
		watcher:Dispose()
		nameplateWatchers[unitToken] = nil
	end
end

local function DisableTargetFocusWatchers()
	if targetWatcher then
		targetWatcher:Disable()
	end

	if focusWatcher then
		focusWatcher:Disable()
	end
end

local function EnableTargetFocusWatchers()
	if targetWatcher then
		targetWatcher:Enable()
	end

	if focusWatcher then
		focusWatcher:Enable()
	end
end

local function RebuildNameplateWatchers()
	-- Build a set of currently active enemy unit tokens
	local activeTokens = {}
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken
		if unitToken and units:IsEnemy(unitToken) then
			activeTokens[unitToken] = true
		end
	end

	-- Remove watchers for tokens that are no longer active
	for unitToken, watcher in pairs(nameplateWatchers) do
		if not activeTokens[unitToken] then
			watcher:Dispose()
			nameplateWatchers[unitToken] = nil
		end
	end

	-- Add watchers for tokens we don't already track
	for unitToken in pairs(activeTokens) do
		if not nameplateWatchers[unitToken] then
			OnNamePlateAdded(unitToken)
		end
	end
end

local function InitTargetFocusWatchers()
	-- Create watchers for target and focus
	local watcherFilter = {
		CC = true,
		Defensive = true,
		Important = true,
	}

	targetWatcher = unitWatcher:New("target", { "PLAYER_TARGET_CHANGED" }, watcherFilter)
	targetWatcher:RegisterCallback(OnAuraDataChanged)

	focusWatcher = unitWatcher:New("focus", { "PLAYER_FOCUS_CHANGED" }, watcherFilter)
	focusWatcher:RegisterCallback(OnAuraDataChanged)
end

local function InitArenaWatchers()
	if not db or not db.Modules or not db.Modules.AlertsModule then
		return
	end

	-- Always create watchers with all types
	local watcherFilter = {
		CC = true,
		Defensive = true,
		Important = true,
	}

	local events = {
		"ARENA_OPPONENT_UPDATE",
	}

	arenaWatchers = {
		unitWatcher:New("arena1", events, watcherFilter),
		unitWatcher:New("arena2", events, watcherFilter),
		unitWatcher:New("arena3", events, watcherFilter),
	}

	for _, watcher in ipairs(arenaWatchers) do
		watcher:RegisterCallback(OnAuraDataChanged)
	end
end

local function DisableWatchers()
	for _, watcher in ipairs(arenaWatchers) do
		watcher:Disable()
	end

	for unitToken, watcher in pairs(nameplateWatchers) do
		watcher:Disable()
	end

	if targetWatcher then
		targetWatcher:Disable()
	end

	if focusWatcher then
		focusWatcher:Disable()
	end

	if container then
		container:ResetAllSlots()
	end
	hadImportantAlerts = false
	hadDefensiveAlerts = false
	previousImportantAuras = {}
	previousDefensiveAuras = {}
	paused = true
end

local function EnableDisable()
	local options = db.Modules.AlertsModule
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Alerts)

	if not moduleEnabled then
		DisableWatchers()
		return
	end

	local inInstance, instanceType = IsInInstance()

	if instanceType == "arena" then
		-- Enable arena watchers only if in arena
		for _, watcher in ipairs(arenaWatchers) do
			watcher:Enable()
		end
	else
		-- Disable arena watchers if not in arena
		for _, watcher in ipairs(arenaWatchers) do
			watcher:Disable()
		end
	end

	-- Enable watchers (for World/BG)
	if instanceType == "pvp" or not inInstance then
		if instanceType == "pvp" then
			-- In battlegrounds, use target/focus mode
			EnableTargetFocusWatchers()
			-- Also use nameplate watchers as fallback
			RebuildNameplateWatchers()
		else
			-- World: use nameplate watchers
			RebuildNameplateWatchers()
			-- disable target/focus mode
			DisableTargetFocusWatchers()
		end
	else
		-- Disable all watchers if not in world/bg/arena
		ClearNamePlateWatchers()
		DisableTargetFocusWatchers()
	end

	ScheduleAuraDataUpdate()
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
	ScheduleAuraDataUpdate()
end

function M:StartTesting()
	testModeActive = true
	Pause()
	M:Refresh()

	if not container then
		return
	end

	container.Frame:EnableMouse(true)
	container.Frame:SetMovable(true)
end

function M:StopTesting()
	testModeActive = false

	if not container then
		return
	end

	container:ResetAllSlots()
	Resume()

	container.Frame:EnableMouse(false)
	container.Frame:SetMovable(false)
end

function M:Refresh()
	local options = db.Modules.AlertsModule
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Alerts)

	-- Update cached TTS values
	cachedVoiceID = (options.TTS and options.TTS.VoiceID) or C_TTSSettings.GetVoiceOptionID(0)
	cachedTTSVolume = options.TTS and options.TTS.Volume or 100
	cachedTTSSpeechRate = options.TTS and options.TTS.SpeechRate or 0
	cachedTTSImportantEnabled = options.TTS and options.TTS.Important and options.TTS.Important.Enabled or false
	cachedTTSDefensiveEnabled = options.TTS and options.TTS.Defensive and options.TTS.Defensive.Enabled or false

	EnableDisable()

	container.Frame:ClearAllPoints()
	container.Frame:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	container:SetIconSize(options.Icons.Size)
	container:SetSpacing(db.IconSpacing or 2)

	if testModeActive then
		RefreshTestAlerts()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	local options = db.Modules.AlertsModule
	local count = 8
	local size = options.Icons.Size

	-- Initialize cached TTS values
	cachedVoiceID = (options.TTS and options.TTS.VoiceID) or C_TTSSettings.GetVoiceOptionID(0)
	cachedTTSVolume = options.TTS and options.TTS.Volume or 100
	cachedTTSSpeechRate = options.TTS and options.TTS.SpeechRate or 0
	cachedTTSImportantEnabled = options.TTS and options.TTS.Important and options.TTS.Important.Enabled or false
	cachedTTSDefensiveEnabled = options.TTS and options.TTS.Defensive and options.TTS.Defensive.Enabled or false

	container = iconSlotContainer:New(UIParent, count, size, db.IconSpacing or 2, "Alerts")
	container.Frame:SetIgnoreParentScale(true)

	local initialRelativeTo = _G[options.RelativeTo] or UIParent
	container.Frame:SetPoint(
		options.Point,
		initialRelativeTo,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)
	container.Frame:SetFrameStrata("HIGH")
	container.Frame:SetFrameLevel((initialRelativeTo:GetFrameLevel() or 0) + 5)
	container.Frame:EnableMouse(false)
	container.Frame:SetMovable(false)
	container.Frame:SetClampedToScreen(true)
	container.Frame:RegisterForDrag("LeftButton")
	container.Frame:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	container.Frame:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		options.Point = point
		options.RelativePoint = relativePoint
		options.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		options.Offset.X = x
		options.Offset.Y = y
	end)
	container.Frame:Show()

	InitArenaWatchers()
	InitTargetFocusWatchers()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	eventsFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "PVP_MATCH_STATE_CHANGED" then
			OnMatchStateChanged()
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Alerts)
			if moduleEnabled then
				local inInstance, instanceType = IsInInstance()
				if instanceType == "pvp" or not inInstance then
					OnNamePlateAdded(unitToken)
				end
			end
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		elseif event == "ZONE_CHANGED_NEW_AREA" then
			EnableDisable()
		end
	end)

	EnableDisable()
end
