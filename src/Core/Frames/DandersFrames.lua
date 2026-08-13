local _, addon = ...
local mini = addon.Framework
local M = addon.Core.Frames

---Appends the DandersFrames frames. Copied out rather than handed on: the table belongs to
---DandersFrames and is not ours to keep a reference to.
---@param frames table Frames are appended here.
function M:DandersFrames(frames)
	if not DandersFrames_GetAllFrames then
		return
	end

	local ok, result = pcall(DandersFrames_GetAllFrames)

	if not ok or type(result) ~= "table" then
		return
	end

	mini:Append(result, frames)
end
