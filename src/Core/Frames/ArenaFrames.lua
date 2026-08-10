local _, addon = ...
local M = addon.Core.Frames

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
