---@type string, Addon
local _, addon = ...
local kickTracker = addon.Core.KickTracker

addon.Modules.Portrait = addon.Modules.Portrait or {}

---@class PortraitObserver
local M = {}
addon.Modules.Portrait.Observer = M

-- Callbacks that re-render each container attached to a unit, filled as portraits are attached.
-- Only target and focus have any, since they are the only portraits whose occupant changes.
---@type table<string, fun()[]>
local unitUpdateFns = {}

---@param unit string
---@param callback fun()
function M:RegisterUnitUpdate(unit, callback)
	unitUpdateFns[unit] = unitUpdateFns[unit] or {}
	local fns = unitUpdateFns[unit]
	fns[#fns + 1] = callback
end

---@param unit string
function M:FireUnitUpdate(unit)
	local fns = unitUpdateFns[unit]
	if not fns then
		return
	end

	for _, fn in ipairs(fns) do
		fn()
	end
end

---A kick landing on the target or focus has to redraw that portrait, and no aura event covers it.
function M:WatchKicks()
	for _, unit in ipairs({ "target", "focus" }) do
		local event = unit == "target" and "PLAYER_TARGET_CHANGED" or "PLAYER_FOCUS_CHANGED"
		kickTracker:Watch(unit, { event })
		kickTracker:Subscribe(unit, function()
			M:FireUnitUpdate(unit)
		end)
	end
end
