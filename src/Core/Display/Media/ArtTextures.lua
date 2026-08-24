---@type string, Addon
local _, addon = ...
local artTextureData = addon.Core.ArtTextureData

-- The art a texture aura can draw, and the one place that paints it: the proc overlays the game
-- itself flashes beside a unit, hand-picked in ArtTextureData.

-- Corner offsets from the middle of the texture, in the order SetTexCoord's eight-number form
-- takes them: upper left, lower left, upper right, lower right. Y grows downwards.
local CORNERS = {
	{ -0.5, -0.5 }, { -0.5, 0.5 }, { 0.5, -0.5 }, { 0.5, 0.5 },
}
local DEGREES_TO_RADIANS = math.pi / 180
-- How much of the list the client has to admit to owning before its answers are believed. A build
-- drops the odd file; one that claims to have almost none of them is not answering the question.
local MIN_RESOLVED_SHARE = 0.25
local ALERTS_FAMILY = "Alerts"
-- The whole of a texture, which is what everything that is not an atlas element uses.
local FULL_RECT = { 0, 1, 0, 1 }
-- What a group drawing art starts with, so picking the texture shape shows something rather than
-- an empty space nobody can position. Maelstrom Weapon, by file id, named rather than "the first
-- one in the list" so re-ordering the list cannot change it.
local DEFAULT_ASSET = 450927

---@type ArtTextureEntry[]?
local entries
---@type table<string|number, ArtTextureEntry>?
local byAsset
-- Atlas name -> its corner of the sheet, or false for one this build does not have. Its file id
-- is kept alongside rather than in the same table, so the miss case can stay a plain false.
local atlasCache = {}
local atlasFiles = {}
-- Refilled by Coords on every call, so painting a texture allocates nothing.
local coordScratch = {}
-- Refilled by Filter, which the picker calls on every keystroke.
local matchScratch = {}

---@class ArtTextures
local M = {}

addon.Core.ArtTextures = M

---Whether the client has a file, for builds that can answer. One that cannot leaves everything
---in the list: an empty picker is a worse answer than one with a few dead entries in it.
---
---Art is held as a file id, which outlives the path that names it. The path is kept only for this
---check, and anything typed by hand stays as typed, a path or an atlas name.
---@param path string
---@return boolean
local function Resolvable(path)
	if not GetFileIDFromPath then
		return true
	end

	return GetFileIDFromPath(path) ~= nil
end

---What an atlas element is: the sheet holding it, and the corner of that sheet it occupies.
---Cached, since the answer cannot change within a session and this is asked per restyle.
---@param name string
---@return table? rect { left, right, top, bottom } texture coordinates, nil when unknown.
---@return number? file The sheet's file id.
local function AtlasRect(name)
	local cached = atlasCache[name]

	if cached ~= nil then
		return cached ~= false and cached or nil, cached ~= false and atlasFiles[name] or nil
	end

	local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name)

	if not info or not info.file then
		atlasCache[name] = false

		return nil
	end

	local rect = {
		info.leftTexCoord or 0, info.rightTexCoord or 1,
		info.topTexCoord or 0, info.bottomTexCoord or 1,
	}

	atlasCache[name] = rect
	atlasFiles[name] = info.file

	return rect, info.file
end

---Whether a value names an atlas element rather than a file. Atlas names carry no folder and no
---extension, which is what tells the two apart. A hand-typed name works either way round.
---@param asset string|number
---@return boolean
local function IsAtlasName(asset)
	return type(asset) == "string" and not asset:find("[\\/]") and not asset:find("%.%w+$")
end

local function Build()
	local list = {}
	local client = {}
	local index = {}

	-- The list is short on purpose. The client's wider effect library and its atlas art both looked
	-- wrong hung off a nameplate, so the picker's path field is how anyone reaches the rest.
	for _, row in ipairs(artTextureData.Alerts) do
		local entry = {
			Asset = row[1],
			Label = row[2],
			Path = row[3],
			Family = ALERTS_FAMILY,
		}

		index[entry.Asset] = entry
		client[#client + 1] = entry
	end

	local present = {}
	local kept = 0

	for position, entry in ipairs(client) do
		present[position] = Resolvable(entry.Path)
		kept = kept + (present[position] and 1 or 0)
	end

	-- A handful of survivors means the check is lying rather than the client being bare, so the
	-- whole of its list stands. A list that looks fine can come out four entries long on a real
	-- client, with nothing to say why.
	local trust = kept >= #client * MIN_RESOLVED_SHARE

	for position, entry in ipairs(client) do
		if present[position] or not trust then
			list[#list + 1] = entry
		end
	end

	byAsset = index
	entries = list
end

---@return ArtTextureEntry[]
local function Entries()
	if not entries then
		Build()
	end

	return entries
end

---A readable name for whatever a group has chosen: the label the list carries for a file id, or
---the file name for a path somebody typed.
---@param asset string|number?
---@return string
function M:Label(asset)
	if asset == nil or asset == "" then
		return ""
	end

	Entries()

	local entry = byAsset[asset]

	if entry then
		return entry.Label
	end

	if type(asset) == "number" then
		return "#" .. asset
	end

	local name = asset:match("([^\\/]+)$") or asset

	name = name:gsub("%.%w+$", ""):gsub("[_%-]", " ")

	return (name:gsub("(%a[%w']*)", function(word)
		return word:sub(1, 1):upper() .. word:sub(2):lower()
	end))
end

---Every texture on offer, built once. Callers must not keep the table: it is the module's own.
---@return ArtTextureEntry[]
function M:GetEntries()
	return Entries()
end

---The art a group that has not picked any starts with. Answered without building the list, since
---this is asked of every group at load.
---@return string|number
function M:DefaultAsset()
	return DEFAULT_ASSET
end

---The entries whose label carries every word of the query, in list order. A word at a time
---rather than the whole string, so "blue rune" finds "Aura Rune Blue".
---Hands back its own shared table, refilled per call.
---@param query string?
---@return ArtTextureEntry[]
function M:Filter(query)
	local all = Entries()
	local out = matchScratch

	wipe(out)

	query = type(query) == "string" and query:lower():gsub("^%s+", ""):gsub("%s+$", "") or ""

	if query == "" then
		for index = 1, #all do
			out[index] = all[index]
		end

		return out
	end

	for _, entry in ipairs(all) do
		local label = entry.Label:lower()
		local matched = true

		for word in query:gmatch("%S+") do
			if not label:find(word, 1, true) then
				matched = false
				break
			end
		end

		if matched then
			out[#out + 1] = entry
		end
	end

	return out
end

---The eight texture coordinates for a quad turned by an angle and optionally flipped. Pure maths
---and no frames, so the awkward part of this file is testable on its own.
---
---Computed as coordinates rather than left to SetRotation, because both write the same four
---corners and a mirrored texture would lose its mirror the moment it was also turned.
---@param rotation number? Degrees, clockwise.
---@param mirror boolean? Flip left to right, applied before the turn.
---@return number[] coords The shared scratch, in SetTexCoord's UL, LL, UR, LR order.
function M:Coords(rotation, mirror)
	local angle = (tonumber(rotation) or 0) * DEGREES_TO_RADIANS
	local cos = math.cos(angle)
	local sin = math.sin(angle)
	local flip = mirror and -1 or 1
	local out = coordScratch

	-- Turned the opposite way to the corners, because moving where a corner samples from turns the
	-- picture the other way: sampling further right draws what was on the right further left.
	for index, corner in ipairs(CORNERS) do
		local x = corner[1] * flip
		local y = corner[2]

		out[index * 2 - 1] = 0.5 + x * cos + y * sin
		out[index * 2] = 0.5 - x * sin + y * cos
	end

	return out
end

---Puts one piece of art on a texture, with none of the styling around it. Shared by the picker's
---own cells, which show the art as it comes.
---
---An atlas element is set as its sheet plus the corner it lives in, rather than through SetAtlas:
---the two write the same texture coordinates, and going through the coordinates is what lets the
---art be turned and mirrored like everything else.
---@param texture table
---@param asset string|number? An atlas name, a file id, or a path.
---@return number[]? rect The part of the texture the art occupies, nil when nothing was drawn.
function M:SetAsset(texture, asset)
	if asset == nil or asset == "" then
		texture:SetTexture(nil)

		return nil
	end

	if IsAtlasName(asset) then
		local rect, file = AtlasRect(asset)

		if not rect then
			texture:SetTexture(nil)

			return nil
		end

		texture:SetTexture(file)
		texture:SetTexCoord(rect[1], rect[3], rect[1], rect[4], rect[2], rect[3], rect[2], rect[4])

		return rect
	end

	texture:SetTexture(asset)
	texture:SetTexCoord(0, 0, 0, 1, 1, 0, 1, 1)

	return FULL_RECT
end

---Paints one texture with a group's art settings. Shared by the live aura buttons and the
---stand-ins the options page draws, so the preview is the same picture as the real thing.
---@param texture table
---@param spec ArtTextureSpec
function M:Apply(texture, spec)
	local rect = M:SetAsset(texture, spec.Asset)

	if not rect then
		texture:Hide()

		return
	end

	texture:SetBlendMode(spec.Additive and "ADD" or "BLEND")
	texture:SetDesaturated(spec.Desaturate == true)
	texture:SetVertexColor(spec.R or 1, spec.G or 1, spec.B or 1, spec.A or 1)

	local coords = M:Coords(spec.Rotation, spec.Mirror)
	local left, right, top, bottom = rect[1], rect[2], rect[3], rect[4]
	local width, height = right - left, bottom - top

	-- The turn is worked out over the whole of a texture and then folded into whatever part of it
	-- the art actually occupies, so an atlas element turns exactly like a file does.
	texture:SetTexCoord(
		left + coords[1] * width, top + coords[2] * height,
		left + coords[3] * width, top + coords[4] * height,
		left + coords[5] * width, top + coords[6] * height,
		left + coords[7] * width, top + coords[8] * height)
	texture:Show()
end

---@class ArtTextureEntry
---@field Asset string|number What draws: an atlas name, a file id, or a path.
---@field Label string
---@field Path string? Client art only, and only to ask whether this build has the file.
---@field Family string

---@class ArtTextureSpec
---@field Asset string|number? File id or path; empty or missing hides the texture.
---@field R number?
---@field G number?
---@field B number?
---@field A number?
---@field Rotation number? Degrees, clockwise.
---@field Mirror boolean?
---@field Desaturate boolean?
---@field Additive boolean? ADD blending, which is what the client's own overlay art expects.

---@class ArtTextures
---@field Label fun(self: table, asset: string|number?): string
---@field GetEntries fun(self: table): ArtTextureEntry[]
---@field DefaultAsset fun(self: table): string|number
---@field Filter fun(self: table, query: string?): ArtTextureEntry[]
---@field Coords fun(self: table, rotation: number?, mirror: boolean?): number[]
---@field SetAsset fun(self: table, texture: table, asset: string|number?): boolean
---@field Apply fun(self: table, texture: table, spec: ArtTextureSpec)
