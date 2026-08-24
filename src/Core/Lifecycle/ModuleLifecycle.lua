---@type string, Addon
local _, addon = ...

-- Edge detection for a whole module, the same trick EventGate plays for a set of events. A module's
-- Refresh runs whether or not anything moved, and enablement is what has edges.

---@class ModuleLifecycle
local M = {}
M.__index = M

addon.Core.ModuleLifecycle = M

---Creates a lifecycle in the disabled state; the first Refresh settles it.
---@param callbacks ModuleLifecycleCallbacks
---@return ModuleLifecycle
function M:New(callbacks)
	local instance = setmetatable({}, M)

	instance.GetOptions = callbacks.GetOptions
	instance.IsEnabled = callbacks.IsEnabled
	instance.Setup = callbacks.Setup
	instance.OnEnable = callbacks.OnEnable
	instance.OnDisable = callbacks.OnDisable
	instance.Apply = callbacks.Apply
	instance.Active = false
	instance.HasSetUp = false

	return instance
end

---Runs the one-time setup if it has not run yet. Called on the enable edge, and by ArmEarly.
---
---Separate from OnEnable because none of it can be taken back: hooks and observers outlive the
---module being switched off again. A module the player never switches on builds no frames,
---registers no events and installs no hooks.
function M:EnsureSetup()
	if self.HasSetUp then
		return
	end

	self.HasSetUp = true

	if self.Setup then
		self.Setup()
	end
end

---Sets the module up at load rather than waiting for the first Refresh, where its settings say it
---runs. For a module whose hooks are one-way and fire in between: a hook missed in that window can
---never be installed retrospectively. Does not enable the module, since the first Refresh still
---owns that edge.
---@return boolean armed Whether the module's settings had it running, so a caller can follow up.
function M:ArmEarly()
	if not self.IsEnabled() then
		return false
	end

	self:EnsureSetup()

	return true
end

---@return boolean
function M:IsActive()
	return self.Active
end

---Reconciles the module against its settings and the world. Cheap to call as often as anything
---that could have moved either.
function M:Refresh()
	local options

	if self.GetOptions then
		options = self.GetOptions()

		-- Settings the module cannot read yet; a later refresh will find them. Deliberately ahead
		-- of the enabled check, so a module never tears down over a missing options table.
		if options == nil then
			return
		end
	end

	local enabled = self.IsEnabled() == true

	if enabled ~= self.Active then
		self.Active = enabled

		if enabled then
			self:EnsureSetup()

			if self.OnEnable then
				self.OnEnable()
			end
		elseif self.OnDisable then
			self.OnDisable()
		end
	end

	if enabled and self.Apply then
		self.Apply(options)
	end
end

---@class ModuleLifecycleCallbacks
---@field IsEnabled fun(): boolean Whether the module should be running right now.
---@field GetOptions (fun(): table?)? Settings handed to Apply; nil skips the whole refresh.
---@field Setup fun()? Runs once, before the first OnEnable. Frames, events, hooks, observers.
---@field OnEnable fun()? The disabled to enabled edge.
---@field OnDisable fun()? The enabled to disabled edge.
---@field Apply fun(options: table)? Runs on every refresh while enabled.

---@class ModuleLifecycle
---@field GetOptions (fun(): table?)?
---@field IsEnabled fun(): boolean
---@field Setup fun()?
---@field OnEnable fun()?
---@field OnDisable fun()?
---@field Apply fun(options: table)?
---@field Active boolean
---@field HasSetUp boolean
