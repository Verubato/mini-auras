local _, addon = ...
local M = addon.Core.Frames
local MAX_PARTY = MAX_PARTY_MEMBERS or 4
local MAX_RAID = MAX_RAID_MEMBERS or 40

---Appends the Grid2 unit frames.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:Grid2Frames(visibleOnly, frames)
	if not Grid2 or not Grid2.GetUnitFrames then
		return
	end

	local playerSuccess, playerFrames = pcall(Grid2.GetUnitFrames, Grid2, "player")
	local playerFrame = playerSuccess and playerFrames and next(playerFrames)

	if playerFrame and (playerFrame:IsVisible() or not visibleOnly) then
		frames[#frames + 1] = playerFrame
	end

	for i = 1, MAX_PARTY do
		local partySuccess, partyFrames = pcall(Grid2.GetUnitFrames, Grid2, "party" .. i)
		local frame = partySuccess and partyFrames and next(partyFrames)

		if not frame then
			break
		end

		if frame:IsVisible() or not visibleOnly then
			frames[#frames + 1] = frame
		end
	end

	for i = 1, MAX_RAID do
		local raidSuccess, raidFrames = pcall(Grid2.GetUnitFrames, Grid2, "raid" .. i)
		local frame = raidSuccess and raidFrames and next(raidFrames)

		if frame and (frame:IsVisible() or not visibleOnly) then
			frames[#frames + 1] = frame
		end
	end
end
