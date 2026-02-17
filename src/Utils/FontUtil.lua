---@type string, Addon
local _, addon = ...

---@class FontUtil
local M = {}
addon.Utils.FontUtil = M

--- Updates the cooldown frame's countdown text font size based on icon size
--- @param cd table The cooldown frame
--- @param iconSize number The size of the icon
--- @param coefficient? number Optional coefficient (default: 0.4)
--- @param fontScale? number Optional font scale multiplier (default: 1.0)
function M:UpdateCooldownFontSize(cd, iconSize, coefficient, fontScale)
	if not cd or not iconSize then
		return
	end

	coefficient = coefficient or 0.4
	fontScale = fontScale or 1.0

	local fontSize = math.floor(iconSize * coefficient * fontScale)

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
