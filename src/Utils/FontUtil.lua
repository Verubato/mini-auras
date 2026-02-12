---@type string, Addon
local _, addon = ...

---@class FontUtil
local M = {}
addon.Utils.FontUtil = M

--- Updates the cooldown frame's countdown text font size based on icon size
--- @param cd table The cooldown frame
--- @param iconSize number The size of the icon
--- @param coefficient? number Optional coefficient (default: 0.4)
function M:UpdateCooldownFontSize(cd, iconSize, coefficient)
	if not cd or not iconSize then
		return
	end

	coefficient = coefficient or 0.4
	local fontSize = math.max(8, math.floor(iconSize * coefficient + 0.5))

	-- Get the FontString region from the cooldown frame
	local numRegions = cd:GetNumRegions()
	for i = 1, numRegions do
		local region = select(i, cd:GetRegions())
		if region and region.GetObjectType and region:GetObjectType() == "FontString" then
			local font, _, flags = region:GetFont()
			if font then
				region:SetFont(font, fontSize, flags)
			end
			break
		end
	end
end
