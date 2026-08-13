local _, addon = ...
local M = addon.Core.Frames
local childScratch = {}

---Appends the TPerl party unit frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:TPerlFrames(visibleOnly, frames)
	if not TPerl_Party_SecureHeader then
		return
	end

	M:AppendUnitChildren(childScratch, TPerl_Party_SecureHeader, visibleOnly, frames)
end
