---@type string, Addon
local _, addon = ...

---@class CcManager
local M = {}

addon.CcManager = M

---Returns a potentially secret number if any of the specified headers have CC applied.
---@param watchers Watcher|Watcher[]
---@return number 0 or 1
function M:IsCcAppliedAlpha(watchers)
	local list = watchers[1] ~= nil and watchers or { watchers }
	local result = 0

	for _, watcher in ipairs(list) do
		local info = watcher:GetCcState()

		if type(info.IsCcApplied) == "boolean" then
			if info.IsCcApplied then
				result = 1
				break
			end
		elseif type(info.IsCcApplied) == "table" then
			-- collapse the set of secret booleans into a 1 or 0
			local ev = C_CurveUtil.EvaluateColorValueFromBoolean

			---@diagnostic disable-next-line: param-type-mismatch
			for _, isCCApplied in ipairs(info.IsCcApplied) do
				result = ev(isCCApplied, 1, result)
			end
		end
	end

	return result
end
