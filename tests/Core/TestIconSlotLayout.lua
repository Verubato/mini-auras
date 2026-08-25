-- The wrapping grid layout on IconSlotContainer. Every line has to start on the edge the
-- container is anchored by, or a part-full line floats away from the live row it stands in for.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local iconSlotContainer = env.addon.Core.IconSlotContainer

local ICON = 134400
local SIZE = 10
local SPACING = 2

---A grow-up grid holding `count` icons, wrapped at `columns` per line.
---@param count number
---@param columns number
---@param invertLayout boolean
---@return IconSlotContainer
local function NewGrid(count, columns, invertLayout)
	local container = iconSlotContainer:New(_G.UIParent, count, SIZE, SPACING, "LayoutTest")

	container:SetGrowUp(true)
	container:SetColumns(columns, invertLayout)

	for slot = 1, count do
		container:SetSlot(slot, { Texture = ICON })
	end

	return container
end

---Where each of a container's icons was placed across the row, in slot order.
---@param container IconSlotContainer
---@return number[]
local function OffsetsIn(container)
	local offsets = {}

	for index = 1, container.Count do
		local _, _, _, x = container.Slots[index].Frame:GetPoint(1)
		offsets[index] = x
	end

	return offsets
end

fw.describe("IconSlotContainer - the wrapping grid", function()
	fw.it("starts a wrapped line where the line above it started", function()
		local offsets = OffsetsIn(NewGrid(5, 3, false))

		assert(offsets[2] - offsets[1] == SIZE + SPACING,
			"the line runs rightwards from slot 1, got " .. (offsets[2] - offsets[1]))
		assert(offsets[4] == offsets[1],
			"the part-full line starts under the full one, got " .. offsets[4] .. " against " .. offsets[1])
		assert(offsets[5] == offsets[2], "and carries on from there, got " .. offsets[5])
	end)

	fw.it("hangs a wrapped line off the right edge when the row fills leftwards", function()
		local offsets = OffsetsIn(NewGrid(5, 3, true))

		assert(offsets[2] - offsets[1] == -(SIZE + SPACING),
			"slot 1 is the rightmost icon, got " .. (offsets[2] - offsets[1]))
		assert(offsets[4] == offsets[1],
			"the part-full line starts under the full one, got " .. offsets[4] .. " against " .. offsets[1])
		assert(offsets[5] == offsets[2], "and carries on from there, got " .. offsets[5])
	end)

	-- The layout skips its work whenever nothing it was last built from moved, so a fill direction
	-- left out of that reckoning would change the setting and not the screen.
	fw.it("redraws for a change of fill direction alone", function()
		local container = NewGrid(5, 3, false)
		local before = OffsetsIn(container)

		container:SetColumns(3, true)

		local after = OffsetsIn(container)

		assert(after[1] == -before[1], "flipping the fill mirrors the line, got " .. after[1])
		assert(after[4] == after[1], "and the wrapped line follows it, got " .. after[4])
	end)
end)
