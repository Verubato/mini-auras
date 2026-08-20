local _, addon = ...
local M = addon.Framework

---Whether the value is a secure "secret" value, which can't be compared or used as a table key.
---Always false on clients that predate secret values.
---
---Bound once rather than branching per call: this sits on hot paths in several addons, and
---whether the client has the api at all is settled before any of them run.
---@type fun(self: table, value: any): boolean
M.IsSecret = issecretvalue
	and function(_, value)
		return issecretvalue(value)
	end
	or function()
		return false
	end

---Whether this client is a version that produces secret values at all.
---@return boolean
function M:HasSecrets()
	if LE_EXPANSION_LEVEL_CURRENT == nil or LE_EXPANSION_MIDNIGHT == nil then
		return false
	end

	return LE_EXPANSION_LEVEL_CURRENT >= LE_EXPANSION_MIDNIGHT
end
