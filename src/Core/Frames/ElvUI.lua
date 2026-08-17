local _, addon = ...
local M = addon.Core.Frames
-- Two, because the subgroup walk below is nested inside the group walk.
local groupScratch = {}
local childScratch = {}
local seen = {}

---Appends a secure header's unit buttons, read from the child1..childN attributes the header
---publishes. ElvUI reads its own buttons this way rather than from GetChildren, and unlike
---frame.unit an attribute cannot go missing while a unit is still resolving.
---@param header table
---@param visibleOnly boolean
---@param frames table Frames are appended here.
---@return boolean isHeader Whether this was a secure header at all, so the caller knows when to
---fall back to walking children.
local function AppendHeaderChildren(header, visibleOnly, frames)
	if not header.GetAttribute then
		return false
	end

	local child = header:GetAttribute("child1")

	if not child then
		return false
	end

	local i = 1

	while child do
		M:AppendUnitChild(child, visibleOnly, frames, seen)

		i = i + 1
		child = header:GetAttribute("child" .. i)
	end

	return true
end

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

	if not ufSuccess or not UF or not UF.headers then
		return
	end

	wipe(seen)

	for groupName in pairs(UF.headers) do
		local group = UF[groupName]

		-- Tank and assist are headers in their own right, party and raid are plain containers
		-- holding one header per subgroup.
		if group and group.GetChildren and not AppendHeaderChildren(group, visibleOnly, frames) then
			for _, frame in ipairs(M:Children(groupScratch, group)) do
				-- Health is how ElvUI itself tells a unit button from a subgroup header.
				if frame.Health then
					M:AppendUnitChild(frame, visibleOnly, frames, seen)
				elseif not AppendHeaderChildren(frame, visibleOnly, frames) then
					M:AppendUnitChildren(childScratch, frame, visibleOnly, frames, seen)
				end
			end
		end
	end
end
