-- MiniAuras External API v1
-- Exposes a stable global (MiniAurasApi.v1) for other addons to register callbacks.
---@type string, Addon
local _, addon = ...

local fcdModule = addon.Modules.FriendlyCooldowns.Module
local framesCore = addon.Core.Frames

---@alias MiniAurasSpellType "Defensive"
---@alias MiniAurasPredictedCallback fun(unit: string, spellId: number, spellType: MiniAurasSpellType)
---@alias MiniAurasMatchedCallback fun(unit: string, spellId: number, spellType: MiniAurasSpellType)
---@alias MiniAurasRefreshCallback fun()

---External frame provider spec passed to MiniAurasApiV1:RegisterFrameProvider.
---@class MiniAurasApiV1
---@field RegisterPredictedCallback fun(self: MiniAurasApiV1, fn: MiniAurasPredictedCallback)
---@field RegisterMatchedCallback fun(self: MiniAurasApiV1, fn: MiniAurasMatchedCallback)
---@field RegisterFrameProvider fun(self: MiniAurasApiV1, provider: MiniAurasFrameProvider)
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
