---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
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
local previousDefensiveAuras = {}
-- Reused each OnAuraDataChanged call to avoid per-frame allocation
---@type table<number, boolean>
local currentDefensiveAuras = {}
-- Scratch table reused for every SetSlot call in ProcessWatcherData
local slotOptionsScratch = {}
-- Scratch table reused for the per-arena-token important stack in ProcessImportantArena
local importantOptionsScratch = {}
-- Reusable AuraInstanceID set: a unit's defensives (shown on the defensives bar), excluded from
-- its important stack so a both-important-and-defensive spell isn't drawn on both bars.
local importantSkipScratch = {}
-- Scratch table reused for every class-color lookup in ProcessWatcherData
local colorScratch = { r = 0, g = 0, b = 0, a = 1 }

local hadDefensiveAlerts = false
local pendingAuraUpdate = false

local cachedVoiceID
local cachedTTSVolume
local cachedTTSSpeechRate
local cachedTTSDefensiveEnabled
-- Defensives bar: enemy defensive cooldowns (the only category alerts shows besides important).
---@type IconSlotContainer
local container
-- Dedicated arena-only bar: one fixed slot per arena token (arena1/2/3). Each slot stacks that
-- opponent's helpful buffs and lets IsSpellImportant decide which (if any) shows.
---@type IconSlotContainer
local importantContainer
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
	if spellType == "defensive" then
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
	if spellType == "defensive" and cachedTTSDefensiveEnabled then
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

-- Fills the defensives bar from a watcher's defensive auras. `defSlot` is the running slot index
-- across all watchers processed this frame; returns the updated index.
local function ProcessWatcherData(watcher, defSlot, iconsEnabled, iconsGlow, iconsReverse, colorByClass, includeDefensives, showTooltips)
	local unit = watcher:GetUnit()

	-- when units go stealth, we can't get their aura data anymore
	if not unit or not UnitExists(unit) then
		return defSlot
	end

	local defensivesData = watcher:GetDefensiveState()

	if #defensivesData == 0 then
		return defSlot
	end

	local color = nil

	-- Get class color if the option is enabled
	if colorByClass then
		local _, class = UnitClass(unit)
		if class then
			local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
			if classColor then
				colorScratch.r = classColor.r
				colorScratch.g = classColor.g
				colorScratch.b = classColor.b
				colorScratch.a = 1
				color = colorScratch
			end
		end
	end

	local fontScale = db.FontScale

	-- Process defensive spells
	for _, data in ipairs(defensivesData) do
		if includeDefensives and iconsEnabled and defSlot < container.Count then
			defSlot = defSlot + 1
			slotOptionsScratch.Texture = data.SpellIcon
			slotOptionsScratch.DurationObject = data.DurationObject
			slotOptionsScratch.Alpha = data.IsDefensive
			slotOptionsScratch.Glow = iconsGlow
			slotOptionsScratch.ReverseCooldown = iconsReverse
			slotOptionsScratch.Color = color
			slotOptionsScratch.FontScale = fontScale
			slotOptionsScratch.SpellId = showTooltips and data.SpellId or nil
			container:SetSlot(defSlot, slotOptionsScratch)
		end

		-- Track and announce new defensive auras
		if data.AuraInstanceID then
			currentDefensiveAuras[data.AuraInstanceID] = true
			if not previousDefensiveAuras[data.AuraInstanceID] then
				AnnounceTTS(data.SpellName, "defensive")
			end
		end
	end

	return defSlot
end

-- Arena-only: stack each opponent's helpful buffs onto their dedicated slot (arena1 -> slot 1,
-- etc.) so the important one shows. Existing-but-buffless opponents keep their slot reserved so
-- the per-token columns stay fixed; absent opponents (e.g. 2v2) free their trailing slot.
local function ProcessImportantArena(iconsGlow, iconsReverse, colorByClass, includeDefensives)
	for i = 1, importantContainer.Count do
		local watcher = arenaWatchers[i]
		local unit = watcher and watcher:GetUnit()

		if unit and UnitExists(unit) then
			local color = nil
			if colorByClass then
				local _, class = UnitClass(unit)
				local classColor = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
				if classColor then
					colorScratch.r = classColor.r
					colorScratch.g = classColor.g
					colorScratch.b = classColor.b
					colorScratch.a = 1
					color = colorScratch
				end
			end

			-- When the defensives bar is showing this unit's defensives, exclude them from the
			-- important stack so a both-important-and-defensive spell isn't drawn on both bars.
			local skipIds = nil
			if includeDefensives then
				wipe(importantSkipScratch)
				for _, d in ipairs(watcher:GetDefensiveState()) do
					if d.AuraInstanceID then
						importantSkipScratch[d.AuraInstanceID] = true
					end
				end
				skipIds = importantSkipScratch
			end

			importantOptionsScratch.Glow = iconsGlow
			importantOptionsScratch.ReverseCooldown = iconsReverse
			importantOptionsScratch.Color = color
			importantOptionsScratch.FontScale = db.FontScale
			importantContainer:StackImportantBuffs(i, watcher:GetBuffState(), importantOptionsScratch, true, skipIds)
		else
			importantContainer:SetSlotUnused(i)
		end
	end
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
		if importantContainer then
			importantContainer:ResetAllSlots()
		end
		return
	end

	local iconsEnabled = db.Modules.AlertsModule.Icons.Enabled
	local iconsGlow = db.Modules.AlertsModule.Icons.Glow
	local iconsReverse = db.Modules.AlertsModule.Icons.ReverseCooldown
	local colorByClass = db.Modules.AlertsModule.Icons.ColorByClass
	local importantEnabled = db.Modules.AlertsModule.Important and db.Modules.AlertsModule.Important.Enabled
	local includeDefensives = db.Modules.AlertsModule.IncludeDefensives
	local showTooltips = db.Modules.AlertsModule.ShowTooltips ~= false
	local defSlot = 0
	local hasDefensiveAlerts
	local inInstance, instanceType = IsInInstance()

	wipe(currentDefensiveAuras)

	-- Process arena watchers
	if instanceType == "arena" then
		for _, watcher in ipairs(arenaWatchers) do
			defSlot = ProcessWatcherData(
				watcher, defSlot, iconsEnabled, iconsGlow, iconsReverse, colorByClass, includeDefensives, showTooltips
			)
		end
	end

	-- Process watchers for World/BG
	if instanceType == "pvp" or not inInstance then
		local targetFocusOnly = db.Modules.AlertsModule.TargetFocusOnly
		if targetFocusOnly then
			-- Process target/focus watchers
			for _, pair in ipairs({ { targetWatcher, "target" }, { focusWatcher, "focus" } }) do
				local watcher, unit = pair[1], pair[2]
				if watcher and UnitExists(unit) and units:IsEnemy(unit) then
					defSlot = ProcessWatcherData(
						watcher, defSlot, iconsEnabled, iconsGlow, iconsReverse, colorByClass, includeDefensives, showTooltips
					)
				end
			end
		else
			-- Process nameplate watchers
			for _, watcher in pairs(nameplateWatchers) do
				defSlot = ProcessWatcherData(
					watcher, defSlot, iconsEnabled, iconsGlow, iconsReverse, colorByClass, includeDefensives, showTooltips
				)
			end
		end
	end

	-- Important arena bar: independent of the defensives bar above and arena-only.
	if importantContainer then
		if iconsEnabled and importantEnabled and instanceType == "arena" then
			ProcessImportantArena(iconsGlow, iconsReverse, colorByClass, includeDefensives)
		else
			importantContainer:ResetAllSlots()
		end
	end

	-- Check if we have alerts for sound playback
	hasDefensiveAlerts = next(currentDefensiveAuras) ~= nil

	-- Play sound only when transitioning from no alerts to having alerts
	if hasDefensiveAlerts and not hadDefensiveAlerts then
		PlaySound("defensive")
	end

	hadDefensiveAlerts = hasDefensiveAlerts

	-- Swap buffers: previous gets this frame's data and current gets the old previous table
	-- (which will be wiped at the top of the next call)
	previousDefensiveAuras, currentDefensiveAuras = currentDefensiveAuras, previousDefensiveAuras

	-- If icons are disabled, keep sounds/TTS logic but don't show anything.
	if not iconsEnabled then
		container:ResetAllSlots()
		return
	end

	-- Clear any defensive slots above what we used
	if defSlot == 0 then
		container:ResetAllSlots()
	else
		for i = defSlot + 1, container.Count do
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

	for _, watcher in pairs(nameplateWatchers) do
		watcher:ClearState(true)
	end

	if targetWatcher then
		targetWatcher:ClearState(true)
	end

	if focusWatcher then
		focusWatcher:ClearState(true)
	end

	container:ResetAllSlots()
	if importantContainer then
		importantContainer:ResetAllSlots()
	end
	hadDefensiveAlerts = false
	previousDefensiveAuras = {}
end

local function RefreshTestAlerts()
	if not db.Modules.AlertsModule.Icons.Enabled then
		container:ResetAllSlots()
		if importantContainer then
			importantContainer:ResetAllSlots()
		end
		return
	end

	local includeDefensives = db.Modules.AlertsModule.IncludeDefensives

	local testDefensiveSpells = {
		{ spellId = 47788, class = "PRIEST" }, -- Guardian Spirit
		{ spellId = 45438, class = "MAGE" }, -- Ice Block
		{ spellId = 104773, class = "WARLOCK" }, -- Unending Resolve
	}

	local now = GetTime()
	local colorByClass = db.Modules.AlertsModule.Icons.ColorByClass
	local iconsGlow = db.Modules.AlertsModule.Icons.Glow
	local showTooltips = db.Modules.AlertsModule.ShowTooltips ~= false

	-- Defensives bar test icons
	local defSlot = 0
	if includeDefensives then
		local stepIndex = 0
		for _, entry in ipairs(testDefensiveSpells) do
			local tex = C_Spell.GetSpellTexture(entry.spellId)
			if tex and defSlot < container.Count then
				local glowColor = nil
				if colorByClass and entry.class then
					local classColor = RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
					if classColor then
						glowColor = { r = classColor.r, g = classColor.g, b = classColor.b, a = 1 }
					end
				end

				defSlot = defSlot + 1
				container:SetSlot(defSlot, {
					Texture = tex,
					DurationObject = wowEx:CreateDuration(now - stepIndex * 1.25, 12 + stepIndex * 3),
					Alpha = true,
					Glow = iconsGlow,
					ReverseCooldown = db.Modules.AlertsModule.Icons.ReverseCooldown,
					Color = glowColor,
					FontScale = db.FontScale,
					SpellId = showTooltips and entry.spellId or nil,
				})
				stepIndex = stepIndex + 1
			end
		end
	end

	-- Clear any unused slots beyond test defensive count
	for i = defSlot + 1, container.Count do
		container:SetSlotUnused(i)
	end

	-- Important arena bar test icons: one per slot (these are shown directly since the test
	-- spells aren't necessarily flagged important by the game).
	if importantContainer then
		local importantEnabled = db.Modules.AlertsModule.Important and db.Modules.AlertsModule.Important.Enabled
		if importantEnabled then
			local testImportantSpellIds = { 190319, 121471, 377362 } -- Combustion, Shadow Blades, precog
			for i = 1, importantContainer.Count do
				local spellId = testImportantSpellIds[((i - 1) % #testImportantSpellIds) + 1]
				local tex = C_Spell.GetSpellTexture(spellId)
				if tex then
					importantContainer:SetSlot(i, {
						Texture = tex,
						DurationObject = wowEx:CreateDuration(now - (i - 1) * 1.25, 15 + (i - 1) * 3),
						Alpha = true,
						Glow = iconsGlow,
						ReverseCooldown = db.Modules.AlertsModule.Icons.ReverseCooldown,
						FontScale = db.FontScale,
						SpellId = showTooltips and spellId or nil,
					})
				end
			end
		else
			importantContainer:ResetAllSlots()
		end
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

	---@type AuraTypeFilter
	local watcherFilter = {
		CC = true,
		Defensives = true,
	}

	local watcher = unitWatcher:New(unitToken, nil, watcherFilter)
	watcher:RegisterCallback(ScheduleAuraDataUpdate)
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
	---@type AuraTypeFilter
	local watcherFilter = {
		CC = true,
		Defensives = true,
	}

	targetWatcher = unitWatcher:New("target", { "PLAYER_TARGET_CHANGED" }, watcherFilter)
	targetWatcher:RegisterCallback(ScheduleAuraDataUpdate)

	focusWatcher = unitWatcher:New("focus", { "PLAYER_FOCUS_CHANGED" }, watcherFilter)
	focusWatcher:RegisterCallback(ScheduleAuraDataUpdate)
end

local function InitArenaWatchers()
	-- Always create watchers with all types. Buffs are collected so the dedicated arena important
	-- bar can stack them and surface the important one via IsSpellImportant.
	local watcherFilter = {
		CC = true,
		Defensives = true,
		Buffs = true,
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
		watcher:RegisterCallback(ScheduleAuraDataUpdate)
	end
end

local function DisableWatchers()
	for _, watcher in ipairs(arenaWatchers) do
		watcher:Disable()
	end

	for _, watcher in pairs(nameplateWatchers) do
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
	if importantContainer then
		importantContainer:ResetAllSlots()
	end
	hadDefensiveAlerts = false
	previousDefensiveAuras = {}
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
		local targetFocusOnly = options.TargetFocusOnly
		if targetFocusOnly then
			EnableTargetFocusWatchers()
			ClearNamePlateWatchers()
		else
			DisableTargetFocusWatchers()
			RebuildNameplateWatchers()
		end
	else
		-- Disable nameplate and target/focus watchers if not in world/bg
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

	if importantContainer and importantContainer.Frame:IsShown() then
		importantContainer.Frame:EnableMouse(true)
		importantContainer.Frame:SetMovable(true)
	end
end

function M:StopTesting()
	testModeActive = false

	if not container then
		return
	end

	container:ResetAllSlots()
	if importantContainer then
		importantContainer:ResetAllSlots()
	end
	Resume()

	container.Frame:EnableMouse(false)
	container.Frame:SetMovable(false)

	if importantContainer then
		importantContainer.Frame:EnableMouse(false)
		importantContainer.Frame:SetMovable(false)
	end
end

function M:Refresh()
	local options = db.Modules.AlertsModule

	cachedVoiceID = wowEx:ResolveVoiceID(options.TTS and options.TTS.VoiceID)
	cachedTTSVolume = options.TTS and options.TTS.Volume or 100
	cachedTTSSpeechRate = options.TTS and options.TTS.SpeechRate or 0
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
	container:SetCount(options.Icons.MaxIcons or 8)

	if importantContainer then
		local importantOptions = options.Important
		local importantVisible = importantOptions and importantOptions.Enabled
		local impAnchor = importantOptions or options
		importantContainer.Frame:ClearAllPoints()
		importantContainer.Frame:SetPoint(
			impAnchor.Point,
			_G[impAnchor.RelativeTo] or UIParent,
			impAnchor.RelativePoint,
			impAnchor.Offset.X,
			impAnchor.Offset.Y
		)

		importantContainer:SetIconSize(options.Icons.Size)
		importantContainer:SetSpacing(db.IconSpacing or 2)
		-- One fixed slot per arena token.
		importantContainer:SetCount(3)

		if importantVisible then
			importantContainer.Frame:Show()
			local moveable = testModeActive and moduleUtil:IsModuleEnabled(moduleName.Alerts)
			importantContainer.Frame:EnableMouse(moveable)
			importantContainer.Frame:SetMovable(moveable)
		else
			importantContainer:ResetAllSlots()
			importantContainer.Frame:Hide()
			importantContainer.Frame:EnableMouse(false)
			importantContainer.Frame:SetMovable(false)
		end
	end

	if testModeActive and moduleUtil:IsModuleEnabled(moduleName.Alerts) then
		RefreshTestAlerts()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	local options = db.Modules.AlertsModule
	local count = options.Icons.MaxIcons or 8
	local size = options.Icons.Size

	cachedVoiceID = wowEx:ResolveVoiceID(options.TTS and options.TTS.VoiceID)
	cachedTTSVolume = options.TTS and options.TTS.Volume or 100
	cachedTTSSpeechRate = options.TTS and options.TTS.SpeechRate or 0
	cachedTTSDefensiveEnabled = options.TTS and options.TTS.Defensive and options.TTS.Defensive.Enabled or false

	container = iconSlotContainer:New(UIParent, count, size, db.IconSpacing or 2, "Alerts", nil, "Alerts")

	local initialRelativeTo = _G[options.RelativeTo] or UIParent
	container.Frame:SetPoint(
		options.Point,
		initialRelativeTo,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)
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

	-- Dedicated arena important bar: 3 fixed slots (one per arena token).
	importantContainer = iconSlotContainer:New(UIParent, 3, size, db.IconSpacing or 2, "Alerts", nil, "Alerts")

	local impAnchor = options.Important or options
	local impInitialRelativeTo = _G[impAnchor.RelativeTo] or UIParent
	importantContainer.Frame:SetPoint(
		impAnchor.Point,
		impInitialRelativeTo,
		impAnchor.RelativePoint,
		impAnchor.Offset.X,
		impAnchor.Offset.Y
	)
	importantContainer.Frame:SetFrameLevel((impInitialRelativeTo:GetFrameLevel() or 0) + 5)
	importantContainer.Frame:EnableMouse(false)
	importantContainer.Frame:SetMovable(false)
	importantContainer.Frame:SetClampedToScreen(true)
	importantContainer.Frame:RegisterForDrag("LeftButton")
	importantContainer.Frame:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	importantContainer.Frame:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		impAnchor.Point = point
		impAnchor.RelativePoint = relativePoint
		impAnchor.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		impAnchor.Offset.X = x
		impAnchor.Offset.Y = y
	end)

	if options.Important and options.Important.Enabled then
		importantContainer.Frame:Show()
	else
		importantContainer.Frame:Hide()
	end

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
