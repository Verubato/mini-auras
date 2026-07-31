local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of TPerl party unit frames.
---@param visibleOnly boolean
---@return table
function M:TPerlFrames(visibleOnly)
	if not TPerl_Party_SecureHeader then
		return {}
	end

	local frames = {}

	for _, child in ipairs({ TPerl_Party_SecureHeader:GetChildren() }) do
		local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))

		if unit and unit ~= "" then
			if (not child.IsForbidden or not child:IsForbidden()) and (child:IsVisible() or not visibleOnly) then
				frames[#frames + 1] = child
			end
		end
	end

	return frames
end
