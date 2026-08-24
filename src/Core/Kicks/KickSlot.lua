---@type string, Addon
local _, addon = ...

-- Kick lockouts are not auras, so on 12.1 they cannot render through an AuraContainer alongside
-- the aura icons. Every module that shows one keeps a one-slot IconSlotContainer for it and chains
-- the aura display after it, and since no aura event fires when the lockout ends, the slot needs
-- its own expiry timer.

---@class KickSlot
local M = {}

addon.Core.KickSlot = M

-- Small grace period so the slot is cleared just after the lockout has actually elapsed, rather
-- than a frame early.
local EXPIRY_GRACE = 0.05

---Renders a kick lockout into slot 1 of an IconSlotContainer and schedules onExpired shortly
---after the lockout ends. Cancels previousTimer; returns the new timer (nil when there is
---nothing to wait for). Pass kickEntry nil to clear the slot.
---@param container IconSlotContainer
---@param kickEntry table?
---@param slotOptions table? SetSlot options for the kick icon (required when kickEntry is set).
---@param previousTimer table?
---@param onExpired fun()
---@return table? timer
function M:Render(container, kickEntry, slotOptions, previousTimer, onExpired)
	if previousTimer then
		previousTimer:Cancel()
	end

	if not kickEntry then
		container:SetSlotUnused(1)
		return nil
	end

	container:SetSlot(1, slotOptions)

	return M:ScheduleExpiry(kickEntry, nil, onExpired)
end

---Schedules onExpired for when a kick lockout ends, cancelling previousTimer first. Split out
---for callers that render the slot themselves (the nameplates module writes the icon into every
---enabled bar, but only needs one timer for the plate).
---@param kickEntry table?
---@param previousTimer table?
---@param onExpired fun()
---@return table? timer
function M:ScheduleExpiry(kickEntry, previousTimer, onExpired)
	if previousTimer then
		previousTimer:Cancel()
	end

	if not kickEntry then
		return nil
	end

	local remaining = (kickEntry.StartTime or 0) + (kickEntry.Duration or 0) - GetTime()
	if remaining <= 0 then
		return nil
	end

	return C_Timer.NewTimer(remaining + EXPIRY_GRACE, onExpired)
end
