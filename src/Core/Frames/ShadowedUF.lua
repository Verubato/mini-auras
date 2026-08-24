local _, addon = ...
local M = addon.Core.Frames
local MAX_PARTY = MAX_PARTY_MEMBERS or 4
local MAX_RAID = MAX_RAID_MEMBERS or 40

---Appends the Shadowed Unit Frames (SUF) unit frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:ShadowedUFFrames(visibleOnly, frames)
	if not SUFUnitplayer and not SUFHeaderpartyUnitButton1 and not SUFHeaderraidUnitButton1 then
		return
	end

	local function Add(frame)
		if not frame then
			return
		end
		if frame.IsForbidden and frame:IsForbidden() then
			return
		end
		if (not visibleOnly) or frame:IsVisible() then
			frames[#frames + 1] = frame
		end
	end

	-- Party and raid header buttons: SUFHeaderpartyUnitButton# and SUFHeaderraidUnitButton#.
	for i = 1, MAX_PARTY do
		Add(_G["SUFHeaderpartyUnitButton" .. i])

		-- Some layouts/forks also expose party as SUFUnitparty#
		Add(_G["SUFUnitparty" .. i])
	end

	for i = 1, MAX_RAID do
		Add(_G["SUFHeaderraidUnitButton" .. i])

		-- Some layouts/forks also expose raid as SUFUnitraid#
		Add(_G["SUFUnitraid" .. i])
	end
end
