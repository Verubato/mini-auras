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

	for _, header in ipairs(GW2_ADDON.GridHeaders) do
		for _, child in ipairs(M:Children(childScratch, header)) do
			if not M:AppendUnitChild(child, visibleOnly, frames, seen) then
				-- A sub-group frame, so walk one level deeper.
				M:AppendUnitChildren(grandchildScratch, child, visibleOnly, frames, seen)
			end
		end
	end
end
