---@type string, Addon
local _, addon = ...
local testIsRaid = nil

---@class InstanceOptions
local M = {}

addon.Core.InstanceOptions = M

---Whether the current context is a raid. False in arena, which reports as a raid group but is not
---a raid. Test mode answers with the override when one is set.
---@return boolean
function M:IsRaid()
	if testIsRaid ~= nil then
		return testIsRaid
	end
	local _, instanceType = IsInInstance()
	if instanceType == "arena" then
		return false
	end
	return IsInRaid()
end

---What the test preview is pretending the context is, or nil when nothing is overriding it.
---The enable gate reads this so a preview shows what the previewed context would show, rather
---than what the zone the player happens to be standing in would.
---@return boolean?
function M:GetTestIsRaid()
	return testIsRaid
end

---@param isRaid boolean?
function M:SetTestIsRaid(isRaid)
	testIsRaid = isRaid
end
