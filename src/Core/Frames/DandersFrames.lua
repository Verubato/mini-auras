local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of visible DandersFrames frames.
---@return table
function M:DandersFrames()
	local frames

	if DandersFrames_GetAllFrames then
		local dandersSuccess, result = pcall(DandersFrames_GetAllFrames)
		if dandersSuccess then
			frames = result
		end
	end

	frames = frames or {}

	return frames
end
