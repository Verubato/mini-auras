local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of Enhanced QoL party unit frames.
---@param visibleOnly boolean
---@return table
function M:EnhancedQoLFrames(visibleOnly)
	local hasAny = EQOLUFPartyHeader
	for i = 1, 8 do
		if _G["EQOLUFRaidGroupHeader" .. i] then
			hasAny = true
			break
		end
	end

	if not hasAny then
		return {}
	end

	local frames = {}
	local headers = { EQOLUFPartyHeader }

	for i = 1, 8 do
		local header = _G["EQOLUFRaidGroupHeader" .. i]
		if header then
			headers[#headers + 1] = header
		end
	end

	for _, header in ipairs(headers) do
		if header then
			for _, child in ipairs({ header:GetChildren() }) do
				local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))

				if unit and unit ~= "" then
					if (not child.IsForbidden or not child:IsForbidden()) and (child:IsVisible() or not visibleOnly) then
						frames[#frames + 1] = child
					end
				end
			end
		end
	end

	return frames
end
