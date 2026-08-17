-- The glow catalog. Both icon backends read it, so a malformed entry breaks glows everywhere at
-- once: a missing asset file draws nothing, and flipbook geometry that does not match the sheet
-- plays a crop of it. Neither shows up as an error, hence the checks here.

local fw = require("Framework")

local ADDON_NAME = "MiniAuras"

local addon = { Core = {} }
assert(loadfile("src/Core/Display/Media/GlowStyles.lua"))(ADDON_NAME, addon)
local glowStyles = addon.Core.GlowStyles

---A glow frame as ApplySpec sees it: it only ever touches these three children.
local function StubGlowFrame()
	local calls = {}
	local frame = { Geometry = {}, Calls = calls }

	frame.Texture = {
		SetAtlas = function(_, atlas) frame.Atlas = atlas end,
		SetTexture = function(_, path) frame.TexturePath = path end,
		SetBlendMode = function(_, mode) frame.BlendMode = mode end,
		SetDesaturated = function(_, on) frame.Desaturated = on end,
		SetTexCoord = function() calls[#calls + 1] = "SetTexCoord" end,
	}
	frame.Anim = {
		Stop = function() calls[#calls + 1] = "Stop" end,
	}
	frame.FlipAnim = {
		SetFlipBookRows = function(_, value) frame.Geometry.Rows = value end,
		SetFlipBookColumns = function(_, value) frame.Geometry.Columns = value end,
		SetFlipBookFrames = function(_, value) frame.Geometry.Frames = value end,
		SetDuration = function(_, value) frame.Geometry.Duration = value end,
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

	fw.it("gives every animated style a full sheet geometry", function()
		for name, spec in pairs(glowStyles.Specs) do
			if spec.Animated then
				assert(spec.Rows and spec.Columns and spec.Frames and spec.Duration,
					name .. " is animated with an incomplete geometry")
				assert(spec.Frames <= spec.Rows * spec.Columns,
					name .. " claims more frames than its sheet holds")
				assert(spec.Duration > 0, name .. " has no loop length")
			end
		end
	end)

	fw.it("has a default that is one of its own styles", function()
		assert(glowStyles.Specs[glowStyles.DefaultName], "the default names a style that is missing")
	end)

	fw.it("pushes an animated style's own geometry onto the flipbook", function()
		local frame = StubGlowFrame()
		local spec = glowStyles.Specs["Twins Mirror"]

		glowStyles:ApplySpec(frame, spec)

		assert(frame.Calls[1] == "Stop", "the running animation is stopped before re-skinning")
		assert(frame.TexturePath == spec.Texture, "the sheet is applied")
		assert(frame.Geometry.Rows == spec.Rows and frame.Geometry.Columns == spec.Columns,
			"the sheet's own rows and columns are used")
		assert(frame.Geometry.Frames == spec.Frames and frame.Geometry.Duration == spec.Duration,
			"so are its frame count and loop length")
	end)

	fw.it("resets the coords for a static style rather than writing geometry", function()
		local frame = StubGlowFrame()

		glowStyles:ApplySpec(frame, glowStyles.Specs["Static Pixel Border"])

		assert(frame.Atlas, "the atlas is applied")
		assert(frame.Calls[2] == "SetTexCoord", "the last animated frame's crop is cleared")
		assert(next(frame.Geometry) == nil, "a static style leaves the flipbook alone")
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
