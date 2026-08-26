local _, addon = ...
local M = addon.Core.Frames
-- Arena never goes past three opponents, so the frames are walked by index.
local MAX_ARENA_FRAMES = 3

---The arena enemy frame an addon built: sArena Reloaded (sArenaEnemyFrame1/2/3) or ElvUI
---(ElvUF_Arena1/2/3). Both build theirs at login and hold its size and scale while hidden, so one
---can be measured before an arena starts.
---@param index number
---@return table?
function M:GetAddonArenaFrame(index)
	return _G["sArenaEnemyFrame" .. index] or _G["ElvUF_Arena" .. index]
end

---Returns the arena enemy frame for the given index, an addon's first and Blizzard's
---(CompactArenaFrame.memberUnitFrames[index]) after, since a loaded addon replaces those.
---Nil until something has actually built the frame, which is usually not before the arena loads.
---@param index number
---@return table?
function M:GetArenaFrame(index)
	local addonFrame = M:GetAddonArenaFrame(index)

	if addonFrame then
		return addonFrame
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
