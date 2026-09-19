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

---Whether this client produces secret values at all. A Classic client can carry the 12.x
---interface, so the expansion level cannot tell.
---@return boolean
function M:HasSecrets()
	-- Mists Classic shares the engine, so the predicate alone does not settle it.
	return WOW_PROJECT_ID ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE and issecretvalue ~= nil
end
