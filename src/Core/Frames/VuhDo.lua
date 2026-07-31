local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of VuhDo unit frames.
---VuhDo panel frames are globals named Vd1, Vd2, … up to 10.
---Unit buttons are direct children; the unit token is in :GetAttribute("unit") or button.raidid.
---@param visibleOnly boolean
---@return table
function M:VuhDoFrames(visibleOnly)
	if not _G["Vd1"] then
		return {}
	end

	local frames = {}
	local seen = {}

	local panelNum = 1
	while true do
		local panel = _G["Vd" .. panelNum]
		if not panel then break end

		for _, child in ipairs({ panel:GetChildren() }) do
			if not seen[child] then
				local unit = (child.GetAttribute and child:GetAttribute("unit")) or child.raidid
				if unit and unit ~= "" then
					if (not child.IsForbidden or not child:IsForbidden()) and (child:IsVisible() or not visibleOnly) then
						seen[child] = true
						frames[#frames + 1] = child
					end
				end
			end
		end

		panelNum = panelNum + 1
	end

	return frames
end

---Returns true if the frame is a VuhDo unit button.
---Used to decide whether to bump strata so FCD icons render above VuhDo frame elements.
---@param frame table
---@return boolean
function M:IsVuhDoFrame(frame)
	if not frame or issecretvalue(frame) then
		return false
	end
	if frame:IsForbidden() then
		return false
	end
	local name = frame:GetName()
	return name ~= nil and string.find(name, "^Vd%d+H%d+") ~= nil
end
