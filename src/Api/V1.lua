-- MiniAuras's external API. Exposes a stable global, MiniAurasApi.v1, for other addons to register
-- callbacks.
---@type string, Addon
local _, addon = ...

local mini = addon.Framework
local framesCore = addon.Core.Frames
local moduleUtil = addon.Utils.ModuleUtil
local ttsPacks = addon.Core.TtsPacks
local alertsModule = addon.Modules.AlertsModule

---Neither cooldown callback can fire any more: they were fed by the friendly cooldown tracker, and
---12.1 removed addon access to the ally aura data it inferred from. The methods stay so a caller
---written against them still loads, and each warns once, naming itself, so the author can drop it.
local deprecationWarned = {}

-- On our own next frame rather than in the caller's stack: the alert sounds are registered with a
-- restricted API the engine refuses to a foreign addon's execution.
local QueueAlertsRefresh = moduleUtil:Coalesced(function()
	alertsModule:Refresh()
end)

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

---@param name string
local function WarnDeprecated(name)
	if deprecationWarned[name] then
		return
	end

	deprecationWarned[name] = true
	mini:NotifyWithPrefix(("MiniAurasApi.v1:%s is deprecated and no longer fires: cooldown tracking was removed in 12.1."):format(name))
end

---Deprecated no-op, for the friendly cooldown prediction 12.1 took away.
---@deprecated
---@param fn MiniAurasPredictedCallback
function v1:RegisterPredictedCallback(fn) -- luacheck: no unused args
	WarnDeprecated("RegisterPredictedCallback")
end

---Deprecated no-op, for the matched cooldown rules 12.1 took away.
---@deprecated
---@param fn MiniAurasMatchedCallback
function v1:RegisterMatchedCallback(fn) -- luacheck: no unused args
	WarnDeprecated("RegisterMatchedCallback")
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
		QueueAlertsRefresh()
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
---@field Path string Base folder holding the pack's clips, e.g. "Interface\\AddOns\\YourAddon\\Sounds\\". It must contain one OGG per clip, named exactly as the files in MiniAuras's own Sounds\\TTS packs (extension included): one per Important, Defensive and enemy-debuff spell name, plus PreviewVoice.ogg, PreviewImportant.ogg, PreviewDefensive.ogg and PreviewEnemyDebuff.ogg for the config previews.
---@field Locales? string[] Client locales the pack is spoken for, matched against GetLocale(), e.g. { "deDE" }. Omit it to offer the pack on every client. The name stays reserved either way, so the same saved value always means the same pack.
