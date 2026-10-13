---@type string, Addon
local _, addon = ...

---@class InspectorFacade
local M = {}
addon.Core.InspectorFacade = M

---Returns the spec ID for a unit using a best-effort fallback chain:
---  1. FrameSort (most authoritative, real-time)
---  2. Internal Inspector (tooltip + async inspect queue)
---@param unit string
---@return number|nil
function M:GetUnitSpecId(unit)
	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Inspector then
		local id = fs.Inspector:GetUnitSpecId(unit)
		if id then
			return id
		end
	end

	return addon.Core.Inspector:GetUnitSpecId(unit)
end
