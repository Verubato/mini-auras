---@type string, Addon
local _, addon = ...
local mini = addon.Framework

---@class FontUtil
local M = {}
addon.Utils.FontUtil = M

-- Stack counts sit in a corner and share the icon with the countdown, so they run smaller.
local STACK_COEFFICIENT = 0.38
-- The alphabets a font family carries a member for. Only the client's own locale takes the
-- configured file, so text in another script still renders from the game's files.
local FAMILY_ALPHABETS = { "roman", "korean", "simplifiedchinese", "traditionalchinese", "russian" }
local LOCALE_ALPHABETS = {
	koKR = "korean",
	zhCN = "simplifiedchinese",
	zhTW = "traditionalchinese",
	ruRU = "russian",
}

-- The file the configured face resolves to, remembered between calls: every icon asks for it on
-- every refresh and the answer only moves when the media list does.
local cachedName
local cachedFile
-- The saved variables table, kept between calls.
local cachedDb
local subscribedToFonts = false
-- One shared font object per file, size and flags, nested file -> size -> flags, each created
-- once and never re-fonted. Text attaches to one with SetFontObject rather than being handed the
-- file: the client renders a string given a font object even while the file's first load is in
-- flight, where SetFont on a cold path answers false and leaves the string as it was. Re-fonting
-- an object in place only repaints text that was about to redraw anyway, so a font change hands
-- re-applied strings a new object.
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
	if not subscribedToFonts then
		subscribedToFonts = true

		-- Core/Display/Media/Fonts loads after this file, so it is reached through the addon table.
		addon.Core.Fonts:OnChanged(function()
			cachedName = nil
			cachedDb = nil
		end)
	end

	-- Every fontstring on every icon comes through here on a restyle, and the table cannot be
	-- swapped without a refresh behind it.
	local db = cachedDb

	if not db then
		db = mini:GetSavedVars()
		cachedDb = db
	end

	local name = db and db.Font

	if not name then
		return nil
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
---after. The file is a parameter because the dropdown's preview rows ask for faces other than the
---configured one.
---
---Created through CreateFontFamily with its definition, never CreateFont plus SetFont: SetFont on
---a font object hits the same lazy file loading strings do, answering false for a file the client
---is still loading and leaving the object undefined for good. A family created with its definition
---is registered like the game's own declared fonts, so the client sees the file's load through it.
---@param file string
---@param size number
---@param flags string?
---@return table object
function M:FileFontObject(file, size, flags)
	flags = flags or ""

	-- Asked for per fontstring per restyle, so it nests rather than build a key string per call.
	local bySize = fontObjects[file]

	if not bySize then
		bySize = {}
		fontObjects[file] = bySize
	end

	local byFlags = bySize[size]

	if not byFlags then
		byFlags = {}
		bySize[size] = byFlags
	end

	local object = byFlags[flags]

	if not object then
		fontObjectCount = fontObjectCount + 1

		local name = "MiniAurasFont" .. fontObjectCount

		if CreateFontFamily then
			object = CreateFontFamily(name, FamilyMembers(file, size, flags))
		else
			-- Only an old client gets here, where the two-step is all there is.
			object = CreateFont(name)
			object:SetFont(file, size, flags)
		end

		byFlags[flags] = object
	end

	return object
end

--- Draws a fontstring in the configured font at the given size, or in its own face when nothing
--- is picked or the pick has not resolved yet. Always through a font object, never
--- FontString:SetFont, which sets instance properties that keep shadowing any object attached
--- later.
---
--- An unresolved name resolves on a later media refresh, so this falls back rather than picking a
--- default face.
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
		-- and rewriting its text is that something. Cleared first, because the client drops a
		-- SetText that changes nothing. Secret text is left alone, since the engine redraws that
		-- itself.
		local text = fontString.GetText and fontString:GetText()
		local secret = issecretvalue and issecretvalue(text)

		if not secret and text ~= nil and text ~= "" then
			fontString:SetText("")
			fontString:SetText(text)
		end
	end
end

--- The face a string was built with: what going back to "Game Default" restores, and what a
--- stand-in borrows from the string it mirrors. The face it is wearing would bake the pick in as
--- the mirror's own.
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

--- @param fontString table The font string showing the count
--- @param iconSize number The size of the icon
--- @param coefficient? number Fraction of the icon size (default: the shared stack ratio)
--- @param fontScale? number Optional font scale multiplier (default: 1.0)
function M:UpdateStackFontSize(fontString, iconSize, coefficient, fontScale)
	M:UpdateFontSize(fontString, iconSize, coefficient or STACK_COEFFICIENT, fontScale)
end

--- @param cd table The cooldown frame
--- @param iconSize number The size of the icon
--- @param coefficient? number Optional coefficient (default: 0.4)
--- @param fontScale? number Optional font scale multiplier (default: 1.0)
function M:UpdateCooldownFontSize(cd, iconSize, coefficient, fontScale)
	if not cd or not iconSize then
		return
	end

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
