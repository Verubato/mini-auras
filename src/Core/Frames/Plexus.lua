local _, addon = ...
local M = addon.Core.Frames
local childScratch = {}
local seen = {}

---Appends the Plexus raid/party unit frames from PlexusLayoutHeader frames only.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:PlexusFrames(visibleOnly, frames)
	if not PlexusLayoutHeader1 then
		return
	end

	wipe(seen)

	local headerIndex = 1

	while true do
		local header = _G["PlexusLayoutHeader" .. headerIndex]
		if not header then
			break
		end

		-- These are secure header children = actual unit buttons
		M:AppendUnitChildren(childScratch, header, visibleOnly, frames, seen)

		headerIndex = headerIndex + 1
	end
end
