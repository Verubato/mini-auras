local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of GW2 UI unit frames.
---GW2 UI stores all spawned oUF headers in GW.GridHeaders. Each header's direct
---children are either unit buttons (have .unit) or sub-group frames (when groupingOrder
---is set), whose children are the actual unit buttons.
---@param visibleOnly boolean
---@return table
function M:GW2UIFrames(visibleOnly)
	if not GW2_ADDON or not GW2_ADDON.GridHeaders then
		return {}
	end

	local frames = {}
	local seen = {}

	local function Add(frame)
		if not frame or seen[frame] then return end
		if frame.IsForbidden and frame:IsForbidden() then return end
		if visibleOnly and not frame:IsVisible() then return end
		seen[frame] = true
		frames[#frames + 1] = frame
	end

	for _, header in ipairs(GW2_ADDON.GridHeaders) do
		for _, child in ipairs({ header:GetChildren() }) do
			local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))
			if unit and unit ~= "" then
				Add(child)
			else
				-- sub-group frame - walk one level deeper
				for _, grandchild in ipairs({ child:GetChildren() }) do
					local gcUnit = grandchild.unit or (grandchild.GetAttribute and grandchild:GetAttribute("unit"))
					if gcUnit and gcUnit ~= "" then
						Add(grandchild)
					end
				end
			end
		end
	end

	return frames
end
