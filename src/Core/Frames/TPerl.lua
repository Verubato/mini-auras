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

	for _, child in ipairs(M:Children(childScratch, TPerl_Party_SecureHeader)) do
		local unit = child.unit or (child.GetAttribute and child:GetAttribute("unit"))

		if unit and unit ~= "" then
			if (not child.IsForbidden or not child:IsForbidden()) and (child:IsVisible() or not visibleOnly) then
				frames[#frames + 1] = child
			end
		end
	end
end
