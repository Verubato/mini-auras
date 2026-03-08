---@type string, Addon
local _, addon = ...
local testIsRaid = nil

---@class InstanceOptions
local M = {}

addon.Core.InstanceOptions = M

---Returns true if the current context is a raid/large group (>5 members).
---During test mode, returns the overridden value if one was set.
---@return boolean
function M:IsRaid()
	if testIsRaid ~= nil then
		return testIsRaid
	end
	return GetNumGroupMembers() > 5
end

---@param isRaid boolean?
function M:SetTestIsRaid(isRaid)
	testIsRaid = isRaid
end
