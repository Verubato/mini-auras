-- The glow catalog. Both icon backends read it, so a malformed entry breaks glows everywhere at
-- once, and a missing asset file draws nothing without showing up as an error. Hence the checks
-- here.

local fw = require("Framework")

local ADDON_NAME = "MiniAuras"

local addon = { Core = {} }
assert(loadfile("src/Core/Display/Media/GlowStyles.lua"))(ADDON_NAME, addon)
local glowStyles = addon.Core.GlowStyles

---A glow frame as ApplySpec sees it: it only ever touches the texture.
local function StubGlowFrame()
	local frame = {}

	frame.Texture = {
		SetAtlas = function(_, atlas) frame.Atlas = atlas end,
		SetTexture = function(_, path) frame.TexturePath = path end,
		SetBlendMode = function(_, mode) frame.BlendMode = mode end,
		SetDesaturated = function(_, on) frame.Desaturated = on end,
	}

	return frame
end

---A frame as SetIconCorners sees it, plus the icon it cuts the corners off.
local function MaskingFrame()
	local frame = {}

	frame.CreateMaskTexture = function()
		frame.Mask = {
			SetTexture = function(_, path) frame.MaskTexture = path end,
			SetAllPoints = function() end,
		}

		return frame.Mask
	end

	frame.CreateTexture = function()
		return {
			AddMaskTexture = function() end,
			RemoveMaskTexture = function() end,
		}
	end

	return frame
end

---The file a shipped texture path names, under src. Everything after the addon folder is kept, so
---a style pointing into a subfolder is checked where it actually lives.
---@param texture string
---@return string?
local function SourcePath(texture)
	local within = texture:match("\\AddOns\\[^\\]+\\(.+)$")

	return within and ("src/" .. within:gsub("\\", "/"))
end

local function ReadPanel()
	local handle = assert(io.open("src/Config/Panels/Miscellaneous.lua", "r"))
	local source = handle:read("*a")
	handle:close()

	return source
end

fw.describe("GlowStyles", function()
	fw.it("gives every style exactly one asset and a padding share", function()
		for name, spec in pairs(glowStyles.Specs) do
			local hasBoth = spec.Texture and spec.Atlas
			assert(spec.Texture or spec.Atlas, name .. " has no asset")
			assert(not hasBoth, name .. " has both a texture and an atlas")
			assert(type(spec.PaddingFactor) == "number", name .. " has no padding factor")
			assert(spec.BlendMode, name .. " has no blend mode")
		end
	end)

	fw.it("ships the corner mask it cuts icons with", function()
		-- The mask is a file like the glow art, and it has moved between folders, so it is worth
		-- the same check: nothing else would notice the path going stale.
		local frame = MaskingFrame()

		glowStyles:SetIconCorners(frame, frame:CreateTexture(), nil, nil, true)

		local path = SourcePath(frame.MaskTexture)
		assert(path, "the mask has an unreadable texture path")

		local handle = io.open(path, "rb")
		assert(handle, "the mask points at a missing file: " .. path)
		handle:close()
	end)

	fw.it("ships the texture file behind every style that names one", function()
		for name, spec in pairs(glowStyles.Specs) do
			if spec.Texture then
				local path = SourcePath(spec.Texture)
				assert(path, name .. " has an unreadable texture path")
				local handle = io.open(path, "rb")
				assert(handle, name .. " points at a missing file: " .. path)
				handle:close()
			end
		end
	end)

	fw.it("holds no animated style at all", function()
		-- The flipbook styles are gone for their idle CPU cost. A REPEAT animation is evaluated
		-- every frame even on a hidden button, and Blizzard leaves no way to gate one per icon.
		-- Anything reintroducing that field brings the cost straight back.
		for name, spec in pairs(glowStyles.Specs) do
			assert(spec.Animated == nil, name .. " is animated; the catalog is static only")
		end
	end)

	fw.it("has a default that is one of its own styles", function()
		assert(glowStyles.Specs[glowStyles.DefaultName], "the default names a style that is missing")
	end)

	fw.it("applies a file-backed style through SetTexture", function()
		local frame = StubGlowFrame()
		local spec = glowStyles.Specs["Slot Glow"]

		glowStyles:ApplySpec(frame, spec)

		assert(frame.TexturePath == spec.Texture, "the asset is applied")
		assert(frame.BlendMode == spec.BlendMode, "so is the blend mode")
		assert(frame.PaddingFactor == spec.PaddingFactor, "the padding share is read back off the frame")
	end)

	fw.it("applies an atlas-backed style through SetAtlas", function()
		local frame = StubGlowFrame()

		glowStyles:ApplySpec(frame, glowStyles.Specs["Static Pixel Border"])

		assert(frame.Atlas, "the atlas is applied")
		assert(frame.TexturePath == nil, "and no file path with it")
	end)

	fw.it("offers every style on the aura-container dropdown", function()
		-- The catalog holds exactly the styles the 12.1 path can draw, so anything added to it and
		-- left out of the panel is a style nobody can pick.
		local source = ReadPanel()

		for name in pairs(glowStyles.Specs) do
			assert(source:find('"' .. name .. '"', 1, true), name .. " is not offered in the config panel")
		end
	end)
end)
