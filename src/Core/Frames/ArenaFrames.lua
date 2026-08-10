local _, addon = ...
local M = addon.Core.Frames
-- Arena never goes past three opponents, so the frames are walked by index.
local MAX_ARENA_FRAMES = 3

---Returns the arena enemy frame for the given index, checking known frame addons in order:
---sArena Reloaded (sArenaEnemyFrame1/2/3), ElvUI (ElvUF_Arena1/2/3),
---then Blizzard (CompactArenaFrame.memberUnitFrames[index]).
---sArena is checked first: when it is loaded it replaces the Blizzard frames.
---Nil until something has actually built the frame, which is usually not before the arena loads.
---@param index number
---@return table?
function M:GetArenaFrame(index)
	local sArena = _G["sArenaEnemyFrame" .. index]

	if sArena then
		return sArena
	end

	local elvui = _G["ElvUF_Arena" .. index]

	if elvui then
		return elvui
	end

	local blizzard = CompactArenaFrame and CompactArenaFrame.memberUnitFrames

	return blizzard and blizzard[index]
end

---Whether any arena enemy frame is on screen right now. Outside an arena nothing has usually
---built one at all, which is when the stand-ins earn their keep.
---@return boolean
function M:HasVisibleArenaFrames()
	for index = 1, MAX_ARENA_FRAMES do
		local frame = M:GetArenaFrame(index)

		if frame and frame:IsVisible() then
			return true
		end
	end

	return false
end
