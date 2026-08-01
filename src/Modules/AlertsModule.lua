---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local auraContainerDisplay = addon.Core.AuraContainerDisplay
local auraFilters = addon.Core.AuraFilters
local growAnchors = addon.Core.GrowAnchors
local eventGate = addon.Core.EventGate
local duelPoller = addon.Core.DuelPoller
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local units = addon.Utils.Units
local auras = addon.Utils.Auras
-- 12.1 path: the alert bars become rows of per-nameplate AuraContainers chained off the movable
-- bar frames. The bar can't stay a single aggregated list there because a container tracks
-- exactly one unit and there is no readable aura data to merge across units - so instead of one
-- bar of N icons, it is N containers laid end to end, and an enemy with no alerts collapses to
-- nothing. The Blizzard nameplate buffList scan is replaced by a HELPFUL|IMPORTANT container
-- group, which also obsoletes the mind-control and purgeable-garbage workarounds on this path.
-- The legacy IconSlotContainer bars stay as drag anchors and test-mode renderers.
--
-- Sounds DO work on 12.1, just inverted: the addon can't notice "a new aura appeared", but
-- C_UnitAuras.AddAuraSound lets the ENGINE play a sound when a named spell lands on a registered
-- unit. See alertSoundsByToken. TTS has no such escape hatch (it needs the spell NAME at the
-- moment it appears) and stays disabled, as do class colours on icons (UnitClass is secret while
-- the unit's identity is).
-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local testModeActive = false
local paused = false
local inPrepRoom = false
---@type EventGate?
local plateGate
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
-- Set for friendly units (i.e. duel opponents): an extra nameplate aura filter to drop the
-- non-important buffs friendly nameplate buff lists contain. Mirrors the nameplates module. nil for
-- true enemies, whose list is already curated.
local impCtxFriendlyFilter
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
-- DH/Mage/Evoker (any spec) and Shadow Priest can purge or steal enemy magic buffs, so enemy
-- nameplates surface a lot of non-important purgeable buffs. The important alpha hides those visually,
-- but TTS can't be gated on the secret IsSpellImportant value (branching would taint), so it would
-- announce the garbage. Important TTS is suppressed entirely for these specs.
local IMPORTANT_TTS_SUPPRESSED_CLASSES = {
	DEMONHUNTER = true,
	MAGE = true,
	EVOKER = true,
	HUNTER = true,
}
local SHADOW_PRIEST_SPEC_ID = 258
-- Main alerts bar: enemy defensive cooldowns, plus important spells when combined.
---@type IconSlotContainer
local container
-- Dedicated, separately-movable bar for important enemy buffs (e.g. offensive cooldowns, precog),
-- used only in split mode. Filled from Blizzard's nameplate buff lists across every active enemy.
---@type IconSlotContainer
local importantContainer
---@type table<string, Watcher>
local nameplateWatchers = {}
-- 12.1 path: per-token display pairs (Def on the main bar, Imp on the important bar in split
-- mode), drawn from a central pre-created pool: acquired and retargeted
-- with SetUnit when an enemy plate appears, released back when it goes away, so plate churn
-- mid-combat never creates containers. Presence in this map means the token is active.
---@type table<string, {Def: AuraContainerDisplay, Imp: AuraContainerDisplay}>
local nameplateDisplays = {}
-- token -> its display pair, kept for the session. nameplateDisplays holds only the ACTIVE
-- tokens; this keeps every pair that has been built so a token returning reuses its own, since
-- WoW frames can never be freed. Pairs are rebuilt only when the configuration baked into their
-- buttons changes (see AlertPairSignature).
local displayPairsByToken = {}
-- Configuration the live pairs were built with; a change rebuilds them. Forward-declared
-- because RefreshNameplateDisplays is defined well above the display helpers.
local pairSignature
local RebuildStaleDisplayPairs
-- Sorted token list scratch for deterministic chaining order.
local displayOrderScratch = {}
-- nameplate token -> its numeric index, memoized. The sort comparator ran a string match per
-- comparison, and the chain re-sorts on every plate add/remove; the token set is small and fixed,
-- so resolving each token once removes all of that per-comparison string churn.
local nameplateTokenOrder = {}
-- Reused enemy-token set for RebuildNameplateWatchers.
local activeTokensScratch = {}
-- Freed id lists from RemoveTokenAlertSounds, reused by the next registration instead of
-- allocating a fresh ~116-entry table per nameplate.
local alertSoundIdListPool = {}
-- Fallback geometry for a pooled display pair, used only if the db isn't readable yet.
-- CreateAlertDisplayPair otherwise builds at the configured size: a button's size is fixed in
-- initializeFrame, which never re-runs on pool reuse, so a placeholder size would survive any
-- refresh that can't restyle (i.e. the whole of an arena).
local DEFAULT_PAIR_ICONS = 8
local DEFAULT_PAIR_SIZE = 24
local DEFAULT_PAIR_SPACING = 2
-- 12.1 path: engine-side alert sounds via C_UnitAuras.AddAuraSound (the aura transitions the
-- legacy sound reacted to are secret there, but the engine can play sounds on them for us -
-- same pattern as HealerCrowdControlModule). Registrations are per (enemy nameplate token,
-- spellId), fed from the generated Core/AuraSoundData Important/Defensive lists.
-- token -> array of auraSoundIDs for that token. Registrations are kept warm across plate
-- despawns: a token's registration set is identical no matter which enemy holds it, so tearing
-- down and re-adding ~120 sounds per plate churn would be pure API traffic. They are removed
-- only when the token reappears as a non-enemy, the sound settings change, or plate tracking
-- stops entirely.
local alertSoundsByToken = {}
-- Signature of the sound settings the current registrations were made with; when it changes
-- every active token is re-registered.
local alertSoundSettingsSignature = nil
-- Reused UnitAuraSoundInfo table for registrations.
local alertSoundInfoScratch = { unitToken = nil, spellID = nil, soundFileName = nil, outputChannel = nil }
-- Duel detection: no event fires when a friendly unit turns attackable at duel start (or back
-- at duel end), so the shared DuelPoller re-registers plates whose enemy status flips.
-- Baselines are seeded on plate add and cleared on plate remove.
---@type DuelPollerSubscriber
local duelSub

---@class AlertsModule : IModule
local M = {}
addon.Modules.AlertsModule = M

local function PlaySound(spellType)
	-- 12.1: sound alerts are disabled - they fire on aura transitions, which are unreadable there.
	if USE_AURA_CONTAINERS then
		return
	end

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

-- True when the player's class/spec should never announce important buffs over TTS (see the comment
-- on IMPORTANT_TTS_SUPPRESSED_CLASSES).
local function ImportantTTSSuppressedForPlayer()
	local _, class = UnitClass("player")
	if IMPORTANT_TTS_SUPPRESSED_CLASSES[class] then
		return true
	end
	if class == "PRIEST" then
		local specIndex = GetSpecialization()
		return (specIndex and GetSpecializationInfo(specIndex)) == SHADOW_PRIEST_SPEC_ID
	end
	return false
end

-- Recomputes cachedTTSImportantEnabled from the saved option AND the class/spec suppression. Called on
-- refresh/init and on spec change (suppression depends on the player's current spec).
local function UpdateImportantTTSCache()
	local ttsOptions = db and db.Modules.AlertsModule.TTS
	cachedTTSImportantEnabled = (ttsOptions and ttsOptions.Important and ttsOptions.Important.Enabled or false)
		and not ImportantTTSSuppressedForPlayer()
end

local function AnnounceTTS(spellName, spellType)
	-- 12.1: TTS is disabled - it fires on aura transitions, which are unreadable there.
	if USE_AURA_CONTAINERS then
		return
	end

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
	if impCtxFriendlyFilter
		and C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, impCtxFriendlyFilter) then
		return
	end
	-- Drop purgeable non-defensive buffs (sound/TTS and bar): the non-important garbage Blizzard's
	-- enemy list bundles in. Purgeable defensives (e.g. magic barriers) are kept.
	if auras:IsPurgeableNonDefensive(unit, auraInstanceID) then
		return
	end
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
	-- Hide non-important survivors via alpha: IsSpellImportant is a secret boolean SetAlphaFromBoolean
	-- accepts directly. Catches the non-important garbage the purgeable filter can't (e.g. for
	-- non-dispel specs). Sound/TTS above can't be gated the same way - branching on the secret value
	-- would taint - so they still fire for every tracked buff (see the class-based TTS suppression).
	importantOptionsScratch.Alpha = C_Spell.IsSpellImportant(aura.spellId)
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
	-- Alerts only tracks enemies, but a duel opponent is same-faction (IsFriend) so their nameplate
	-- buff list is the uncurated friendly one - apply the friendly filter to drop the garbage.
	impCtxFriendlyFilter = units:IsFriend(unit)
		and "HELPFUL|INCLUDE_NAME_PLATE_ONLY|RAID_IN_COMBAT|PLAYER"
		or nil
	buffList:Iterate(PlaceImportantBuff)
end

local function OnAuraDataChanged()
	-- 12.1: the container path renders everything and no watchers feed this; skip the wasted
	-- scratch-table wipes and bar resets it would otherwise do on every scheduled update.
	if USE_AURA_CONTAINERS then
		return
	end

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
			-- Skip mind-controlled units: charm flips the nameplate buff list to the uncurated friendly
			-- one, spamming TTS and invisible important-icon slots. A charmed enemy player stays
			-- attackable by the controller's team, so CanAttack alone can't detect this - test the charm
			-- state directly. Also covers a charmed ally whose plate flipped to an enemy one. The
			-- CanAttack skip stays for units that genuinely become non-attackable.
			local watcherUnit = watcher:GetUnit()
			local controlled = watcherUnit
				and (units:IsCharmed(watcherUnit) or not units:CanAttack(watcherUnit))
			if not controlled then
				activeWatchers[#activeWatchers + 1] = watcher
			end
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
	-- Test icons render through the legacy IconSlotContainer, which CAN class colour - but the
	-- real 12.1 bars can't (UnitClass is secret there, and the option is hidden in the config).
	-- Colouring only the preview would advertise something the live display never does.
	local colorByClass = not USE_AURA_CONTAINERS and db.Modules.AlertsModule.Icons.ColorByClass
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

-- Resolves (and memoizes) a token's numeric index, so the comparator below never has to run a
-- pattern match. Non-nameplate tokens memoize as false and fall back to a string compare.
local function NameplateTokenIndex(token)
	local index = nameplateTokenOrder[token]
	if index == nil then
		index = tonumber(token:match("^nameplate(%d+)$")) or false
		nameplateTokenOrder[token] = index
	end

	return index
end

-- Numeric-aware token order so nameplate10 doesn't sort between nameplate1 and nameplate2.
local function NameplateTokenLess(a, b)
	local numberA = NameplateTokenIndex(a)
	local numberB = NameplateTokenIndex(b)
	if numberA and numberB then
		return numberA < numberB
	end
	return a < b
end

-- Effective grow direction for the alert bars. CENTER (the default, symmetric growth around
-- the anchor) needs a readable row width to center on, which the 12.1 chained displays don't
-- have, so it falls back to RIGHT there.
local function GetGrow()
	local grow = db.Modules.AlertsModule.Grow
	if grow ~= "LEFT" and grow ~= "RIGHT" then
		grow = "CENTER"
	end
	if USE_AURA_CONTAINERS and grow == "CENTER" then
		return "RIGHT"
	end
	return grow
end

-- Rewrites a bar's saved anchor so the pinned edge matches the grow direction, keeping the
-- frame at its current on-screen position (changing Grow never visibly moves the bar). Rect
-- values are in the frame's own scale, which is also the scale SetPoint offsets use, so no
-- conversion is needed even though the bars ignore parent scale.
local function NormalizeBarAnchor(frame, anchorOptions, grow)
	local point = growAnchors:GetPinPoint(grow)
	if anchorOptions.Point == point then
		return
	end
	local left, right = frame:GetLeft(), frame:GetRight()
	local centerX, centerY = frame:GetCenter()
	if not left or not right or not centerY then
		return
	end
	anchorOptions.Point = point
	anchorOptions.RelativeTo = "UIParent"
	anchorOptions.RelativePoint = "BOTTOMLEFT"
	anchorOptions.Offset.X = (point == "RIGHT" and right) or (point == "LEFT" and left) or centerX
	anchorOptions.Offset.Y = centerY
end

-- Saves a bar's position after a drag, normalized to the grow-appropriate pinned edge.
local function SaveDraggedPosition(frame, anchorOptions)
	local point, relativeTo, relativePoint, x, y = frame:GetPoint()
	anchorOptions.Point = point
	anchorOptions.RelativePoint = relativePoint
	anchorOptions.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
	anchorOptions.Offset.X = x
	anchorOptions.Offset.Y = y
	NormalizeBarAnchor(frame, anchorOptions, GetGrow())
end

-- 12.1 path: re-anchors the active per-nameplate displays into rows. Defensive displays chain
-- off the main bar frame; important displays chain off the important bar in split mode, or
-- continue the main-bar chain when combined. Chaining container-to-container avoids reading
-- their (possibly secret) sizes; empty containers collapse to nothing.
-- (Category overlap is handled by filter negation at group creation, not here.)
local function ChainAlertDisplays()
	local options = db.Modules.AlertsModule
	local spacing = options.IconSpacing or 2
	local splitBars = options.SplitBars
	-- Same chain geometry the aura displays use when they follow a kick icon: continue the row
	-- in the grow direction, offset by the icon spacing.
	local point, relativePoint, step = growAnchors:GetChain(GetGrow(), spacing)

	local tokens = displayOrderScratch
	wipe(tokens)
	for token in pairs(nameplateDisplays) do
		tokens[#tokens + 1] = token
	end
	table.sort(tokens, NameplateTokenLess)

	-- Note the first display in each row anchors point -> POINT on the bar frame, not
	-- point -> relativePoint: it starts AT the bar's pinned edge rather than continuing past it,
	-- since the (zero-width) bar frame is the row's origin and not a preceding icon.
	local prevMain
	for _, token in ipairs(tokens) do
		local defFrame = nameplateDisplays[token].Def.Frame
		defFrame:ClearAllPoints()
		if prevMain then
			defFrame:SetPoint(point, prevMain, relativePoint, step, 0)
		else
			defFrame:SetPoint(point, container.Frame, point, 0, 0)
		end
		prevMain = defFrame
	end

	-- Combined mode draws importants from the Def container's own Important group, so there is
	-- no second frame to place. Ordering differs from the legacy bar as a result: each unit's
	-- categories stay together (u1 def+imp, u2 def+imp) rather than every defensive followed by
	-- every important. That grouping is what removes the gap - the alternative needs one frame
	-- per category per unit, and the engine reserves each frame's full icon budget of width.
	if not splitBars then
		return
	end

	local prevImp
	for _, token in ipairs(tokens) do
		local impFrame = nameplateDisplays[token].Imp.Frame
		impFrame:ClearAllPoints()
		if prevImp then
			impFrame:SetPoint(point, prevImp, relativePoint, step, 0)
		else
			impFrame:SetPoint(point, importantContainer.Frame, point, 0, 0)
		end
		prevImp = impFrame
	end
end

---12.1 path: whether the alert bars should currently render at all.
local function GetAlertBarsShown()
	local options = db.Modules.AlertsModule
	return moduleUtil:IsModuleEnabled(moduleName.Alerts)
		and options.Icons.Enabled
		and not inPrepRoom
		and not testModeActive
end

-- 12.1 path: applies options (size, style, per-category budgets, visibility) to ONE pooled
-- display pair. Deviations from the legacy bar, forced by aura data being unreadable: no
-- class-colored glow/border, and MaxIcons caps each unit's icons rather than the whole bar.
-- (Important-vs-defensive dedup is handled by filter negation at creation.)
local function ApplyNameplateDisplayOptions(entry, options, showBars)
	local includeDefensives = options.IncludeDefensives
	local importantEnabled = options.Important and options.Important.Enabled
	local splitBars = options.SplitBars
	local maxIcons = options.Icons.MaxIcons or 8
	local size = options.Icons.Size
	local spacing = options.IconSpacing or 2
	local showTooltips = options.ShowTooltips ~= false
	local grow = GetGrow()

	-- Important renders on whichever display the current mode uses; the other is budgeted to 0.
	local importantOnDef = importantEnabled and not splitBars
	local importantOnImp = importantEnabled and splitBars

	entry.Def:SetGrow(grow)
	entry.Def:SetIconSize(size)
	entry.Def:SetSpacing(spacing)
	entry.Def:SetMaxIcons(auraFilters.GroupKey.BigDefensive, includeDefensives and maxIcons or 0)
	entry.Def:SetMaxIcons(auraFilters.GroupKey.ExternalDefensive, includeDefensives and maxIcons or 0)
	entry.Def:SetMaxIcons(auraFilters.GroupKey.Important, importantOnDef and maxIcons or 0)

	-- Both displays take the same style; fill the scratch once and hand it to each.
	local style = auraContainerDisplay:GetStyleScratch()
	style.ReverseCooldown = options.Icons.ReverseCooldown
	style.Glow = options.Icons.Glow
	style.FontScale = db.FontScale
	style.ShowTooltips = showTooltips

	entry.Def:SetStyle(style)
	entry.Def:SetEnabled(showBars == true)
	entry.Def:SetShown(showBars == true)

	entry.Imp:SetGrow(grow)
	entry.Imp:SetIconSize(size)
	entry.Imp:SetSpacing(spacing)
	entry.Imp:SetMaxIcons(auraFilters.GroupKey.Important, importantOnImp and maxIcons or 0)
	entry.Imp:SetStyle(style)
	local impShown = showBars and importantOnImp
	entry.Imp:SetEnabled(impShown == true)
	entry.Imp:SetShown(impShown == true)
end

-- 12.1 path: applies options to every pooled display pair and re-chains the rows.
local function RefreshNameplateDisplays()
	local options = db.Modules.AlertsModule
	local showBars = GetAlertBarsShown()

	RebuildStaleDisplayPairs()

	for _, entry in pairs(nameplateDisplays) do
		ApplyNameplateDisplayOptions(entry, options, showBars)
	end

	ChainAlertDisplays()
end

local function OnMatchStateChanged()
	local matchState = C_PvP.GetActiveMatchState()

	inPrepRoom = matchState == Enum.PvPMatchState.StartUp

	if USE_AURA_CONTAINERS then
		-- Prep-room garbage handling: RefreshNameplateDisplays hides the displays while
		-- inPrepRoom is set and re-shows them when the match starts.
		RefreshNameplateDisplays()
	end

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

-- 12.1 path: removes the engine sound registrations for one nameplate token.
local function RemoveTokenAlertSounds(unitToken)
	local ids = alertSoundsByToken[unitToken]
	if not ids then
		return
	end
	for i = #ids, 1, -1 do
		C_UnitAuras.RemoveAuraSound(ids[i])
		ids[i] = nil
	end
	alertSoundsByToken[unitToken] = nil
	-- Now empty; hand it back for the next token instead of garbaging a ~116-entry table.
	alertSoundIdListPool[#alertSoundIdListPool + 1] = ids
end

local function RemoveAllTokenAlertSounds()
	for unitToken in pairs(alertSoundsByToken) do
		RemoveTokenAlertSounds(unitToken)
	end
end

-- Registers one spell list's sounds against the token already set on `info`, appending the
-- returned ids to `ids`. Hoisted out of RegisterTokenAlertSounds so the per-nameplate path
-- doesn't build a closure each time.
---@param ids number[]
---@param info table The shared UnitAuraSoundInfo scratch, with unitToken already set.
---@param list table<number, boolean> Spell ids to register.
---@param config table Sound options (File/Channel).
---@param fallbackFile string
local function RegisterAlertSoundList(ids, info, list, config, fallbackFile)
	info.soundFileName = addon.Config.MediaLocation .. (config.File or fallbackFile)
	info.outputChannel = config.Channel or "Master"

	for spellId in pairs(list) do
		info.spellID = spellId
		local soundId = C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, info)
		if soundId then
			ids[#ids + 1] = soundId
		end
	end
end

-- 12.1 path: registers the important/defensive alert sounds for one enemy nameplate token.
-- No-op when already registered (which is what keeps warm registrations cheap on token reuse)
-- or when no alert sound is enabled.
local function RegisterTokenAlertSounds(unitToken)
	if not USE_AURA_CONTAINERS or alertSoundsByToken[unitToken] then
		return
	end
	if paused or not moduleUtil:IsModuleEnabled(moduleName.Alerts) then
		return
	end
	local sound = db.Modules.AlertsModule.Sound
	local importantEnabled = sound.Important and sound.Important.Enabled
	local defensiveEnabled = sound.Defensive and sound.Defensive.Enabled
	if not importantEnabled and not defensiveEnabled then
		return
	end

	local ids = table.remove(alertSoundIdListPool) or {}
	local info = alertSoundInfoScratch
	info.unitToken = unitToken

	if importantEnabled then
		RegisterAlertSoundList(ids, info, addon.Core.AuraSoundData.Important, sound.Important, "AirHorn.ogg")
	end
	if defensiveEnabled then
		RegisterAlertSoundList(ids, info, addon.Core.AuraSoundData.Defensive, sound.Defensive, "AlertToastWarm.ogg")
	end

	alertSoundsByToken[unitToken] = ids
end

-- 12.1 path: re-evaluates the sound settings; when they change, every active token's
-- registrations are rebuilt (token add/remove is handled incrementally at the
-- Ensure/ReleaseNameplateDisplay chokepoints). Called from Refresh, which also runs after
-- the test-mode Pause/Resume transitions.
local function RefreshAlertSounds()
	if not USE_AURA_CONTAINERS then
		return
	end
	local sound = db.Modules.AlertsModule.Sound
	local importantEnabled = (sound.Important and sound.Important.Enabled) or false
	local defensiveEnabled = (sound.Defensive and sound.Defensive.Enabled) or false
	local active = (importantEnabled or defensiveEnabled)
		and moduleUtil:IsModuleEnabled(moduleName.Alerts)
		and not paused
	local signature = tostring(active)
		.. "|" .. tostring(importantEnabled)
		.. "|" .. tostring(sound.Important and sound.Important.File)
		.. "|" .. tostring(sound.Important and sound.Important.Channel)
		.. "|" .. tostring(defensiveEnabled)
		.. "|" .. tostring(sound.Defensive and sound.Defensive.File)
		.. "|" .. tostring(sound.Defensive and sound.Defensive.Channel)
	if signature == alertSoundSettingsSignature then
		return
	end
	alertSoundSettingsSignature = signature

	RemoveAllTokenAlertSounds()
	if active then
		for unitToken in pairs(nameplateDisplays) do
			RegisterTokenAlertSounds(unitToken)
		end
	end
end

-- 12.1 path: builds one pooled display pair. BIG and EXTERNAL defensives are separate groups
-- because filter-string tokens combine with AND - "HELPFUL|BIG_DEFENSIVE|EXTERNAL_DEFENSIVE"
-- would only match auras flagged as BOTH, i.e. almost nothing; groups on one container are
-- the idiom for OR (they render as one continuous row). The filters themselves are partitioned
-- by negation (see Core/AuraFilters), so a both-important-and-defensive aura is never drawn on
-- both bars (legacy deduped by id). Sizes/budgets are applied per token by
-- RefreshNameplateDisplays.
--
-- Def carries an Important group too, so combined mode can render all three categories in one
-- container with no gap. Separate containers are separate frames chained by SetPoint and the
-- engine reserves each one's maxFrameCount worth of width, so an under-filled defensive display
-- left a hole before the important icons; groups inside a single container flow tight instead.
-- A display's group list is fixed for its lifetime (see New), so both groups always exist and
-- the mode is chosen purely by budgeting one of them to 0 - no container churn on toggle.
---Fills the shared style scratch from the alert options.
---@return AuraDisplayStyle
local function AlertStyle()
	local options = db and db.Modules.AlertsModule
	local icons = options and options.Icons
	local style = auraContainerDisplay:GetStyleScratch()
	style.ReverseCooldown = icons and icons.ReverseCooldown
	style.Glow = icons and icons.Glow
	style.FontScale = db and db.FontScale
	style.ShowTooltips = not options or options.ShowTooltips ~= false
	return style
end

local function CreateAlertDisplayPair()
	-- Build at the CONFIGURED size, not a placeholder. A button takes its size in
	-- initializeFrame, which the frame pool runs once when it creates the button and never
	-- again on reuse (AcquireFrame does not re-initialise). Correcting it afterwards needs a
	-- restyle, and inside an arena C_Secrets.ShouldAurasBeSecret never clears, so the restyle
	-- never gets to run and the icons keep the placeholder size for the whole match. Creating
	-- them right means the common path needs no restyle at all. The constants stay as
	-- fallbacks for the pre-creation that can run before the db is read.
	local options = db and db.Modules.AlertsModule
	local icons = options and options.Icons
	local size = (icons and icons.Size) or DEFAULT_PAIR_SIZE
	local maxIcons = (icons and icons.MaxIcons) or DEFAULT_PAIR_ICONS
	local spacing = (options and options.IconSpacing) or DEFAULT_PAIR_SPACING

	-- Style is applied at creation for the same reason as the size: StyleButton bakes it into
	-- each button, and a later restyle can't reach them while auras are secret.
	local style = AlertStyle()

	return {
		Def = auraContainerDisplay:New(UIParent, "none", {
			{
				Key = auraFilters.GroupKey.BigDefensive,
				FilterString = auraFilters.Filter.BigDefensive,
				CandidateFilters = auraFilters.CandidateFilters.BigDefensive,
				MaxIcons = maxIcons,

			},
			{
				Key = auraFilters.GroupKey.ExternalDefensive,
				FilterString = auraFilters.Filter.ExternalDefensive,
				CandidateFilters = auraFilters.CandidateFilters.ExternalDefensive,
				MaxIcons = maxIcons,

			},
			-- Used in combined mode only; budgeted to 0 when the bars are split.
			{
				Key = auraFilters.GroupKey.Important,
				FilterString = auraFilters.Filter.Important,
				CandidateFilters = auraFilters.CandidateFilters.Important,
				MaxIcons = maxIcons,

			},
		}, size, spacing, "Alerts", { Style = style }),
		-- Used in split mode only; hidden and budgeted to 0 when combined.
		Imp = auraContainerDisplay:New(UIParent, "none", {
			{
				Key = auraFilters.GroupKey.Important,
				FilterString = auraFilters.Filter.Important,
				CandidateFilters = auraFilters.CandidateFilters.Important,
				MaxIcons = maxIcons,

			},
		}, size, spacing, "Alerts", { Style = style }),
	}
end

-- Everything baked into a pair's buttons when it is created. A change means the live pairs have
-- to be rebuilt rather than restyled, because a restyle can't reach the buttons while auras are
-- secret (i.e. for the whole of an arena).
---@return string
local function AlertPairSignature()
	local options = db and db.Modules.AlertsModule
	local icons = options and options.Icons

	return auraContainerDisplay:GetStyleSignature(
		AlertStyle(),
		(icons and icons.Size) or DEFAULT_PAIR_SIZE,
		(options and options.IconSpacing) or DEFAULT_PAIR_SPACING
	) .. ":" .. tostring(icons and icons.MaxIcons)
end

-- 12.1 path: parks a display pair (both displays stay parented to UIParent).
local function ResetAlertDisplayPair(entry)
	entry.Def:SetEnabled(false)
	entry.Def:Hide()
	entry.Def.Frame:ClearAllPoints()
	entry.Imp:SetEnabled(false)
	entry.Imp:Hide()
	entry.Imp.Frame:ClearAllPoints()
end

-- 12.1 path: activates the display pair for a nameplate token, acquiring from the pool on
-- first sight. SetEnabled(false -> true) in RefreshNameplateDisplays triggers the containers'
-- own full refresh, so a pair re-acquired for a recycled token repopulates.
local function EnsureNameplateDisplay(unitToken)
	local entry = nameplateDisplays[unitToken]

	if not entry then
		entry = displayPairsByToken[unitToken]

		if not entry then
			entry = CreateAlertDisplayPair()
			displayPairsByToken[unitToken] = entry
		end

		nameplateDisplays[unitToken] = entry
	end

	entry.Def:SetUnit(unitToken)
	entry.Imp:SetUnit(unitToken)
	RegisterTokenAlertSounds(unitToken)
	return entry
end

-- 12.1 path: parks a token's display pair when its plate goes away. The pair stays in
-- displayPairsByToken for the token's return; only the active map loses it. Deliberately leaves
-- the token's sound registrations warm (see alertSoundsByToken).
local function ReleaseNameplateDisplay(unitToken)
	local entry = nameplateDisplays[unitToken]
	if entry then
		nameplateDisplays[unitToken] = nil
		ResetAlertDisplayPair(entry)
	end
end

-- Drops every built pair so the next Ensure rebuilds it. Used when the configuration baked into
-- the buttons changes; there is no way to restyle in place.
local function RebuildDisplayPairs()
	for token, entry in pairs(displayPairsByToken) do
		ResetAlertDisplayPair(entry)
		displayPairsByToken[token] = nil
		nameplateDisplays[token] = nil
	end
end

-- Rebuilds every pair when the configuration baked into their buttons has changed. Tokens that
-- are currently tracked get theirs back straight away so the bars never blank out.
function RebuildStaleDisplayPairs()
	local signature = AlertPairSignature()

	if signature == pairSignature then
		return
	end

	pairSignature = signature

	local tracked = activeTokensScratch
	wipe(tracked)

	for token in pairs(nameplateDisplays) do
		tracked[#tracked + 1] = token
	end

	RebuildDisplayPairs()

	for _, token in ipairs(tracked) do
		EnsureNameplateDisplay(token)
	end
end

-- Plate tracking is stopping entirely (module off, or a zone where alerts don't run), so the
-- warm sound registrations go too.
local function ReleaseAllNameplateDisplays()
	RemoveAllTokenAlertSounds()
	for unitToken in pairs(nameplateDisplays) do
		ReleaseNameplateDisplay(unitToken)
	end
end

-- Hooks a nameplate's RefreshAuras so the important bar (which reads Blizzard's nameplate buff
-- lists) refreshes when the game updates them. Watchers don't track buffs, so this is the only
-- signal for buff changes. Installed for every enemy nameplate; the hook is a cheap no-op when
-- nothing important-related is enabled. Legacy path only.
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
	-- Baseline for the duel poll, kept fresh on every (re)registration.
	local isEnemy = duelSub:Seed(unitToken)

	-- Only track enemy nameplates
	if not isEnemy then
		if USE_AURA_CONTAINERS then
			-- The token now belongs to a non-enemy (recycled plate or duel ending), so its warm
			-- sound registrations are dropped along with the display.
			RemoveTokenAlertSounds(unitToken)
			ReleaseNameplateDisplay(unitToken)
		end
		return
	end

	if USE_AURA_CONTAINERS then
		-- Configure only the new entry (styling every pooled pair per plate spawn adds up in
		-- busy fights); the chain re-anchor is cheap and covers the row shift.
		local entry = EnsureNameplateDisplay(unitToken)
		ApplyNameplateDisplayOptions(entry, db.Modules.AlertsModule, GetAlertBarsShown())
		ChainAlertDisplays()
		return
	end

	-- Clean up any existing watcher for this unit token
	if nameplateWatchers[unitToken] then
		nameplateWatchers[unitToken]:Dispose()
		nameplateWatchers[unitToken] = nil
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
	duelSub:Clear(unitToken)

	if USE_AURA_CONTAINERS then
		ReleaseNameplateDisplay(unitToken)
		ChainAlertDisplays()
		return
	end

	if nameplateWatchers[unitToken] then
		nameplateWatchers[unitToken]:Dispose()
		nameplateWatchers[unitToken] = nil
		ScheduleAuraDataUpdate()
	end
end

local function ClearNamePlateWatchers()
	if USE_AURA_CONTAINERS then
		ReleaseAllNameplateDisplays()
		return
	end

	for unitToken, watcher in pairs(nameplateWatchers) do
		watcher:Dispose()
		nameplateWatchers[unitToken] = nil
	end
end

local function RebuildNameplateWatchers()
	-- Build a set of currently active enemy unit tokens
	local activeTokens = activeTokensScratch
	wipe(activeTokens)
	for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
		local unitToken = nameplate.unitToken
		if unitToken then
			-- Seed the duel-poll baseline here too: plates that existed before Init/enable
			-- never fire NAME_PLATE_UNIT_ADDED.
			if duelSub:Seed(unitToken) then
				activeTokens[unitToken] = true
			end
		end
	end

	if USE_AURA_CONTAINERS then
		for unitToken in pairs(nameplateDisplays) do
			if not activeTokens[unitToken] then
				ReleaseNameplateDisplay(unitToken)
			end
		end
		for unitToken in pairs(activeTokens) do
			EnsureNameplateDisplay(unitToken)
		end
		RefreshNameplateDisplays()
		return
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

local function Pause()
	paused = true
end

local function Resume()
	paused = false
	ScheduleAuraDataUpdate()
end

-- Lifecycle

---@return AlertsModuleOptions?
local function GetOptions()
	-- The bars are built in Init; without them there is nothing to configure.
	if not db or not container then
		return nil
	end

	return db.Modules.AlertsModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Alerts)
end

---Arena, battlegrounds, and the open world all read enemy nameplate watchers; nowhere else does.
---@param isEnabled boolean
---@return boolean
local function AreNameplatesNeeded(isEnabled)
	local inInstance, instanceType = IsInInstance()

	return isEnabled and (instanceType == "arena" or instanceType == "pvp" or not inInstance)
end

---@param active boolean
local function SetEventsActive(active)
	-- Plate events stay unregistered while inactive; ZONE_CHANGED_NEW_AREA and
	-- PVP_MATCH_STATE_CHANGED stay registered as they drive this gate.
	local nameplatesNeeded = AreNameplatesNeeded(active)

	if plateGate then
		plateGate:SetActive(nameplatesNeeded)
	end

end

local function Teardown()
	for _, watcher in pairs(nameplateWatchers) do
		watcher:Disable()
	end

	if USE_AURA_CONTAINERS then
		ReleaseAllNameplateDisplays()
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

local function EnsureFrames()
	if AreNameplatesNeeded(true) then
		RebuildNameplateWatchers()
	else
		ClearNamePlateWatchers()
	end

	ScheduleAuraDataUpdate()
end

---@param options AlertsModuleOptions
local function ApplyTTSOptions(options)
	cachedVoiceID = wowEx:ResolveVoiceID(options.TTS and options.TTS.VoiceID)
	cachedTTSVolume = options.TTS and options.TTS.Volume or 100
	cachedTTSSpeechRate = options.TTS and options.TTS.SpeechRate or 0
	cachedTTSDefensiveEnabled = options.TTS and options.TTS.Defensive and options.TTS.Defensive.Enabled or false
	UpdateImportantTTSCache()
end

---@param options AlertsModuleOptions
---@param grow string
local function ApplyMainBarOptions(options, grow)
	NormalizeBarAnchor(container.Frame, options, grow)

	container.Frame:ClearAllPoints()
	container.Frame:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	container:SetIconSize(options.Icons.Size)
	container:SetSpacing(options.IconSpacing or 2)
	container:SetCount(options.Icons.MaxIcons or 8)
	-- Grow-left rows fill right-to-left so the first icon sits nearest the pinned edge,
	-- matching the 12.1 flow layouts.
	container:SetRows(nil, "CENTER", grow == "LEFT")
end

---@param options AlertsModuleOptions
---@param grow string
local function ApplyImportantBarOptions(options, grow)
	if not importantContainer then
		return
	end

	local importantOptions = options.Important
	-- The dedicated important bar only appears in split mode; combined merges into the main bar.
	local importantVisible = importantOptions and importantOptions.Enabled and options.SplitBars
	local impAnchor = importantOptions or options

	if impAnchor ~= options then
		NormalizeBarAnchor(importantContainer.Frame, impAnchor, grow)
	end

	importantContainer.Frame:ClearAllPoints()
	importantContainer.Frame:SetPoint(
		impAnchor.Point,
		_G[impAnchor.RelativeTo] or UIParent,
		impAnchor.RelativePoint,
		impAnchor.Offset.X,
		impAnchor.Offset.Y
	)

	importantContainer:SetIconSize(options.Icons.Size)
	importantContainer:SetSpacing(options.IconSpacing or 2)
	importantContainer:SetCount(options.Icons.MaxIcons or 8)
	importantContainer:SetRows(nil, "CENTER", grow == "LEFT")

	if importantVisible then
		importantContainer.Frame:Show()
		-- Only draggable while the test bars are up; this runs with the module enabled.
		importantContainer.Frame:EnableMouse(testModeActive)
		importantContainer.Frame:SetMovable(testModeActive)
	else
		importantContainer:ResetAllSlots()
		importantContainer.Frame:Hide()
		importantContainer.Frame:EnableMouse(false)
		importantContainer.Frame:SetMovable(false)
	end
end

---@param options AlertsModuleOptions
local function ApplyOptions(options)
	ApplyTTSOptions(options)

	local grow = GetGrow()
	ApplyMainBarOptions(options, grow)
	ApplyImportantBarOptions(options, grow)
end

---@param options AlertsModuleOptions
local function UpdateContent(options)
	if USE_AURA_CONTAINERS then
		RefreshNameplateDisplays()
		RefreshAlertSounds()
	end

	if testModeActive then
		RefreshTestAlerts()
	end
end

---@param active boolean
local function SetAnchorInteractive(active)
	if not container then
		return
	end

	container.Frame:EnableMouse(active)
	container.Frame:SetMovable(active)

	if not importantContainer then
		return
	end

	-- The important bar is only draggable while it is actually on screen (split mode).
	local moveable = active and importantContainer.Frame:IsShown()
	importantContainer.Frame:EnableMouse(moveable)
	importantContainer.Frame:SetMovable(moveable)
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active

	if active then
		Pause()
	else
		if container then
			container:ResetAllSlots()
		end
		if importantContainer then
			importantContainer:ResetAllSlots()
		end
		Resume()
	end

	M:Refresh()
	SetAnchorInteractive(active)
end

---@param bar IconSlotContainer
---@param anchorOptions table
local function SetUpBarDragging(bar, anchorOptions)
	local relativeTo = _G[anchorOptions.RelativeTo] or UIParent

	bar.Frame:SetPoint(
		anchorOptions.Point,
		relativeTo,
		anchorOptions.RelativePoint,
		anchorOptions.Offset.X,
		anchorOptions.Offset.Y
	)
	bar.Frame:SetFrameLevel((relativeTo:GetFrameLevel() or 0) + 5)
	bar.Frame:EnableMouse(false)
	bar.Frame:SetMovable(false)
	bar.Frame:SetClampedToScreen(true)
	bar.Frame:RegisterForDrag("LeftButton")
	bar.Frame:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	bar.Frame:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()
		SaveDraggedPosition(anchorSelf, anchorOptions)
	end)
end

local function CreateFrames()

	local options = db.Modules.AlertsModule
	local count = options.Icons.MaxIcons or 8
	local size = options.Icons.Size

	container = iconSlotContainer:New(UIParent, count, size, options.IconSpacing or 2, "Alerts", nil, "Alerts")
	SetUpBarDragging(container, options)
	container.Frame:Show()

	-- Dedicated important-buff bar (split mode); sized to MaxIcons (Refresh keeps it in sync).
	importantContainer = iconSlotContainer:New(UIParent, count, size, options.IconSpacing or 2, "Alerts", nil, "Alerts")
	SetUpBarDragging(importantContainer, options.Important or options)

	if options.Important and options.Important.Enabled and options.SplitBars then
		importantContainer.Frame:Show()
	else
		importantContainer.Frame:Hide()
	end
end

local function CreateEvents()
	local eventsFrame = CreateFrame("Frame")
	-- The plate events are gated by Refresh; PVP_MATCH_STATE_CHANGED and
	-- ZONE_CHANGED_NEW_AREA drive that gate so they stay always-registered.
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	eventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	plateGate = eventGate:New(eventsFrame, { "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }, {
		-- Plate events maintain the duel baselines; drop them so reactivation reseeds
		-- via RebuildNameplateWatchers instead of trusting stale tokens.
		OnDeactivate = function()
			duelSub:ClearAll()
		end,
	})
	eventsFrame:SetScript("OnEvent", function(_, event, unitToken)
		if event == "PVP_MATCH_STATE_CHANGED" then
			OnMatchStateChanged()
		elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
			-- Important-TTS suppression depends on the player's spec (Shadow Priest), so refresh it.
			UpdateImportantTTSCache()
		elseif event == "NAME_PLATE_UNIT_ADDED" then
			-- Hook every enemy nameplate's aura refresh so the important bar can react to buff changes.
			-- Legacy only: on 12.1 the containers track their unit themselves.
			if not USE_AURA_CONTAINERS and units:IsEnemy(unitToken) then
				HookNameplateAuraFrame(unitToken)
			end
			if IsEnabled() and AreNameplatesNeeded(true) then
				OnNamePlateAdded(unitToken)
			end
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			OnNamePlateRemoved(unitToken)
		elseif event == "ZONE_CHANGED_NEW_AREA" then
			M:Refresh()
		end
	end)

	-- A duel opponent starts as an untracked friendly plate; when the duel begins the flip
	-- routes through OnNamePlateAdded to build its displays and sound registrations, and when
	-- it ends the same call releases them.
	duelSub = duelPoller:Register(function()
		return moduleUtil:IsModuleEnabled(moduleName.Alerts)
	end, OnNamePlateAdded)
end

local function ApplyInitialState()
	M:Refresh()
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	local options = GetOptions()

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		Teardown()
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent(options)
end

function M:Init()
	db = mini:GetSavedVars()

	CreateFrames()
	CreateEvents()
	ApplyInitialState()
end
