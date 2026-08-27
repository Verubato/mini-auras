---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local auraSounds = addon.Core.AuraSounds
local ttsPacks = addon.Core.TtsPacks
local ttsMutes = addon.Core.TtsMutes
local units = addon.Utils.UnitUtil
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local changeStamp = addon.Utils.ChangeStamp

addon.Modules.Alerts = addon.Modules.Alerts or {}

---@class AlertsSound
local M = {}
addon.Modules.Alerts.Sound = M

-- The addon cannot notice a new aura, but C_UnitAuras.AddAuraSound lets the engine play a sound
-- when a named spell lands on a registered unit. TTS rides the same mechanism with one baked clip
-- per spell name, registered against its own spell id.

-- The two sound sets the module keeps, stamped so a settings change re-registers them and
-- anything else leaves them alone.
local ALERT_SOUND_KEY = "AlertSounds"
local ALLY_SOUND_KEY = "AlertAllySounds"
-- Spells worth an icon but not a noise. The engine plays these per aura application, so an
-- ability that lands often turns the alert sound into a metronome.
local SILENT_ALERT_SPELL_IDS = {
	[1044] = true, -- Blessing of Freedom
	[305395] = true, -- Blessing of Freedom
	[8178] = true, -- Grounding Totem
}

-- The enemy-debuff spells land on the caster's target, so one appearing on an enemy plate means an
-- ally cast it. The plates stay quiet for those and RefreshAllySounds announces the incoming ones.
-- Their TTS clips are already absent from the plate categories, so this only has the plain alert
-- sound left to cover.
for spellId in pairs(addon.Core.AuraCategoryIds.EnemyDebuff) do
	SILENT_ALERT_SPELL_IDS[spellId] = true
end

-- Read by the tests, which derive the expected registration count from it.
M.SilentAlertSpellIds = SILENT_ALERT_SPELL_IDS

-- Who the enemy-debuff announcements watch. Those cooldowns sit on whoever they were cast at, so
-- they land on your own side and there is no nameplate to hang them off. Filled from the roster
-- per pass, with the player always kept, since FriendlyUnits hands back nothing while solo and a
-- duel is exactly when being told about a Deathmark on yourself matters.
local allyTokens = {}

---@type Db
local db
local paused = false

-- token -> pooled list of sound handles for that token, one registration per token and spell id,
-- fed from the generated Core/AuraCategoryIds lists plus the baked TTS clips when those are on.
-- Registrations are kept warm across plate despawns, since a token's set is identical no matter
-- which enemy holds it and re-adding ~120 sounds per plate churn would be pure API traffic. They
-- are removed only when the token reappears as a non-enemy, the sound settings change, or plate
-- tracking stops entirely.
local alertSoundsByToken = {}
local settingsStamp = changeStamp:New()
-- Refilled by AddSet on each check; see Utils/ChangeStamp.
local mutedScratch = {}
local alertSoundSettingsGeneration = nil
-- The enemy-debuff registrations: one flat list over every watched token rather than a set per
-- token, because they are all made and dropped together.
---@type number[]?
local allySoundIds
local allySoundGeneration = nil

-- The spells that stay silent in one category: what the TTS Spells tab has switched off, plus
-- the spells that start switched off. The table belongs to Core/Audio/TtsMutes and is refilled per
-- call, so use it before asking for the same category again.
---@param category string "Important", "Defensive" or "EnemyDebuff"
---@return table<number, boolean>
local function MutedSpellIds(category)
	local tts = db and db.Modules.Alerts.TTS
	local options = tts and tts[category]

	return ttsMutes:EffectiveSet(category, options and options.MutedSpellIds)
end

-- Registers one spell list's sounds for a token, appending to `ids`, or starting a new pooled list
-- when it is nil. Hoisted out of RegisterToken so the per-nameplate path doesn't build a closure.
---@param ids number[]?
---@param unitToken string
---@param list table<number, boolean> Spell ids to register.
---@param config table Sound options (File).
---@param fallbackFile string
---@param channel string The one output channel both alert categories share.
---@return number[] ids
local function RegisterAlertSoundList(ids, unitToken, list, config, fallbackFile, channel)
	return auraSounds:RegisterSet(
		ids,
		unitToken,
		list,
		addon.Core.Sounds:Resolve(config.File or fallbackFile),
		channel,
		SILENT_ALERT_SPELL_IDS
	)
end

---@param value boolean
function M:SetPaused(value)
	paused = value
end

-- Reconciles the enemy-debuff announcements on the player and party tokens. Kept apart from the
-- nameplate registrations because the tokens are fixed, and what invalidates them is the roster
-- rather than a plate coming and going. Unchanged settings do nothing, which is what lets the
-- roster event drive it directly.
---@param force boolean? Re-register even when the settings have not moved. The tokens never
---change, but a registration made against a token nobody was holding is not something the
---engine promises to keep, so a roster change redoes them.
function M:RefreshAllySounds(force)
	if not db then
		return
	end

	local tts = db.Modules.Alerts.TTS
	local enabled = (tts and tts.EnemyDebuff and tts.EnemyDebuff.Enabled) or false
	local active = enabled and moduleUtil:IsModuleEnabled(moduleName.Alerts) and not paused
	local voicePack = active and ttsPacks:Resolve(tts and tts.VoicePack) or false
	local voicePackPath = voicePack and ttsPacks:Path(voicePack) or false
	local channel = active and ((tts and tts.Channel) or "Master") or false
	local muted = MutedSpellIds("EnemyDebuff")
	settingsStamp:Begin(ALLY_SOUND_KEY)
	settingsStamp:Add(active)
	settingsStamp:Add(voicePack)
	settingsStamp:Add(voicePackPath)
	settingsStamp:Add(channel)
	settingsStamp:AddSet(mutedScratch, muted)

	local generation = settingsStamp:Commit()

	if not force and generation == allySoundGeneration then
		return
	end

	allySoundGeneration = generation

	auraSounds:RemoveSet(allySoundIds)
	allySoundIds = nil

	if not active then
		return
	end

	-- The roster rather than a fixed party1..4: a raid or a battleground puts your side on raid
	-- tokens instead, and one list means one answer to "who is on my team" across the addon.
	wipe(allyTokens)
	allyTokens[1] = "player"

	for _, token in ipairs(units:FriendlyUnits()) do
		if token ~= "player" then
			allyTokens[#allyTokens + 1] = token
		end
	end

	for _, token in ipairs(allyTokens) do
		allySoundIds = auraSounds:RegisterMappedSet(
			allySoundIds,
			token,
			addon.Core.AuraTtsSounds.EnemyDebuff,
			voicePackPath,
			channel,
			muted
		)
	end
end

-- Registers the important/defensive alert sounds for one enemy nameplate token. A no-op when
-- already registered, which is what keeps warm registrations cheap on token reuse, or when no
-- alert sound is enabled.
---@param unitToken string
function M:RegisterToken(unitToken)
	-- A sound registration matches on spell id, and a mind control makes the unit's aura list the
	-- controller's, so this would announce what landed on whoever is driving. Ahead of the warm
	-- check, since a token charmed after it registered has to lose what it already holds.
	if units:IsCharmed(unitToken) then
		self:RemoveToken(unitToken)
		return
	end
	if alertSoundsByToken[unitToken] then
		return
	end
	if paused or not moduleUtil:IsModuleEnabled(moduleName.Alerts) then
		return
	end
	local sound = db.Modules.Alerts.Sound
	local tts = db.Modules.Alerts.TTS
	local importantEnabled = sound.Important and sound.Important.Enabled
	local defensiveEnabled = sound.Defensive and sound.Defensive.Enabled
	local importantTts = tts and tts.Important and tts.Important.Enabled
	local defensiveTts = tts and tts.Defensive and tts.Defensive.Enabled
	if not importantEnabled and not defensiveEnabled and not importantTts and not defensiveTts then
		return
	end

	-- nil until the first list registers. RegisterSet then hands out a pooled handle list.
	local ids = nil
	local channel = sound.Channel or "Master"
	if importantEnabled then
		ids = RegisterAlertSoundList(ids, unitToken, addon.Core.AuraCategoryIds.Important, sound.Important, "AirHorn.ogg", channel)
	end
	if defensiveEnabled then
		ids = RegisterAlertSoundList(ids, unitToken, addon.Core.AuraCategoryIds.Defensive, sound.Defensive, "AlertToastWarm.ogg", channel)
	end
	-- The silent list is deliberately not applied here: a repeated ding is noise, but a spoken
	-- name still tells you what landed.
	if importantTts or defensiveTts then
		local packPath = ttsPacks:Path(ttsPacks:Resolve(tts and tts.VoicePack))

		-- One channel for both categories: the TTS tab is a single page, so the announcements
		-- all come out of the same output.
		local ttsChannel = (tts and tts.Channel) or "Master"

		if importantTts then
			ids = auraSounds:RegisterMappedSet(ids, unitToken, addon.Core.AuraTtsSounds.Important, packPath,
				ttsChannel, MutedSpellIds("Important"))
		end
		if defensiveTts then
			ids = auraSounds:RegisterMappedSet(ids, unitToken, addon.Core.AuraTtsSounds.Defensive, packPath,
				ttsChannel, MutedSpellIds("Defensive"))
		end
	end

	alertSoundsByToken[unitToken] = ids
end

-- Removes the engine sound registrations for one nameplate token.
---@param unitToken string
function M:RemoveToken(unitToken)
	local ids = alertSoundsByToken[unitToken]
	if not ids then
		return
	end
	alertSoundsByToken[unitToken] = nil
	auraSounds:RemoveSet(ids)
end

function M:RemoveAllTokens()
	for unitToken in pairs(alertSoundsByToken) do
		self:RemoveToken(unitToken)
	end
end

-- Drops the enemy-debuff announcements. Their tokens are not nameplates, so plate teardown never
-- reaches them and the module's own teardown calls this instead.
function M:RemoveAllySounds()
	auraSounds:RemoveSet(allySoundIds)
	allySoundIds = nil
	allySoundGeneration = nil
end

-- Re-evaluates the sound settings, rebuilding every active token's registrations when they change.
-- Token add and remove are handled incrementally at the display's acquire and release points.
---@param activeTokens table<string, any> keys are the tokens currently being drawn
function M:Refresh(activeTokens)
	-- Ahead of the nameplate settings check below, which returns early and would otherwise
	-- swallow a settings change that only the ally registrations care about.
	self:RefreshAllySounds()

	local sound = db.Modules.Alerts.Sound
	local tts = db.Modules.Alerts.TTS
	local importantEnabled = (sound.Important and sound.Important.Enabled) or false
	local defensiveEnabled = (sound.Defensive and sound.Defensive.Enabled) or false
	local importantTts = (tts and tts.Important and tts.Important.Enabled) or false
	local defensiveTts = (tts and tts.Defensive and tts.Defensive.Enabled) or false
	local active = (importantEnabled or defensiveEnabled or importantTts or defensiveTts)
		and moduleUtil:IsModuleEnabled(moduleName.Alerts)
		and not paused
	-- Only part of the stamp while something plays the clips; the pack is irrelevant otherwise.
	-- The path goes in alongside the name because an addon registering a pack later changes where
	-- the same saved name reads its clips from.
	local voicePack = (importantTts or defensiveTts) and ttsPacks:Resolve(tts and tts.VoicePack) or false
	local voicePackPath = voicePack and ttsPacks:Path(voicePack) or false
	local ttsChannel = (importantTts or defensiveTts) and ((tts and tts.Channel) or "Master") or false
	settingsStamp:Begin(ALERT_SOUND_KEY)
	settingsStamp:Add(active)
	settingsStamp:Add(importantEnabled)
	settingsStamp:Add(sound.Important and sound.Important.File)
	settingsStamp:Add(defensiveEnabled)
	settingsStamp:Add(sound.Defensive and sound.Defensive.File)
	settingsStamp:Add(sound.Channel)
	settingsStamp:Add(importantTts)
	settingsStamp:Add(defensiveTts)
	settingsStamp:Add(voicePack)
	settingsStamp:Add(voicePackPath)
	settingsStamp:Add(ttsChannel)
	settingsStamp:AddSet(mutedScratch, importantTts and MutedSpellIds("Important") or nil)
	settingsStamp:AddSet(mutedScratch, defensiveTts and MutedSpellIds("Defensive") or nil)

	local generation = settingsStamp:Commit()

	if generation == alertSoundSettingsGeneration then
		return
	end

	alertSoundSettingsGeneration = generation

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
