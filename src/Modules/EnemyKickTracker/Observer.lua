---@type string, Addon
local _, addon = ...
local kickEvents = addon.Core.KickEvents

addon.Modules.EnemyKickTracker = addon.Modules.EnemyKickTracker or {}

---@class EnemyKickTrackerObserver
local M = {}
addon.Modules.EnemyKickTracker.Observer = M

-- Only the arena team's casts can tell us an enemy kick went out, and an arena team is at most
-- three. Watching anyone else would count interrupts the bar is not there to show.
local WATCHED_UNITS = {
	"player",
	"party1",
	"party2",
}

---@type table<string, table>
local eventFrames = {}
-- The stop events fire more than once for the same interrupted cast, so the first to arrive
-- claims it and the rest are ignored until the unit starts casting again.
---@type table<string, boolean>
local kickedByUnits = {}
---@type fun()[]
local kickCallbacks = {}
local paused = false
local watching = false

local function FireKicked()
	for _, fn in ipairs(kickCallbacks) do
		fn()
	end
end

---@param unit string
---@param event string
local function OnUnitEvent(unit, _, event, ...)
	if paused then
		return
	end

	if kickEvents:IsStart(event) then
		kickedByUnits[unit] = false
		return
	end

	if kickedByUnits[unit] then
		return
	end

	local kickedBy = kickEvents:GetInterrupter(event, ...)
	if not kickedBy then
		return
	end

	kickedByUnits[unit] = true
	FireKicked()
end

---Builds the per-unit event frames. Nothing is registered until Enable.
function M:Create()
	for _, unit in ipairs(WATCHED_UNITS) do
		eventFrames[unit] = eventFrames[unit] or CreateFrame("Frame")
	end
end

---@param callback fun()
function M:RegisterKickCallback(callback)
	kickCallbacks[#kickCallbacks + 1] = callback
end

---Stops firing callbacks without unregistering anything, so test mode can take the bar over and
---hand it straight back.
---@param value boolean
function M:SetPaused(value)
	paused = value
end

---@return boolean changed true only on the transition into watching
function M:Enable()
	if watching then
		return false
	end

	for _, unit in ipairs(WATCHED_UNITS) do
		local frame = eventFrames[unit]
		if frame then
			for _, event in ipairs(kickEvents.StartEvents) do
				frame:RegisterUnitEvent(event, unit)
			end
			for _, event in ipairs(kickEvents.StopEvents) do
				frame:RegisterUnitEvent(event, unit)
			end
			frame:SetScript("OnEvent", function(...)
				OnUnitEvent(unit, ...)
			end)
		end
	end

	watching = true
	return true
end

---@return boolean changed true only on the transition out of watching
function M:Disable()
	if not watching then
		return false
	end

	for _, unit in ipairs(WATCHED_UNITS) do
		local frame = eventFrames[unit]
		if frame then
			for _, event in ipairs(kickEvents.StartEvents) do
				frame:UnregisterEvent(event)
			end
			for _, event in ipairs(kickEvents.StopEvents) do
				frame:UnregisterEvent(event)
			end
			frame:SetScript("OnEvent", nil)
		end
		kickedByUnits[unit] = nil
	end

	watching = false
	return true
end
