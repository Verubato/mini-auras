-- The dispel ring on IconSlotContainer. The other backend, AuraContainerDisplay, is covered by
-- the Alerts suites, which find a live button's border by the same asset.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local iconSlotContainer = env.addon.Core.IconSlotContainer
local borderTextures = env.addon.Core.BorderTextures

local ICON = 134400

---@param noBorder boolean?
local function NewSlot(noBorder)
	local container = iconSlotContainer:New(_G.UIParent, 1, 30, 2, "BorderTest", noBorder)
	container:SetSlot(1, { Texture = ICON })

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
end)
