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
---@type table<number, boolean>
local previousImportantAuras = {}
-- Reused each OnAuraDataChanged call to avoid per-frame allocation
---@type table<number, boolean>
local currentDefensiveAuras = {}
---@type table<number, boolean>
local currentImportantAuras = {}
-- Scratch table reused for every SetSlot call in ProcessWatcherData
local slotOptionsScratch = {}
-- Scratch table reused for every important-buff SetSlot in ProcessImportantForUnit
local importantOptionsScratch = {}
-- Reusable AuraInstanceID set: a unit's defensives (shown on the defensives bar), excluded from
-- the important bar so a both-important-and-defensive spell isn't drawn on both bars.
local importantSkipScratch = {}
-- Scratch table reused for every class-color lookup
local colorScratch = { r = 0, g = 0, b = 0, a = 1 }
-- Reused list of the active enemy watchers for the current mode, rebuilt each update.
local activeWatchersScratch = {}

-- AurasFrames whose RefreshAuras we've already hooked, so important buffs (read from Blizzard's
-- nameplate buff list) refresh when the game updates them. hooksecurefunc can't be undone, so we
-- track hooked frames to avoid stacking duplicate hooks on Blizzard's pooled nameplate frames.
local hookedAuraFrames = {}

-- Per-iteration context for the hoisted PlaceImportantBuff callback (avoids a per-call closure on
-- the aura hot path). The constant-per-frame fields are set in OnAuraDataChanged; the per-unit
-- fields (Unit/Color/Skip) are set by ProcessImportantForUnit.
local impCtxUnit, impCtxColor, impCtxSkip, impCtxGlow, impCtxReverse, impCtxShowTooltips, impCtxDraw
-- Target container for important icons (the main bar when combined, importantContainer when split).
local impCtxContainer
-- Running slot cursor across all units processed this frame for the important bar.
local impCtxSlot = 0

local hadDefensiveAlerts = false
local hadImportantAlerts = false
local pendingAuraUpdate = false

local cachedVoiceID
local cachedTTSVolume
local cachedTTSSpeechRate
local cachedTTSDefensiveEnabled
local cachedTTSImportantEnabled
-- Main alerts bar: enemy defensive cooldowns, plus important spells when combined.
---@type IconSlotContainer
local container
-- Dedicated, separately-movable bar for important enemy buffs (e.g. offensive cooldowns, precog),
-- used only in split mode. Filled from Blizzard's nameplate buff lists across every active enemy.
---@type IconSlotContainer
local importantContainer
---@type table<string, Watcher>
local nameplateWatchers = {}

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

-- Returns the unit's class color (in the shared colorScratch) when colorByClass is on, else nil.
local function ClassColorFor(unit, colorByClass)
	if not colorByClass then
		return nil
	end
	local _, class = UnitClass(unit)
	local classColor = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if not classColor then
		return nil
	end
	colorScratch.r = classColor.r
	colorScratch.g = classColor.g
	colorScratch.b = classColor.b
	colorScratch.a = 1
	return colorScratch
end

-- Fills the main bar from a watcher's defensive auras. `defSlot` is the running slot index across
-- all watchers processed this frame; returns the updated index.
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

	local color = ClassColorFor(unit, colorByClass)

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

-- Returns Blizzard's nameplate buff list for a unit (the buffs the game chooses to display, i.e.
-- the important ones), or nil if the unit has no visible/usable nameplate.
local function GetNameplateBuffList(unit)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.buffList and af.buffList.Iterate and not (af.IsForbidden and af:IsForbidden()) then
		return af.buffList
	end
	return nil
end

-- Hoisted buffList:Iterate callback. Tracks each important buff for sound/TTS (always) and draws it
-- onto impCtxContainer when impCtxDraw is set. Reads its context from the impCtx* upvalues.
local function PlaceImportantBuff(auraInstanceID)
	if impCtxSkip and impCtxSkip[auraInstanceID] then
		return
	end
	local unit = impCtxUnit
	local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
	if not aura then
		return
	end

	-- Track for sound/TTS independently of drawing, so alerts fire even with icons/bar off.
	-- AuraInstanceID is not a secret value, so it's a reliable key for the new-aura transition.
	currentImportantAuras[auraInstanceID] = true
	if not previousImportantAuras[auraInstanceID] then
		-- aura.name may be a secret value post-12.0.7; AnnounceTTS wraps SpeakText in pcall so a
		-- non-speakable name degrades to no announcement rather than erroring.
		AnnounceTTS(aura.name, "important")
	end

	if not impCtxDraw or impCtxSlot >= impCtxContainer.Count then
		return
	end
	impCtxSlot = impCtxSlot + 1
	importantOptionsScratch.Texture = aura.icon
	importantOptionsScratch.DurationObject = C_UnitAuras.GetAuraDuration(unit, auraInstanceID)
	importantOptionsScratch.Alpha = true
	importantOptionsScratch.Glow = impCtxGlow
	importantOptionsScratch.ReverseCooldown = impCtxReverse
	importantOptionsScratch.Color = impCtxColor
	importantOptionsScratch.FontScale = db.FontScale
	importantOptionsScratch.SpellId = impCtxShowTooltips and aura.spellId or nil
	impCtxContainer:SetSlot(impCtxSlot, importantOptionsScratch)
end

-- Scans a unit's important nameplate buffs, tracking them for sound/TTS and (when drawing) appending
-- them to the important target. A buff already shown as one of this unit's defensives is skipped so
-- a both-important-and-defensive spell isn't drawn twice.
local function ProcessImportantForUnit(watcher, colorByClass, includeDefensives)
	local unit = watcher:GetUnit()
	if not unit or not UnitExists(unit) then
		return
	end

	local buffList = GetNameplateBuffList(unit)
	if not buffList then
		return
	end

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

	impCtxUnit = unit
	impCtxColor = ClassColorFor(unit, colorByClass)
	impCtxSkip = skipIds
	buffList:Iterate(PlaceImportantBuff)
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
	local importantSound = db.Modules.AlertsModule.Sound.Important and db.Modules.AlertsModule.Sound.Important.Enabled
	local includeDefensives = db.Modules.AlertsModule.IncludeDefensives
	local showTooltips = db.Modules.AlertsModule.ShowTooltips ~= false
	local defSlot = 0
	local hasDefensiveAlerts
	local inInstance, instanceType = IsInInstance()

	-- Important spells can share the main alerts bar (combined, the default) or sit on their own
	-- separate bar (split). Draw important only when icons are on, but still scan whenever the bar,
	-- its sound, or its TTS is enabled so sound/TTS fire even with icons or the bar hidden.
	local splitBars = db.Modules.AlertsModule.SplitBars
	local importantDraw = iconsEnabled and importantEnabled
	local importantNeedsScan = importantEnabled or importantSound or cachedTTSImportantEnabled
	impCtxDraw = importantDraw
	impCtxGlow = iconsGlow
	impCtxReverse = iconsReverse
	impCtxShowTooltips = showTooltips
	-- Split important draws onto its own bar; combined important appends to the main alerts bar.
	impCtxContainer = (splitBars and importantContainer) or container
	impCtxSlot = 0

	wipe(currentDefensiveAuras)
	wipe(currentImportantAuras)

	-- Collect the active enemy watchers for the current mode. Arena, battlegrounds, and the open
	-- world all read enemy nameplate watchers; other instance types show nothing.
	local activeWatchers = activeWatchersScratch
	wipe(activeWatchers)
	if instanceType == "arena" or instanceType == "pvp" or not inInstance then
		for _, watcher in pairs(nameplateWatchers) do
			activeWatchers[#activeWatchers + 1] = watcher
		end
	end

	-- Defensives fill the main bar.
	for i = 1, #activeWatchers do
		defSlot = ProcessWatcherData(
			activeWatchers[i], defSlot, iconsEnabled, iconsGlow, iconsReverse, colorByClass, includeDefensives, showTooltips
		)
	end

	-- Important spells: when combined, continue in the main bar after the defensives; when split,
	-- start fresh on the dedicated important bar.
	if importantNeedsScan then
		impCtxSlot = splitBars and 0 or defSlot
		for i = 1, #activeWatchers do
			ProcessImportantForUnit(activeWatchers[i], colorByClass, includeDefensives)
		end
		if not splitBars then
			defSlot = impCtxSlot
		end
	end

	-- Dedicated important bar: clear leftover slots when split, otherwise hide it (combined / off).
	if importantContainer then
		if splitBars and importantDraw then
			for i = impCtxSlot + 1, importantContainer.Count do
				importantContainer:SetSlotUnused(i)
			end
		else
			importantContainer:ResetAllSlots()
		end
	end

	-- Check if we have alerts for sound playback
	hasDefensiveAlerts = next(currentDefensiveAuras) ~= nil
	local hasImportantAlerts = next(currentImportantAuras) ~= nil

	-- Play sound only when transitioning from no alerts to having alerts (per type)
	if hasImportantAlerts and not hadImportantAlerts then
		PlaySound("important")
	end

	if hasDefensiveAlerts and not hadDefensiveAlerts then
		PlaySound("defensive")
	end

	hadImportantAlerts = hasImportantAlerts
	hadDefensiveAlerts = hasDefensiveAlerts

	-- Swap buffers: previous gets this frame's data and current gets the old previous table
	-- (which will be wiped at the top of the next call)
	previousDefensiveAuras, currentDefensiveAuras = currentDefensiveAuras, previousDefensiveAuras
	previousImportantAuras, currentImportantAuras = currentImportantAuras, previousImportantAuras

	-- If icons are disabled, keep sounds/TTS logic but don't show anything.
	if not iconsEnabled then
		container:ResetAllSlots()
		return
	end

	-- Clear any main-bar slots above what we used (defensives, plus combined important)
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

	for _, watcher in pairs(nameplateWatchers) do
		watcher:ClearState(true)
	end

	container:ResetAllSlots()
	if importantContainer then
		importantContainer:ResetAllSlots()
	end
	hadDefensiveAlerts = false
	hadImportantAlerts = false
	previousDefensiveAuras = {}
	previousImportantAuras = {}
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

	-- Important test icons (each test spell shown once). Split -> dedicated bar; combined -> main bar.
	local splitBars = db.Modules.AlertsModule.SplitBars
	local importantEnabled = db.Modules.AlertsModule.Important and db.Modules.AlertsModule.Important.Enabled
	local impTarget = (splitBars and importantContainer) or container
	local impSlot = splitBars and 0 or defSlot
	if importantEnabled and impTarget then
		local testImportantSpellIds = { 190319, 121471, 377362 } -- Combustion, Shadow Blades, precog
		for i = 1, #testImportantSpellIds do
			if impSlot >= impTarget.Count then
				break
			end
			local spellId = testImportantSpellIds[i]
			local tex = C_Spell.GetSpellTexture(spellId)
			if tex then
				impSlot = impSlot + 1
				impTarget:SetSlot(impSlot, {
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
	end

	-- Clear leftover slots on the main bar (past defensives, plus combined important).
	local mainUsed = splitBars and defSlot or impSlot
	for i = mainUsed + 1, container.Count do
		container:SetSlotUnused(i)
	end

	-- Dedicated important bar: trim leftovers when split, otherwise hide it.
	if importantContainer then
		if splitBars and importantEnabled then
			for i = impSlot + 1, importantContainer.Count do
				importantContainer:SetSlotUnused(i)
			end
		else
			importantContainer:ResetAllSlots()
		end
	end
end

-- Hooks a nameplate's RefreshAuras so the important bar (which reads Blizzard's nameplate buff
-- lists) refreshes when the game updates them. Watchers don't track buffs, so this is the only
-- signal for buff changes. Installed for every enemy nameplate; the hook is a cheap no-op when
-- nothing important-related is enabled.
local function HookNameplateAuraFrame(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.RefreshAuras and not hookedAuraFrames[af] then
		hookedAuraFrames[af] = true
		hooksecurefunc(af, "RefreshAuras", function(self)
			if paused or (self.IsForbidden and self:IsForbidden()) then
				return
			end
			if not moduleUtil:IsModuleEnabled(moduleName.Alerts) then
				return
			end
			local options = db.Modules.AlertsModule
			local importantNeeded = (options.Important and options.Important.Enabled)
				or (options.Sound.Important and options.Sound.Important.Enabled)
				or cachedTTSImportantEnabled
			if importantNeeded then
				ScheduleAuraDataUpdate()
			end
		end)
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

local function DisableWatchers()
	for _, watcher in pairs(nameplateWatchers) do
		watcher:Disable()
	end

	if container then
		container:ResetAllSlots()
	end
	if importantContainer then
		importantContainer:ResetAllSlots()
	end
	hadDefensiveAlerts = false
	hadImportantAlerts = false
	previousDefensiveAuras = {}
	previousImportantAuras = {}
end

local function EnableDisable()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Alerts)

	if not moduleEnabled then
		DisableWatchers()
		return
	end

	local inInstance, instanceType = IsInInstance()

	-- Arena, battlegrounds, and the open world all read enemy nameplate watchers.
	if instanceType == "arena" or instanceType == "pvp" or not inInstance then
		RebuildNameplateWatchers()
	else
		ClearNamePlateWatchers()
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
	cachedTTSImportantEnabled = options.TTS and options.TTS.Important and options.TTS.Important.Enabled or false

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
		-- The dedicated important bar only appears in split mode; combined merges into the main bar.
		local importantVisible = importantOptions and importantOptions.Enabled and options.SplitBars
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
		importantContainer:SetCount(options.Icons.MaxIcons or 8)

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
	cachedTTSImportantEnabled = options.TTS and options.TTS.Important and options.TTS.Important.Enabled or false

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

	-- Dedicated important-buff bar (split mode); sized to MaxIcons (Refresh keeps it in sync).
	importantContainer = iconSlotContainer:New(UIParent, count, size, db.IconSpacing or 2, "Alerts", nil, "Alerts")

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

	if options.Important and options.Important.Enabled and options.SplitBars then
		importantContainer.Frame:Show()
	else
		importantContainer.Frame:Hide()
	end

	eventsFrame = CreateFrame("Frame")
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	eventsFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "PVP_MATCH_STATE_CHANGED" then
			OnMatchStateChanged()
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			-- Hook every enemy nameplate's aura refresh so the important bar can react to buff changes.
			if units:IsEnemy(unitToken) then
				HookNameplateAuraFrame(unitToken)
			end
			local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Alerts)
			if moduleEnabled then
				local inInstance, instanceType = IsInInstance()
				if instanceType == "arena" or instanceType == "pvp" or not inInstance then
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
