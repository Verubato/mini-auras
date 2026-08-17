---@type string, Addon
local _, addon = ...
local mini = addon.Framework

---@class FontUtil
local M = {}
addon.Utils.FontUtil = M

-- Stack counts sit in a corner and share the icon with the countdown, so they run smaller.
local STACK_COEFFICIENT = 0.38
-- The alphabets a font family carries a member for. The configured file only overrides the
-- member for the client's own locale; the rest keep the game's files, so text in another script
-- - a Cyrillic name in a group, say - never renders as boxes because the picked face lacks it.
local FAMILY_ALPHABETS = { "roman", "korean", "simplifiedchinese", "traditionalchinese", "russian" }
local LOCALE_ALPHABETS = {
	koKR = "korean",
	zhCN = "simplifiedchinese",
	zhTW = "traditionalchinese",
	ruRU = "russian",
}

-- The file the configured face resolves to, remembered between calls: every icon asks for it on
-- every refresh and the answer only moves when the media list does. Core/Display/Fonts loads
-- after this file, so it is reached through the addon table rather than an upvalue.
local cachedName
local cachedFile
local subscribedToFonts = false
-- One shared font object per file, size and flags combination, each created once and never
-- re-fonted. Text drawn in a font attaches to one of these with SetFontObject rather than being
-- handed the file: the client renders a string given a font object even when the file's first
-- load is still in flight, where SetFont with a cold path answers false, leaves the string as
-- it was, and repaints on nothing. Never re-fonted is load-bearing too: a font change hands
-- re-applied strings a DIFFERENT object, because editing an object a string already holds only
-- repainted text that was about to redraw anyway - countdowns followed a change while a static
-- warning kept its old face, which read as the option working for some text and not the rest.
local fontObjects = {}
local fontObjectCount = 0

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
		cachedFile = addon.Core.Fonts:Resolve(name)
	end

	return cachedFile
end

---The family members for a file at a size: the file itself for the client's own locale, the
---game's per-alphabet files for the rest.
---@param file string
---@param size number
---@param flags string
---@return table[] members
local function FamilyMembers(file, size, flags)
	local override = LOCALE_ALPHABETS[GetLocale()] or "roman"
	local members = {}

	for _, alphabet in ipairs(FAMILY_ALPHABETS) do
		local memberFile = file

		if alphabet ~= override and GameFontNormal and GameFontNormal.GetFontObjectForAlphabet then
			local gameObject = GameFontNormal:GetFontObjectForAlphabet(alphabet)

			memberFile = (gameObject and gameObject:GetFont()) or file
		end

		members[#members + 1] = {
			alphabet = alphabet,
			file = memberFile,
			height = size,
			flags = flags,
		}
	end

	return members
end

---The shared object for this file at this size and flags, created on first need and immutable
---after: see the note on fontObjects. Also serves the dropdown's per-font preview rows, which
---is why the file is a parameter rather than always the configured one.
---
---Created through CreateFontFamily, definition and all, never CreateFont plus SetFont: SetFont
---on a font object hits the same lazy file loading strings do - false for a file the client is
---still loading, leaving the object undefined for good - where a family created WITH its
---definition is registered like the game's own declared fonts, and the client sees the file's
---load through itself. That difference is why one session's pick used to land whole on the
---fallback face while another's worked: it hung on whether some other addon had already loaded
---the file before the object was built.
---@param file string
---@param size number
---@param flags string?
---@return table object
function M:FileFontObject(file, size, flags)
	flags = flags or ""

	local key = file .. "|" .. size .. "|" .. flags
	local object = fontObjects[key]

	if not object then
		fontObjectCount = fontObjectCount + 1

		local name = "MiniAurasFont" .. fontObjectCount

		if CreateFontFamily then
			object = CreateFontFamily(name, FamilyMembers(file, size, flags))
		else
			-- Nothing but an old client gets here; the two-step is all it has.
			object = CreateFont(name)
			object:SetFont(file, size, flags)
		end

		fontObjects[key] = object
	end

	return object
end

--- Draws a fontstring in the configured font at the given size, or in its own face when
--- nothing is picked or the pick has not resolved yet. The one entry point for the option, and
--- always through a font object, never FontString:SetFont: an explicit SetFont sets instance
--- properties that keep shadowing whatever object is attached later, which is how a string
--- first touched with no font picked stayed on the game face for the session after a pick. The
--- unpicked state is simply a family built from the string's own base face. Falling back
--- rather than picking a default face is deliberate - the media refresh comes round again once
--- an unresolved name resolves, and swaps then.
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

	local file = M:CurrentFace()
	local face = file or fallbackFace or fontString.MiniAurasBaseFace

	fontString.MiniAurasAttached = file ~= nil or nil

	if not face then
		return
	end

	local object = M:FileFontObject(face, size, flags)

	if (fontString.GetFontObject and fontString:GetFontObject()) ~= object then
		fontString:SetFontObject(object)

		-- A string keeps drawing its old glyphs after SetFontObject until something dirties it,
		-- and rewriting its text is that something. Text that rewrites anyway - the captions,
		-- every countdown - repaints on its own, but a static warning is written once ever.
		-- Cleared first, because the client drops a SetText that changes nothing, which is
		-- exactly what this text is. Secret text is left alone: it belongs to the engine, which
		-- redraws it itself.
		local text = fontString.GetText and fontString:GetText()

		if text ~= nil and text ~= "" and not (issecretvalue and issecretvalue(text)) then
			fontString:SetText("")
			fontString:SetText(text)
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
