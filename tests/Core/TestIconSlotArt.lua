-- An atlas laid over an icon's own texture.

local fw = require("Framework")
local wow = require("WowApi")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local iconSlotContainer = env.addon.Core.IconSlotContainer

local ICON = 134400

local function NewSlotContainer()
	return iconSlotContainer:New(_G.UIParent, 3, 30, 2, "ArtTest")
end

---@param options table
---@return table container
---@return table layer the icon layer the slot draws through
local function SlotWith(options)
	local container = NewSlotContainer()
	container:SetSlot(1, options)

	return container, container.Slots[1].Container
end

fw.describe("IconSlotContainer - an atlas over the icon", function()
	fw.it("draws the atlas on its own texture, above the icon it keeps", function()
		local _, layer = SlotWith({ Texture = ICON, Atlas = "classicon-mage" })

		local atlasIcon = assert(layer.AtlasIcon, "the slot built its atlas texture")

		fw.eq(atlasIcon._lastArgs.SetAtlas[1], "classicon-mage", "the atlas name reached the setter")
		assert(atlasIcon:IsShown(), "and it is up")
		fw.eq(layer.Icon._lastArgs.SetTexture[1], ICON, "the icon stays, so a bad name leaves art")
	end)

	fw.it("fills the button, not whatever a skin sized the icon to", function()
		local _, layer = SlotWith({ Texture = ICON, Atlas = "classicon-mage" })

		local anchor = assert(layer.AtlasIcon._lastArgs.SetAllPoints, "the crest is pinned")

		assert(anchor[1] == layer.Frame, "a crest grown with the icon overhangs the border")
	end)

	fw.it("stays below the layer a Masque skin draws its border in", function()
		local _, layer = SlotWith({ Texture = ICON, Atlas = "classicon-mage" })

		fw.eq(layer.AtlasIcon._layer, "BACKGROUND", "a crest in ARTWORK covers the skin's border")
		assert(layer.AtlasIcon._subLevel > layer.Icon._subLevel, "the crest still covers the icon")
	end)

	fw.it("rounds the crest with the icon once a ring is drawn", function()
		local _, layer = SlotWith({
			Texture = ICON,
			Atlas = "classicon-mage",
			Color = { r = 1, g = 1, b = 1, a = 1 },
		})

		assert(layer.CornersRounded == true, "the ring rounds the icon")

		local masked = layer.AtlasIcon._lastArgs.AddMaskTexture
		assert(masked and masked[1] == layer.CornerMask,
			"a square crest overhangs the ring's rounded corners")
	end)

	fw.it("takes the rounding back off the crest once the ring goes", function()
		local container, layer = SlotWith({
			Texture = ICON,
			Atlas = "classicon-mage",
			Color = { r = 1, g = 1, b = 1, a = 1 },
		})

		local rounded = layer.CornerMask

		container:SetSlot(1, { Texture = ICON, Atlas = "classicon-mage" })

		assert(layer.CornersRounded == false, "nothing rounds the icon now")
		fw.eq(layer.AtlasIcon._lastArgs.RemoveMaskTexture[1], rounded,
			"a mask left on outlives the ring that put it there")
	end)

	fw.it("wears the mask a skin shaped the icon with", function()
		local options = { Texture = ICON, Atlas = "classicon-mage" }
		local container, layer = SlotWith(options)
		local skinMask = {}

		-- Masque hangs its mask on the icon region and hands back no way to ask for it.
		layer.Icon._MSQ_ButtonMask = skinMask
		container:SetSlot(1, options)

		local masked = layer.AtlasIcon._lastArgs.AddMaskTexture
		assert(masked and masked[1] == skinMask, "the crest spills past a skin's rounded edge")
	end)

	fw.it("puts the crest away when the name turns out to be no atlas", function()
		local options = { Texture = ICON, Atlas = "classicon-mage" }
		local container, layer = SlotWith(options)

		layer.AtlasIcon.SetAtlas = function()
			error("no such atlas")
		end

		container:SetSlot(1, options)

		assert(not layer.AtlasIcon:IsShown(), "an empty crest was left over the icon")
	end)

	fw.it("hands over an atlas name it may not read", function()
		local atlas = wow.markSecret({})

		local _, layer = SlotWith({ Texture = ICON, Atlas = atlas })

		fw.eq(layer.AtlasIcon._lastArgs.SetAtlas[1], atlas, "the secret name reached the setter")
	end)

	fw.it("puts the atlas away with the slot", function()
		local container, layer = SlotWith({ Texture = ICON, Atlas = "classicon-mage" })

		container:SetSlotUnused(1)

		assert(not layer.AtlasIcon:IsShown(), "nothing of it left over the next icon")
	end)
end)
