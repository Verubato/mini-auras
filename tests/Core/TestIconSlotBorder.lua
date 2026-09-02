-- The dispel ring on IconSlotContainer. The other backend, AuraContainerDisplay, is covered by
-- the Alerts suites, which find a live button's border by the same asset.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local iconSlotContainer = env.addon.Core.IconSlotContainer
local borderTextures = env.addon.Core.BorderTextures

local ICON = 134400

---@param noBorder boolean?
---@param slotOptions table? Extra SetSlot fields, layered over the bare texture
local function NewSlot(noBorder, slotOptions)
	local container = iconSlotContainer:New(_G.UIParent, 1, 30, 2, "BorderTest", noBorder)
	local options = { Texture = ICON }

	if slotOptions then
		for key, value in pairs(slotOptions) do
			options[key] = value
		end
	end

	container:SetSlot(1, options)

	return container.Slots[1].Container
end

fw.describe("IconSlotContainer - the dispel border", function()
	fw.it("rings a built slot with the shared art", function()
		local border = assert(NewSlot().Border, "the slot was built without one")

		local asset = assert(border._lastArgs.SetTexture, "the ring was left without art")
		assert(asset[1] == borderTextures:GetDispelAsset(), "the ring is not the shared art")
	end)

	fw.it("leaves a borderless container without one", function()
		assert(NewSlot(true).Border == nil, "a borderless slot drew one anyway")
	end)

	fw.it("keeps square corners when Border is asked for but nothing colours it", function()
		local layer = NewSlot(nil, { Border = true })
		assert(layer.CornersRounded == false, "a border nobody can see should not round the icon")
	end)

	fw.it("rounds the corners once a colour draws a ring, Border unasked and glow off", function()
		local layer = NewSlot(nil, { Color = { r = 1, g = 1, b = 1, a = 1 } })
		assert(layer.CornersRounded == true, "a drawn border should round the icon even without Border")
	end)
end)
