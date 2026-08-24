local _, addon = ...
local M = addon.Core.Frames
local childScratch = {}
local seen = {}

---Appends the VuhDo unit frames.
---VuhDo panel frames are globals named Vd1, Vd2, ... up to 10.
---Unit buttons are direct children; the unit token is in :GetAttribute("unit") or button.raidid.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:VuhDoFrames(visibleOnly, frames)
	if not _G["Vd1"] then
		return
	end

	wipe(seen)

	local panelNum = 1
	while true do
		local panel = _G["Vd" .. panelNum]
		if not panel then break end

		for _, child in ipairs(M:Children(childScratch, panel)) do
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
end

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
