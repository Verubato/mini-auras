---@type string, Addon
local _, addon = ...

-- One cast being cut short arrives as several flavours of stop event, with the interrupter at a
-- different argument position per flavour. Every kick consumer decodes the same shape, so the
-- decode lives here; policy (dedup, filtering, what a kick means) stays with the consumers.
--
-- The interrupter is a GUID and is secret inside instances: test it for nil/truthiness only,
-- never read, compare or key a table with it.

---@class KickEvents
local M = {}

addon.Core.KickEvents = M

-- The events that mark a cast (re)starting, i.e. the moment per-cast dedup state resets.
M.StartEvents = {
	"UNIT_SPELLCAST_START",
	"UNIT_SPELLCAST_CHANNEL_START",
	"UNIT_SPELLCAST_EMPOWER_START",
}

-- The events that can report a cast ending early. They also fire for casts that simply ended;
-- GetInterrupter answering nil is what tells those apart.
M.StopEvents = {
	"UNIT_SPELLCAST_INTERRUPTED",
	"UNIT_SPELLCAST_CHANNEL_STOP",
	"UNIT_SPELLCAST_EMPOWER_STOP",
}

local START_EVENTS = {}
for _, event in ipairs(M.StartEvents) do
	START_EVENTS[event] = true
end

---True for the events in StartEvents.
---@param event string
---@return boolean
function M:IsStart(event)
	return START_EVENTS[event] == true
end

---Decodes a stop event's payload: the interrupter (nil when the cast merely ended, or when the
---event is not a stop event) and the spell that was cut short. Both may be secret values.
---@param event string
---@param ... any the payload after the event name: unit, castGUID, spellId, ...
---@return any interruptedBy
---@return any spellId
function M:GetInterrupter(event, ...)
	if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		local _, _, spellId, interruptedBy = ...

		return interruptedBy, spellId
	end

	if event == "UNIT_SPELLCAST_EMPOWER_STOP" then
		-- The empower flavour inserts a "complete" flag at arg 4, pushing the interrupter to 5.
		local _, _, spellId, _, interruptedBy = ...

		return interruptedBy, spellId
	end

	return nil, nil
end
