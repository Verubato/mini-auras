local _, addon = ...
local M = addon.Core.Framework
local eventsFrame = CreateFrame("Frame")

local combatEndCallbacks = {}
local combatEndKeyedCallbacks = {}

local function OnCombatEnded()
	for _, callback in ipairs(combatEndCallbacks) do
		callback()
	end

	for _, callback in pairs(combatEndKeyedCallbacks) do
		callback()
	end

	wipe(combatEndCallbacks)
	wipe(combatEndKeyedCallbacks)
end

---Invokes the callback once combat ends.
---@param key string? an optional key which will ensure only the latest callback provided with the same key will be executed.
---@param callback fun()
function M:RunWhenCombatEnds(callback, key)
	if not callback then
		return
	end

	if not InCombatLockdown() then
		callback()
		return
	end

	if key then
		combatEndKeyedCallbacks[key] = callback
	else
		combatEndCallbacks[#combatEndCallbacks + 1] = callback
	end
end

eventsFrame:SetScript("OnEvent", OnCombatEnded)
eventsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
