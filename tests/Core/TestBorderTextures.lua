-- The dispel ring both icon backends draw. Its art is bundled rather than the client's, so a
-- stale path draws nothing without showing up as an error.

local fw = require("Framework")
local sourcePath = require("SourcePath")

local ADDON_NAME = "MiniAuras"

local addon = { Core = {} }
assert(loadfile("src/Core/Display/Media/BorderTextures.lua"))(ADDON_NAME, addon)
local borderTextures = addon.Core.BorderTextures

---A texture as ApplyDispel sees it: it only ever sets the asset and the cell.
local function StubTexture()
	local texture = {}

	texture.SetTexture = function(_, path) texture.Path = path end
	texture.SetTexCoord = function(_, l, r, t, b) texture.Coords = { l, r, t, b } end

	return texture
end

fw.describe("BorderTextures", function()
	fw.it("draws the ring from our own art rather than the client's", function()
		local texture = StubTexture()

		borderTextures:ApplyDispel(texture)

		-- The Alerts tests find a button's border by GetDispelAsset, so the two have to agree.
		assert(texture.Path == borderTextures:GetDispelAsset(), "the ring came from somewhere else")
		assert(texture.Path:match("\\AddOns\\" .. ADDON_NAME .. "\\"), "the ring is not our asset")
	end)

	fw.it("ships the file the ring is drawn from", function()
		local path = sourcePath(borderTextures:GetDispelAsset())
		assert(path, "the ring has an unreadable texture path")

		local handle = io.open(path, "rb")
		assert(handle, "the ring points at a missing file: " .. path)
		handle:close()
	end)

	fw.it("crops to the square cell of the atlas", function()
		local texture = StubTexture()

		borderTextures:ApplyDispel(texture)

		local coords = assert(texture.Coords, "the ring was left uncropped")
		-- Uncropped, the round cell beside the square one shows over the icon as well.
		assert(coords[1] == 0.296875, "left edge moved")
		assert(coords[2] == 0.5703125, "right edge moved")
		assert(coords[3] == 0, "top edge moved")
		assert(coords[4] == 0.515625, "bottom edge moved")
	end)
end)

