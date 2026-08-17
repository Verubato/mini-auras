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
-- One shared font object per size-and-flags pair, each wearing the configured file. Text drawn
-- in the picked font attaches to these with SetFontObject rather than being handed the file:
-- the client re-renders attached strings itself whenever an object changes, including when the
-- file's first load of the session finishes - where SetFont with a cold path answers false,
-- leaves the string as it was, and repaints on nothing, which is what made a font change land
-- on some text and silently miss the rest. Sizes derive from icon sizes, so the set stays small.
local fontObjects = {}
local fontObjectCount = 0

---Puts a new file on every shared object. The strings attached to them follow on their own -
---this is the whole of what changing the font has to do for text already on screen.
---@param file string?
local function ApplyFileToObjects(file)
	if not file then
		return
	end

	for _, entry in pairs(fontObjects) do
		entry.Object:SetFont(file, entry.Size, entry.Flags)
	end
end

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
		end)
	end

	if name ~= cachedName then
		cachedName = name

		local file = addon.Core.Fonts:Resolve(name)

		if file ~= cachedFile then
			cachedFile = file
			ApplyFileToObjects(file)
		end
	end

	return cachedFile
end

---The shared object for this size and flags, created on first need wearing the current file.
---Only called while a file is resolved: see Apply.
---@param size number
---@param flags string?
---@return table object
local function GetFontObject(size, flags)
	flags = flags or ""

	local key = size .. "|" .. flags
	local entry = fontObjects[key]

	if not entry then
		fontObjectCount = fontObjectCount + 1
		entry = {
			Object = CreateFont("MiniAurasFont" .. fontObjectCount),
			Size = size,
			Flags = flags,
		}
		entry.Object:SetFont(cachedFile, size, flags)
		fontObjects[key] = entry
	end

	return entry.Object
end

--- Draws a fontstring in the configured font at the given size, or leaves it on its own face
--- when nothing is picked or the pick has not resolved yet. The one entry point for the option:
--- picked, the string is attached to a shared font object; not picked, it keeps or gets back
--- the face it was built with. That second case is why this falls back rather than picking a
--- default face - the media refresh comes round again once the name resolves, and swaps then.
--- @param fontString table
--- @param size number? point size; nil keeps the size the string was built with
--- @param flags string? font flags; nil keeps the flags the string was built with
--- @param fallbackFace string? face for the unpicked state, when the string stands in for
--- another and must wear that one's face rather than its own
function M:Apply(fontString, size, flags, fallbackFace)
	if not fontString then
		return
	end

	-- The face to go back to is only readable while the string is not wearing the pick, which is
	-- why it is captured here, before anything is applied, and never while attached.
	if fontString.MiniAurasBaseFace == nil and not fontString.MiniAurasAttached then
		local face, baseSize, baseFlags = fontString:GetFont()

		if face then
			fontString.MiniAurasBaseFace = face
			fontString.MiniAurasBaseSize = baseSize
			fontString.MiniAurasBaseFlags = baseFlags
		end
	end

	size = size or fontString.MiniAurasBaseSize
	flags = flags or fontString.MiniAurasBaseFlags

	if not size then
		return
	end

	if M:CurrentFace() then
		fontString.MiniAurasAttached = true
		fontString:SetFontObject(GetFontObject(size, flags))
	else
		local face = fallbackFace or fontString.MiniAurasBaseFace

		fontString.MiniAurasAttached = nil

		if face then
			fontString:SetFont(face, size, flags)
		end
	end
end

--- The face a string was built with: what going back to "Game Default" restores, and what a
--- stand-in borrows from the string it mirrors - borrowing the WORN face would bake the pick in
--- as the mirror's own.
--- @param fontString table
--- @param face string? the face to answer for a string that has never been through Apply
--- @return string? face
function M:BaseFace(fontString, face)
	if not fontString then
		return face
	end

	if fontString.MiniAurasBaseFace then
		return fontString.MiniAurasBaseFace
	end

	-- Never been through Apply, so what it wears is its own.
	if not fontString.MiniAurasAttached then
		return face or fontString:GetFont()
	end

	return face
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

	-- SetFont errors on height <= 0, and a not-yet-laid-out icon can floor to zero.
	local fontSize = math.max(1, math.floor(iconSize * (coefficient or 0.4) * (fontScale or 1.0)))

	M:Apply(fontString, fontSize)
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

	M:UpdateFontSize(cd.MiniAurasFontString, iconSize, coefficient, fontScale)
end
