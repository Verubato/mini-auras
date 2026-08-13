local _, addon = ...
local M = addon.Core.Frames
-- Two, because the subgroup walk below is nested inside the group walk.
local groupScratch = {}
local childScratch = {}

---Appends the ElvUI unit frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:ElvUIFrames(visibleOnly, frames)
	if not ElvUI then
		return
	end

	---@diagnostic disable-next-line: deprecated
	local elvuiSuccess, E = pcall(unpack, ElvUI)

	if not elvuiSuccess or not E then
		return
	end

	local ufSuccess, UF = pcall(E.GetModule, E, "UnitFrames")

	if not ufSuccess or not UF then
		return
	end

	for groupName in pairs(UF.headers) do
		local group = UF[groupName]
		if group and group.GetChildren then
			for _, frame in ipairs(M:Children(groupScratch, group)) do
				-- is this a unit frame or a subgroup?
				if not frame.Health then
					for _, child in ipairs(M:Children(childScratch, frame)) do
						if child.unit and (child:IsVisible() or not visibleOnly) then
							frames[#frames + 1] = child
						end
					end
				elseif frame.unit and (frame:IsVisible() or not visibleOnly) then
					frames[#frames + 1] = frame
				end
			end
		end
	end
end
