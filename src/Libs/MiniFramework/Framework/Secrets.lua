local _, addon = ...
local M = addon.Framework

---Whether the value is a secure "secret" value, which can't be compared or used as a table key.
---Always false on clients that predate secret values.
---@return boolean
function M:IsSecret(value)
	if not issecretvalue then
		return false
	end

	return issecretvalue(value)
end

---Whether this client is a version that produces secret values at all.
---@return boolean
function M:HasSecrets()
	if LE_EXPANSION_LEVEL_CURRENT == nil or LE_EXPANSION_MIDNIGHT == nil then
		return false
	end

	return LE_EXPANSION_LEVEL_CURRENT >= LE_EXPANSION_MIDNIGHT
end
