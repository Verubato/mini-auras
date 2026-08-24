---@type string, Addon
local _, addon = ...

-- Edge-detected register/unregister gate over a fixed set of events on one frame, so disabled
-- modules receive no event dispatch at all.
--
-- SetActive is safe to call from a level-triggered Refresh, since a repeated call with the same
-- state is a no-op. Only the gate's own events are touched, so always-registered gate-driver
-- events can share the same frame.

---@class EventGate
local M = {}
M.__index = M

addon.Core.EventGate = M

---Creates an inactive gate; call SetActive to register the events.
---@param eventsFrame table Frame the events are registered on (the script handler stays the caller's).
---@param events string[] Events to keep registered while active.
---@param callbacks { OnActivate: fun()?, OnDeactivate: fun()? }? OnActivate runs after registering, OnDeactivate after unregistering.
---@return EventGate
function M:New(eventsFrame, events, callbacks)
	local instance = setmetatable({}, M)

	instance.Frame = eventsFrame
	instance.Events = events
	instance.OnActivate = callbacks and callbacks.OnActivate or nil
	instance.OnDeactivate = callbacks and callbacks.OnDeactivate or nil
	instance.Active = false

	return instance
end

---@param active boolean
function M:SetActive(active)
	active = active == true

	if active == self.Active then
		return
	end

	self.Active = active

	if active then
		for _, event in ipairs(self.Events) do
			self.Frame:RegisterEvent(event)
		end
		if self.OnActivate then
			self.OnActivate()
		end
	else
		for _, event in ipairs(self.Events) do
			self.Frame:UnregisterEvent(event)
		end
		if self.OnDeactivate then
			self.OnDeactivate()
		end
	end
end

---@return boolean
function M:IsActive()
	return self.Active
end

---@class EventGate
---@field Frame table
---@field Events string[]
---@field OnActivate fun()?
---@field OnDeactivate fun()?
---@field Active boolean
