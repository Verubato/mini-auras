local _, addon = ...
local M = addon.Core.Frames
local childScratch = {}
local headers = {}

---Appends the Enhanced QoL party unit frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:EnhancedQoLFrames(visibleOnly, frames)
	wipe(headers)
	headers[#headers + 1] = EQOLUFPartyHeader

	for i = 1, 8 do
		headers[#headers + 1] = _G["EQOLUFRaidGroupHeader" .. i]
	end

	for _, header in ipairs(headers) do
		for _, child in ipairs(M:Children(childScratch, header)) do
			local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))

			if unit and unit ~= "" then
				if (not child.IsForbidden or not child:IsForbidden()) and (child:IsVisible() or not visibleOnly) then
					frames[#frames + 1] = child
				end
			end
		end
	end
end
