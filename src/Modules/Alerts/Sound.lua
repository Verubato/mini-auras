---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

addon.Modules.Alerts = addon.Modules.Alerts or {}

---@class AlertsSound
local M = {}
addon.Modules.Alerts.Sound = M

-- Sounds DO work on 12.1, just inverted: the addon can't notice "a new aura appeared", but
-- C_UnitAuras.AddAuraSound lets the ENGINE play a sound when a named spell lands on a registered
-- unit. See alertSoundsByToken. TTS has no such escape hatch (it needs the spell NAME at the
-- moment it appears) and stays disabled.
-- TEMPORARY dual path: remove the transition-driven branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

-- Spells worth an icon but not a noise. The engine plays these per aura application, so an
-- ability that lands often turns the alert sound into a metronome. 12.1 only: the legacy path
-- fires one sound per no-alerts-to-alerts transition rather than per spell, so it has nothing
-- per-spell to exclude.
local SILENT_ALERT_SPELL_IDS = {
	[1044] = true, -- Blessing of Freedom
	[305395] = true, -- Blessing of Freedom
	[8178] = true, -- Grounding Totem
}

-- Read by the tests, which derive the expected registration count from it.
M.SilentAlertSpellIds = SILENT_ALERT_SPELL_IDS

---@type Db
local db
local paused = false
local soundFile

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

-- 12.1 path: engine-side alert sounds via C_UnitAuras.AddAuraSound (the aura transitions the
-- legacy sound reacted to are secret there, but the engine can play sounds on them for us -
-- same pattern as HealerCrowdControlModule). Registrations are per (enemy nameplate token,
-- spellId), fed from the generated Core/AuraCategoryIds Important/Defensive lists.
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
-- Freed id lists from RemoveToken, reused by the next registration instead of allocating a fresh
-- ~116-entry table per nameplate.
local alertSoundIdListPool = {}

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

-- Registers one spell list's sounds against the token already set on `info`, appending the
-- returned ids to `ids`. Hoisted out of RegisterToken so the per-nameplate path doesn't build a
-- closure each time.
---@param ids number[]
---@param info table The shared UnitAuraSoundInfo scratch, with unitToken already set.
---@param list table<number, boolean> Spell ids to register.
---@param config table Sound options (File/Channel).
---@param fallbackFile string
local function RegisterAlertSoundList(ids, info, list, config, fallbackFile)
	info.soundFileName = addon.Config.SoundLocation .. (config.File or fallbackFile)
	info.outputChannel = config.Channel or "Master"

	for spellId in pairs(list) do
		if not SILENT_ALERT_SPELL_IDS[spellId] then
			info.spellID = spellId
			local soundId = C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, info)
			if soundId then
				ids[#ids + 1] = soundId
			end
		end
	end
end

---@param value boolean
function M:SetPaused(value)
	paused = value
end

-- Legacy path: one sound per no-alerts-to-alerts transition.
---@param spellType string "important" or "defensive"
function M:PlaySound(spellType)
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
	soundFile = addon.Config.SoundLocation .. soundFileName
	PlaySoundFile(soundFile, soundConfig.Channel or "Master")
end

---@param spellName string?
---@param spellType string "important" or "defensive"
function M:AnnounceTTS(spellName, spellType)
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

-- Recomputes the important-TTS cache from the saved option AND the class/spec suppression. Called
-- on refresh/init and on spec change (suppression depends on the player's current spec).
function M:UpdateImportantTTSCache()
	local ttsOptions = db and db.Modules.AlertsModule.TTS
	cachedTTSImportantEnabled = (ttsOptions and ttsOptions.Important and ttsOptions.Important.Enabled or false)
		and not ImportantTTSSuppressedForPlayer()
end

---@return boolean
function M:IsImportantTTSEnabled()
	return cachedTTSImportantEnabled or false
end

---@param options AlertsModuleOptions
function M:ApplyTTSOptions(options)
	cachedVoiceID = wowEx:ResolveVoiceID(options.TTS and options.TTS.VoiceID)
	cachedTTSVolume = options.TTS and options.TTS.Volume or 100
	cachedTTSSpeechRate = options.TTS and options.TTS.SpeechRate or 0
	cachedTTSDefensiveEnabled = options.TTS and options.TTS.Defensive and options.TTS.Defensive.Enabled or false
	self:UpdateImportantTTSCache()
end

-- 12.1 path: registers the important/defensive alert sounds for one enemy nameplate token.
-- No-op when already registered (which is what keeps warm registrations cheap on token reuse)
-- or when no alert sound is enabled.
---@param unitToken string
function M:RegisterToken(unitToken)
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
		RegisterAlertSoundList(ids, info, addon.Core.AuraCategoryIds.Important, sound.Important, "AirHorn.ogg")
	end
	if defensiveEnabled then
		RegisterAlertSoundList(ids, info, addon.Core.AuraCategoryIds.Defensive, sound.Defensive, "AlertToastWarm.ogg")
	end

	alertSoundsByToken[unitToken] = ids
end

-- 12.1 path: removes the engine sound registrations for one nameplate token.
---@param unitToken string
function M:RemoveToken(unitToken)
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

function M:RemoveAllTokens()
	for unitToken in pairs(alertSoundsByToken) do
		self:RemoveToken(unitToken)
	end
end

-- 12.1 path: re-evaluates the sound settings; when they change, every active token's
-- registrations are rebuilt (token add/remove is handled incrementally at the display's
-- acquire/release chokepoints). Called from Refresh, which also runs after the test-mode
-- pause/resume transitions.
---@param activeTokens table<string, any> keys are the tokens currently being drawn
function M:Refresh(activeTokens)
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

	self:RemoveAllTokens()
	if active then
		for unitToken in pairs(activeTokens) do
			self:RegisterToken(unitToken)
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()
end
