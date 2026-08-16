-- The art catalog and the one place a texture is painted. Two things are worth guarding: the
-- list has to survive a client that cannot answer whether a file exists (an empty picker is
-- worse than one with dead entries in it), and the rotation maths has to compose with mirroring,
-- which is the whole reason the coordinates are computed here rather than left to SetRotation.

local fw = require("Framework")

local addon = { Core = {}, Utils = {} }
assert(loadfile("src/Core/Display/ArtTextureData.lua"))("MiniAuras", addon)
assert(loadfile("src/Core/Display/ArtTextures.lua"))("MiniAuras", addon)
local artTextures = addon.Core.ArtTextures

-- One of the game's proc overlays, by the file id it has carried since it was added.
local RIME = 450930

---A stand-in texture recording what was last applied to it.
---@return table
local function NewTexture()
	local texture = { Shown = true }

	function texture:SetTexture(value)
		self.Texture = value
	end

	function texture:SetBlendMode(value)
		self.BlendMode = value
	end

	function texture:SetDesaturated(value)
		self.Desaturated = value
	end

	function texture:SetVertexColor(r, g, b, a)
		self.Color = { r, g, b, a }
	end

	function texture:SetTexCoord(...)
		self.Coords = { ... }
	end

	function texture:Show()
		self.Shown = true
	end

	function texture:Hide()
		self.Shown = false
	end

	return texture
end

---@param actual number
---@param expected number
---@param label string
local function Near(actual, expected, label)
	assert(math.abs(actual - expected) < 1e-6,
		label .. ": expected " .. expected .. ", got " .. tostring(actual))
end

fw.describe("ArtTextures - the list", function()
	fw.it("offers the hand-picked proc overlays and nothing else", function()
		local entries = artTextures:GetEntries()
		local rime = false

		-- Short on purpose, but not empty: a handful of entries would mean the generated file did
		-- not load, or the client answered no to nearly all of it.
		assert(#entries > 10, "the picked list, got " .. #entries)

		for _, entry in ipairs(entries) do
			assert(entry.Family == "Alerts", "one family: " .. tostring(entry.Family))
			assert(type(entry.Asset) == "number", "art is held as a file id")
			rime = rime or entry.Asset == RIME
		end

		assert(rime, "including the one the tests below paint")
	end)

	fw.it("defaults to art that is on the list", function()
		local default = artTextures:DefaultAsset()

		assert(artTextures:Label(default) ~= "", "a group starts on something the picker knows")
	end)

	fw.it("names an entry from the list, and a path from its file", function()
		assert(artTextures:Label(RIME) == "Rime", "the label the list carries")
		assert(artTextures:Label(123) == "#123", "an id from nowhere still says which one")
		assert(artTextures:Label([[Interface/AddOns/Pack/my-art.tga]]) == "My Art",
			"a hand-typed path is named after its file")
		assert(artTextures:Label("") == "", "nothing chosen names nothing")
	end)

	fw.it("narrows to every word of a search, in any order", function()
		local all = #artTextures:GetEntries()
		local narrowed = #artTextures:Filter("maelstrom")

		assert(narrowed > 0 and narrowed < all, "a word narrows the list")
		assert(#artTextures:Filter("weapon maelstrom") > 0, "and the words may come in any order")
		assert(#artTextures:Filter("") == all, "an empty search is the whole list")
		assert(#artTextures:Filter("zzzznothing") == 0, "and a miss is empty")
	end)
end)

fw.describe("ArtTextures - painting", function()
	fw.it("hides a texture with no art chosen", function()
		local texture = NewTexture()

		artTextures:Apply(texture, { Asset = "" })

		assert(not texture.Shown, "an empty path draws nothing")
	end)

	fw.it("applies the tint, blend and greyscale it was given", function()
		local texture = NewTexture()

		artTextures:Apply(texture, {
			Asset = RIME,
			R = 1, G = 0.5, B = 0, A = 0.25,
			Additive = true,
			Desaturate = true,
		})

		assert(texture.Shown, "art chosen means art drawn")
		assert(texture.Texture == RIME, "the chosen file")
		assert(texture.BlendMode == "ADD", "additive, which is what the overlay art expects")
		assert(texture.Desaturated == true, "greyscale")
		Near(texture.Color[4], 0.25, "alpha")
	end)

	fw.it("draws an atlas element as its own corner of the sheet", function()
		-- Set through the sheet and its coordinates rather than SetAtlas, because SetAtlas writes
		-- the same four corners the turn does and the two cannot both have them.
		local texture = NewTexture()

		_G.C_Texture = {
			GetAtlasInfo = function(name)
				if name ~= "test-atlas" then
					return nil
				end

				return {
					file = 12345,
					leftTexCoord = 0.25, rightTexCoord = 0.75,
					topTexCoord = 0.5, bottomTexCoord = 1.0,
				}
			end,
		}

		artTextures:Apply(texture, { Asset = "test-atlas" })

		assert(texture.Texture == 12345, "the sheet holding it")
		Near(texture.Coords[1], 0.25, "upper left lands on the element's left edge")
		Near(texture.Coords[2], 0.5, "and its top")
		Near(texture.Coords[7], 0.75, "lower right on the right edge")
		Near(texture.Coords[8], 1.0, "and the bottom")

		-- Turned a half circle, the element's opposite corner has to come round to the top left,
		-- and it must stay inside the element rather than wandering into its neighbour.
		artTextures:Apply(texture, { Asset = "test-atlas", Rotation = 180 })

		Near(texture.Coords[1], 0.75, "the turn folds into the element")
		Near(texture.Coords[2], 1.0, "on both axes")

		artTextures:Apply(texture, { Asset = "missing-atlas" })

		assert(not texture.Shown, "a name this build does not have draws nothing")

		_G.C_Texture = nil
	end)

	fw.it("leaves an unturned texture on its own corners", function()
		local coords = artTextures:Coords(0, false)
		local expected = { 0, 0, 0, 1, 1, 0, 1, 1 }

		for index = 1, 8 do
			Near(coords[index], expected[index], "coord " .. index)
		end
	end)

	fw.it("mirrors and turns together, which SetRotation could not", function()
		local mirrored = artTextures:Coords(0, true)

		Near(mirrored[1], 1, "the upper left corner takes the right edge")
		Near(mirrored[5], 0, "and the upper right takes the left")

		-- A quarter turn clockwise draws the texture's LOWER left at the upper left corner, which
		-- is what carries the left edge round to the top.
		local turned = artTextures:Coords(90, false)

		Near(turned[1], 0, "upper left x")
		Near(turned[2], 1, "upper left y")

		-- Mirroring first and turning after: the lower RIGHT lands there instead.
		local both = artTextures:Coords(90, true)

		Near(both[1], 0, "mirroring survives the turn")
		Near(both[2], 0, "and the turn survives the mirror")
		Near(both[3], 1, "the lower left corner moved with it")
	end)

	fw.it("turns a half circle onto the opposite corners", function()
		local coords = artTextures:Coords(180, false)

		Near(coords[1], 1, "upper left takes the lower right")
		Near(coords[2], 1, "on both axes")
	end)

	fw.it("comes back where it started after a full turn", function()
		local coords = artTextures:Coords(360, false)
		local expected = { 0, 0, 0, 1, 1, 0, 1, 1 }

		for index = 1, 8 do
			Near(coords[index], expected[index], "coord " .. index)
		end
	end)
end)
