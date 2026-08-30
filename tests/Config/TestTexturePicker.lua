-- The texture picker popup, over the swatch grid it draws.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

-- Mirrors SELECTION_BORDER_PADDING in src/Config/Panels/TexturePicker.lua.
local SELECTION_BORDER_PADDING = 2

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---The grid button drawing the given asset, found by walking the mock's frame registry: the
---picker keeps its buttons to itself and there is no other way in.
---@param asset string|number
---@return table?
local function ButtonFor(asset)
	for _, frame in ipairs(WowMock.Frames) do
		if frame.Value == asset and frame.Selected then
			return frame
		end
	end

	return nil
end

---The glow this replaced came from the art blending onto a fill underneath it, so every edge
---has to hang off the swatch rather than reach back over it.
---@param edge table
local function AssertEdgeSitsOutside(edge)
	for i = 1, edge:GetNumPoints() do
		local point, _, _, x, y = edge:GetPoint(i)
		local outwardX = point:find("LEFT") and -SELECTION_BORDER_PADDING or SELECTION_BORDER_PADDING
		local outwardY = point:find("TOP") and SELECTION_BORDER_PADDING or -SELECTION_BORDER_PADDING

		fw.eq(x, outwardX, point .. " is held clear of the swatch horizontally")
		fw.eq(y, outwardY, point .. " is held clear of the swatch vertically")
	end
end

fw.describe("Texture picker - the selected swatch", function()
	fw.it("outlines the swatch in a border rather than covering its art", function()
		local addon = Load()
		local matches = addon.Core.ArtTextures:Filter("")

		fw.truthy(#matches >= 2, "the catalog has at least two textures to compare")

		local selectedAsset = matches[1].Asset
		local otherAsset = matches[2].Asset

		addon.Config.TexturePicker:Open(selectedAsset, function() end)

		local selectedButton = ButtonFor(selectedAsset)
		local otherButton = ButtonFor(otherAsset)

		fw.not_nil(selectedButton, "the chosen texture has a grid button")
		fw.not_nil(otherButton, "a second texture has a grid button")

		local border = selectedButton.Selected

		fw.eq(type(border), "table", "the selection state is not a single overlay texture")
		fw.eq(type(border.Edges), "table", "the border is made of edge textures")
		fw.eq(#border.Edges, 4, "one edge per side")

		for _, edge in ipairs(border.Edges) do
			fw.eq(edge:IsShown(), true, "the selected swatch's border edges are shown")

			local color = edge.__color

			fw.not_nil(color, "the edge is a plain colour texture")
			fw.eq(color[1], 1, "the border is the addon's selection yellow")
			fw.eq(color[2], 0.82, "the border is the addon's selection yellow")
			fw.eq(color[3], 0, "the border is the addon's selection yellow")
			fw.eq(color[4], 1, "the border is opaque, not a translucent glow")

			local width, height = edge:GetWidth(), edge:GetHeight()
			fw.truthy(width <= 4 or height <= 4, "the edge is a thin stroke, not a full overlay")

			AssertEdgeSitsOutside(edge)
		end

		fw.not_nil(otherButton.Selected.SetShown, "the other swatch has the same border")

		for _, edge in ipairs(otherButton.Selected.Edges) do
			fw.eq(edge:IsShown(), false, "an unselected swatch's border stays hidden")
		end
	end)
end)
