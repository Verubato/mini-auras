local _, addon = ...
local M = addon.Framework
local listener = CreateFrame("Frame")
local queued = {}
local keyed = {}

local function Flush()
	-- Snapshot before running: a callback is free to queue more work, and appending to a
	-- table mid-ipairs would either run it in the same flush or be skipped entirely.
	local pending, pendingKeyed = queued, keyed
	queued, keyed = {}, {}

	for _, callback in ipairs(pending) do
		callback()
	end

	for _, callback in pairs(pendingKeyed) do
		callback()
	end
end

listener:RegisterEvent("PLAYER_REGEN_ENABLED")
listener:SetScript("OnEvent", Flush)

---Runs the callback once combat ends, or immediately if not in combat.
---Protected APIs are unavailable in combat; deferring beats the usual "notify and give up",
---which leaves the work permanently undone.
---@param callback fun()
---@param key string? dedupe key - only the newest callback per key runs
function M:RunWhenCombatEnds(callback, key)
	if not callback then
		error("RunWhenCombatEnds - callback must not be nil.")
	end

	if not InCombatLockdown() then
		callback()
		return
	end

	if key then
		keyed[key] = callback
	else
		queued[#queued + 1] = callback
	end
end

---Whether anything is waiting on combat to end. Mostly useful in tests.
---@return boolean
function M:HasPendingCombatWork()
	return #queued > 0 or next(keyed) ~= nil
end
