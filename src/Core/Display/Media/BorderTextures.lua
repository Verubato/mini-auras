---@type string, Addon
local addonName, addon = ...

-- Our own copy of the client's debuff overlay atlas, redrawn so the ring reads smooth at the
-- sizes icons are shown at. Same layout, so the cell coordinates below are unchanged.
local DISPEL_ATLAS = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Borders\\DispelBorder.blp"
-- The square cell of the atlas, as SetTexCoord's four arguments.
local DISPEL_LEFT, DISPEL_RIGHT, DISPEL_TOP, DISPEL_BOTTOM = 0.296875, 0.5703125, 0, 0.515625

---@class BorderTextures
local M = {}
addon.Core.BorderTextures = M

---Points a texture at the dispel ring. Both icon backends draw the same border.
---@param texture table
function M:ApplyDispel(texture)
	texture:SetTexture(DISPEL_ATLAS)
	texture:SetTexCoord(DISPEL_LEFT, DISPEL_RIGHT, DISPEL_TOP, DISPEL_BOTTOM)
end

---@return string
function M:GetDispelAsset()
	return DISPEL_ATLAS
end
