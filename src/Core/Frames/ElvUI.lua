local _, addon = ...
local M = addon.Core.Frames

---Retrieves a list of ElvUI frames.
---@param visibleOnly boolean
---@return table
function M:ElvUIFrames(visibleOnly)
	if not ElvUI then
		return {}
	end

	---@diagnostic disable-next-line: deprecated
	local elvuiSuccess, E = pcall(unpack, ElvUI)

	if not elvuiSuccess or not E then
		return {}
	end

	local ufSuccess, UF = pcall(E.GetModule, E, "UnitFrames")

	if not ufSuccess or not UF then
		return {}
	end

	local frames = {}

	for groupName in pairs(UF.headers) do
		local group = UF[groupName]
		if group and group.GetChildren then
			local groupFrames = { group:GetChildren() }

			for _, frame in ipairs(groupFrames) do
				-- is this a unit frame or a subgroup?
				if not frame.Health then
					local children = { frame:GetChildren() }

					for _, child in ipairs(children) do
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

	return frames
end
