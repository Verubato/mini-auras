-- MiniAuras External API v1
-- Exposes a stable global (MiniAurasApi.v1) for other addons to register callbacks.
---@type string, Addon
local _, addon = ...

local fcdModule = addon.Modules.FriendlyCooldowns.Module
local framesCore = addon.Core.Frames
local ttsPacks = addon.Core.TtsPacks
local alertsModule = addon.Modules.AlertsModule

---@alias MiniAurasSpellType "Defensive"
---@alias MiniAurasPredictedCallback fun(unit: string, spellId: number, spellType: MiniAurasSpellType)
---@alias MiniAurasMatchedCallback fun(unit: string, spellId: number, spellType: MiniAurasSpellType)
---@alias MiniAurasRefreshCallback fun()

---External frame provider spec passed to MiniAurasApiV1:RegisterFrameProvider.
---@class MiniAurasApiV1
---@field RegisterPredictedCallback fun(self: MiniAurasApiV1, fn: MiniAurasPredictedCallback)
---@field RegisterMatchedCallback fun(self: MiniAurasApiV1, fn: MiniAurasMatchedCallback)
---@field RegisterFrameProvider fun(self: MiniAurasApiV1, provider: MiniAurasFrameProvider)
---@field RegisterVoicePack fun(self: MiniAurasApiV1, pack: MiniAurasVoicePack): boolean
local v1 = {}

---Registers a callback invoked when MiniAuras predicts a friendly cooldown is about to start
---(i.e. the associated buff has been detected on the unit).
---@param fn MiniAurasPredictedCallback
function v1:RegisterPredictedCallback(fn)
	fcdModule:RegisterPredictedCallback(fn)
end

---Registers a callback invoked when MiniAuras commits a matched cooldown rule
---(i.e. the aura has ended and the cooldown timer has started).
---@param fn MiniAurasMatchedCallback
function v1:RegisterMatchedCallback(fn)
	fcdModule:RegisterMatchedCallback(fn)
end

---Registers an external frame provider. Frames returned by `GetFrames()` are
---included alongside MiniAuras's built-in frame sources (ElvUI, Cell, Blizzard, etc.)
---and receive the same icon/cooldown/glow treatment.
---@param provider MiniAurasFrameProvider
function v1:RegisterFrameProvider(provider)
	framesCore:RegisterProvider(provider)
end

---Registers a voice pack for the pre-recorded alert announcements. The name joins the shipped
---voices in the alerts TTS dropdown and its clips play the same way.
---@param pack MiniAurasVoicePack
---@return boolean registered false when the spec is unusable or the name is already taken
function v1:RegisterVoicePack(pack)
	if type(pack) ~= "table" then
		return false
	end

	local registered = ttsPacks:Register(pack.Name, pack.Path, pack.Locales)

	if registered then
		-- A pack registered after login only reaches the engine when the alert sound
		-- registrations are rebuilt. Refresh does nothing until the module has its frames, so
		-- this is safe however early the caller runs.
		alertsModule:Refresh()
	end

	return registered
end

---@class MiniAurasApi
---@field v1 MiniAurasApiV1
MiniAurasApi = MiniAurasApi or {}
MiniAurasApi.v1 = v1

-- Addons written against the old name keep working. Same table, so a caller that grabbed either
-- global sees the same callbacks. Drop this once the ecosystem has moved over.
MiniCCApi = MiniAurasApi

---@class MiniAurasFrameProvider
---@field Name string Unique identifier for the provider.
---@field GetFrames fun(): table Returns an array of unit frames to anchor icons onto.
---@field RegisterRefreshFrames? fun(cb: MiniAurasRefreshCallback) Optional; MiniAuras calls this once at registration, passing a callback the provider should invoke whenever its frame list changes.

---@class MiniAurasVoicePack
---@field Name string Label shown in the voice dropdown and stored in the saved settings, so it must be unique and stable.
---@field Path string Base folder holding the pack's clips, e.g. "Interface\\AddOns\\YourAddon\\Sounds\\". It must contain one OGG per clip, named exactly as the files in MiniAuras's own Sounds\\TTS packs (extension included): one per Important and Defensive spell name, plus PreviewVoice.ogg, PreviewImportant.ogg and PreviewDefensive.ogg for the config previews.
---@field Locales? string[] Client locales the pack is spoken for, matched against GetLocale(), e.g. { "deDE" }. Omit it to offer the pack on every client. The name stays reserved either way, so the same saved value always means the same pack.
