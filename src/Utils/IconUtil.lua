---@type string, Addon
local _, addon = ...
local mini = addon.Framework

-- How much of a spell icon Blizzard's baked silver border takes up. Cropping it off is what
-- makes an icon sit flush against a border of ours instead of carrying two.
local ICON_TRIM = 0.08

---@class IconUtil
local M = {}
addon.Utils.IconUtil = M

---The crop every spell icon is drawn with, as SetTexCoord's four arguments. Uncropped for
---anyone who would rather keep Blizzard's border.
---@return number left, number right, number top, number bottom
function M:TexCoord()
	local db = mini:GetSavedVars()

	if db and db.IconZoom == false then
		return 0, 1, 0, 1
	end

	return ICON_TRIM, 1 - ICON_TRIM, ICON_TRIM, 1 - ICON_TRIM
end
