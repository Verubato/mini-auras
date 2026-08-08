---@type string, Addon
local _, addon = ...

---@class FontUtil
local M = {}
addon.Utils.FontUtil = M

-- Stack counts sit in a corner and share the icon with the countdown, so they run smaller.
local STACK_COEFFICIENT = 0.3

--- Updates any font string's size from the icon size, keeping its font face and flags.
--- @param fontString table
--- @param iconSize number
--- @param coefficient? number Fraction of the icon size (default: 0.4, the countdown ratio)
--- @param fontScale? number Optional font scale multiplier (default: 1.0)
function M:UpdateFontSize(fontString, iconSize, coefficient, fontScale)
	if not fontString or not iconSize then
		return
	end

	local font, _, flags = fontString:GetFont()

	if not font then
		return
	end

	-- SetFont errors on height <= 0, and a not-yet-laid-out icon can floor to zero.
	local fontSize = math.max(1, math.floor(iconSize * (coefficient or 0.4) * (fontScale or 1.0)))
	fontString:SetFont(font, fontSize, flags)
end

--- Updates a stack count's font size based on icon size
--- @param fontString table The font string showing the count
--- @param iconSize number The size of the icon
--- @param fontScale? number Optional font scale multiplier (default: 1.0)
function M:UpdateStackFontSize(fontString, iconSize, fontScale)
	M:UpdateFontSize(fontString, iconSize, STACK_COEFFICIENT, fontScale)
end

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

	-- SetFont errors on height <= 0; a degenerate icon size (e.g. anchor not yet laid out) can floor to 0.
	local fontSize = math.max(1, math.floor(iconSize * coefficient * fontScale))

	-- Scan once, cache result on the cooldown frame
	if not cd.MiniAurasFontString then
		local numRegions = cd:GetNumRegions()
		for i = 1, numRegions do
			local region = select(i, cd:GetRegions())
			if region and region:GetObjectType() == "FontString" then
				cd.MiniAurasFontString = region
				break
			end
		end
	end

	local region = cd.MiniAurasFontString
	if region then
		local font, _, flags = region:GetFont()
		if font then
			region:SetFont(font, fontSize, flags)
		end
	end
end
