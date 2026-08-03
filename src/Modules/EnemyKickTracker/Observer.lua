---@type string, Addon
local _, addon = ...

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
-- One kick per cast: the stop events fire more than once for the same interrupted cast, so the
-- first one to arrive claims it and the rest are ignored until the unit starts casting again.
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

	if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_EMPOWER_START" then
		kickedByUnits[unit] = false
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		if kickedByUnits[unit] then
			return
		end

		local kickedBy = select(4, ...)
		if not kickedBy then
			return
		end

		kickedByUnits[unit] = true
		FireKicked()
	elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
		if kickedByUnits[unit] then
			return
		end

		-- interruptedBy is arg 5 (arg 4 is "complete")
		local kickedBy = select(5, ...)
		if not kickedBy then
			return
		end

		kickedByUnits[unit] = true
		FireKicked()
	end
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
			frame:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", unit)
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
			frame:UnregisterEvent("UNIT_SPELLCAST_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_INTERRUPTED")
			frame:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
			frame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
			frame:SetScript("OnEvent", nil)
		end
		kickedByUnits[unit] = nil
	end

	watching = false
	return true
end
