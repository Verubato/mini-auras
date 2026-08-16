---@type string, Addon
local _, addon = ...
local mini = addon.Framework

---@class FontUtil
local M = {}
addon.Utils.FontUtil = M

-- Stack counts sit in a corner and share the icon with the countdown, so they run smaller.
local STACK_COEFFICIENT = 0.38

-- The file the configured face resolves to, remembered between calls: every icon asks for it on
-- every refresh and the answer only moves when the media list does. Core/Display/Fonts loads
-- after this file, so it is reached through the addon table rather than an upvalue.
local cachedName
local cachedFile
local subscribedToFonts = false

--- The file the font option resolves to right now, or nil when no font is picked or the pick
--- belongs to a media addon that has not registered it yet.
---
--- A display whose style has not otherwise moved still has to notice this changing, so it goes
--- into the style comparisons as a plain value: see StyleDiffersFromStored in
--- Core/Auras/AuraContainerDisplay.
--- @return string? file
function M:CurrentFace()
	local db = mini:GetSavedVars()
	local name = db and db.Font

	if not name then
		return nil
	end

	if not subscribedToFonts then
		subscribedToFonts = true

		addon.Core.Fonts:OnChanged(function()
			cachedName = nil
			cachedFile = nil
		end)
	end

	if name ~= cachedName then
		cachedName = name
		cachedFile = addon.Core.Fonts:Resolve(name)
	end

	return cachedFile
end

--- The face a string was built with, which is what the option being cleared has to go back to.
--- Remembered on the string itself, and only ever from a face that is not already an override:
--- once a string is wearing the picked font, asking it what it wears would remember the pick as
--- if the game had given it, and clearing the option would then "restore" that same pick.
--- @param fontString table
--- @param face string? the face to remember, when the caller knows it is untouched
--- @return string? face
function M:BaseFace(fontString, face)
	if not fontString then
		return face
	end

	local base = fontString.MiniAurasBaseFace

	if base then
		return base
	end

	base = face or fontString:GetFont()

	-- Never remember the configured face as a base. A string whose first pass through here
	-- happens with a font already picked has no recoverable face of its own; leaving it unset
	-- means the next pass with no pick will remember the real one.
	if base and base ~= M:CurrentFace() then
		fontString.MiniAurasBaseFace = base
	end

	return base
end

--- The face every module's text is drawn in: the one the user picked, or the face the string was
--- built with whenever nothing is picked or the pick has not been registered yet. That second
--- case is why this falls back rather than picking a default face - the media refresh comes round
--- again once the name resolves, and swaps it then.
--- @param fontString table
--- @param currentFace string? the untouched face, when the caller knows it
--- @return string? face
function M:Face(fontString, currentFace)
	if not fontString then
		return currentFace
	end

	-- Before the pick is consulted, not after: `or` would short-circuit past it while a font is
	-- picked, and the string's own face would then only ever be read once it is already wearing
	-- the pick - which is the one moment it is not worth remembering.
	local base = M:BaseFace(fontString, currentFace)

	return M:CurrentFace() or base
end

--- Updates any font string's size from the icon size, keeping its flags and taking the
--- configured font face.
--- @param fontString table
--- @param iconSize number
--- @param coefficient? number Fraction of the icon size (default: 0.4, the countdown ratio)
--- @param fontScale? number Optional font scale multiplier (default: 1.0)
function M:UpdateFontSize(fontString, iconSize, coefficient, fontScale)
	if not fontString or not iconSize then
		return
	end

	local font, _, flags = fontString:GetFont()

	font = M:Face(fontString, font)

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
		font = M:Face(region, font)
		if font then
			region:SetFont(font, fontSize, flags)
		end
	end
end
