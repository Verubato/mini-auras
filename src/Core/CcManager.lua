---@type string, Addon
local _, addon = ...

---@class CcManager
local M = {}

addon.CcManager = M

---Returns a potentially secret number if any of the specified headers have CC applied.
---@param headers table|table[]
---@return number 0 or 1
function M:IsCcAppliedAlpha(headers)
	local list = headers[1] ~= nil and headers or { headers }
	local result = 0

	for _, header in ipairs(list) do
		if type(header.IsCcApplied) == "boolean" then
			if header.IsCcApplied then
				result = 1
				break
			end
		elseif type(header.IsCcApplied) == "table" then
			-- collapse the set of secret booleans into a 1 or 0
			local ev = C_CurveUtil.EvaluateColorValueFromBoolean

			-- just to be safe
			for _, isCCApplied in ipairs(header.IsCcApplied) do
				result = ev(isCCApplied, 1, result)
			end
		end
	end

	return result
end
