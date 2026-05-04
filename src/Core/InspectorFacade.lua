---@type string, Addon
local _, addon = ...

---@class InspectorFacade
local M = {}
addon.Core.InspectorFacade = M

---Returns the spec ID for a unit using a best-effort fallback chain:
---  1. FrameSort (most authoritative, real-time)
---  2. Internal Inspector (tooltip + async inspect queue)
---  3. GetArenaOpponentSpec for arena1-9 units
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

	local id = addon.Core.Inspector:GetUnitSpecId(unit)
	if id then
		return id
	end

	local arenaIndex = unit:match("^arena(%d)$")
	if arenaIndex then
		local arenaId = GetArenaOpponentSpec and GetArenaOpponentSpec(tonumber(arenaIndex))
		if arenaId and arenaId > 0 then
			return arenaId
		end
	end

	return nil
end
