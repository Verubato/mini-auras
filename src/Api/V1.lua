-- MiniCC External API v1
-- Exposes a stable global (MiniCCApi.v1) for other addons to register callbacks.
---@type string, Addon
local _, addon = ...

local fcdModule = addon.Modules.FriendlyCooldowns.Module
local framesCore = addon.Core.Frames

---@alias MiniCCSpellType "Defensive"
---@alias MiniCCPredictedCallback fun(unit: string, spellId: number, spellType: MiniCCSpellType)
---@alias MiniCCMatchedCallback fun(unit: string, spellId: number, spellType: MiniCCSpellType)
---@alias MiniCCRefreshCallback fun()

---External frame provider spec passed to MiniCCApiV1:RegisterFrameProvider.
---@class MiniCCFrameProvider
---@field Name string Unique identifier for the provider.
---@field GetFrames fun(): table Returns an array of unit frames to anchor icons onto.
---@field RegisterRefreshFrames? fun(cb: MiniCCRefreshCallback) Optional; MiniCC calls this once at registration, passing a callback the provider should invoke whenever its frame list changes.

---@class MiniCCApiV1
---@field RegisterPredictedCallback fun(self: MiniCCApiV1, fn: MiniCCPredictedCallback)
---@field RegisterMatchedCallback fun(self: MiniCCApiV1, fn: MiniCCMatchedCallback)
---@field RegisterFrameProvider fun(self: MiniCCApiV1, provider: MiniCCFrameProvider)
local v1 = {}

---Registers a callback invoked when MiniCC predicts a friendly cooldown is about to start
---(i.e. the associated buff has been detected on the unit).
---@param fn MiniCCPredictedCallback
function v1:RegisterPredictedCallback(fn)
	fcdModule:RegisterPredictedCallback(fn)
end

---Registers a callback invoked when MiniCC commits a matched cooldown rule
---(i.e. the aura has ended and the cooldown timer has started).
---@param fn MiniCCMatchedCallback
function v1:RegisterMatchedCallback(fn)
	fcdModule:RegisterMatchedCallback(fn)
end

---Registers an external frame provider. Frames returned by `GetFrames()` are
---included alongside MiniCC's built-in frame sources (ElvUI, Cell, Blizzard, etc.)
---and receive the same icon/cooldown/glow treatment.
---@param provider MiniCCFrameProvider
function v1:RegisterFrameProvider(provider)
	framesCore:RegisterProvider(provider)
end

---@class MiniCCApi
---@field v1 MiniCCApiV1
MiniCCApi = MiniCCApi or {}
MiniCCApi.v1 = v1
