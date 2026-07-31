local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of MidnightSimpleUnitFrames (MSUF) unit frames.
---MSUF registers all its unit frames (player, target, focus, pet, party1-4,
---raid1-40, boss1-5, arena1-5, etc.) in _G.MSUF_UnitFrames, keyed by unit
---@param visibleOnly boolean
---@return table
function M:MSUFFrames(visibleOnly)
	local registry = _G.MSUF_UnitFrames
	if type(registry) ~= "table" then
		return {}
	end

	local frames = {}

	for _, frame in pairs(registry) do
		if frame
			and (not frame.IsForbidden or not frame:IsForbidden())
			and frame.unit
			and (frame.unit:match("^party%d") or frame.unit:match("^raid%d"))
			and (not visibleOnly or frame:IsVisible())
		then
			frames[#frames + 1] = frame
		end
	end

	return frames
end
