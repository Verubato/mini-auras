local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of Plexus raid/party unit frames from PlexusLayoutHeader frames only.
---@param visibleOnly boolean
---@return table
function M:PlexusFrames(visibleOnly)
	-- Plexus must be loaded
	if not PlexusLayoutHeader1 then
		return {}
	end

	local frames = {}
	local seen = {}

	local function Add(frame)
		if not frame then
			return
		end
		if seen[frame] then
			return
		end
		if frame.IsForbidden and frame:IsForbidden() then
			return
		end
		if visibleOnly and not frame:IsVisible() then
			return
		end

		seen[frame] = true
		frames[#frames + 1] = frame
	end

	local headerIndex = 1

	while true do
		local header = _G["PlexusLayoutHeader" .. headerIndex]
		if not header then
			break
		end

		-- These are secure header children = actual unit buttons
		for _, child in ipairs({ header:GetChildren() }) do
			local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))

			if unit and unit ~= "" then
				Add(child)
			end
		end

		headerIndex = headerIndex + 1
	end

	return frames
end
