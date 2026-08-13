local _, addon = ...
local M = addon.Core.Frames
-- Two, because the sub-group walk below is nested inside the header walk.
local childScratch = {}
local grandchildScratch = {}
local seen = {}

---Appends the GW2 UI unit frames.
---GW2 UI stores all spawned oUF headers in GW.GridHeaders. Each header's direct
---children are either unit buttons (have .unit) or sub-group frames (when groupingOrder
---is set), whose children are the actual unit buttons.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:GW2UIFrames(visibleOnly, frames)
	if not GW2_ADDON or not GW2_ADDON.GridHeaders then
		return
	end

	wipe(seen)

	local function Add(frame)
		if not frame or seen[frame] then return end
		if frame.IsForbidden and frame:IsForbidden() then return end
		if visibleOnly and not frame:IsVisible() then return end
		seen[frame] = true
		frames[#frames + 1] = frame
	end

	for _, header in ipairs(GW2_ADDON.GridHeaders) do
		for _, child in ipairs(M:Children(childScratch, header)) do
			local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))
			if unit and unit ~= "" then
				Add(child)
			else
				-- sub-group frame - walk one level deeper
				for _, grandchild in ipairs(M:Children(grandchildScratch, child)) do
					local gcUnit = grandchild.unit or (grandchild.GetAttribute and grandchild:GetAttribute("unit"))
					if gcUnit and gcUnit ~= "" then
						Add(grandchild)
					end
				end
			end
		end
	end
end
