-- The wrapping grid layout on IconSlotContainer. Every line has to start on the edge the
-- container is anchored by, or a part-full line floats away from the live row it stands in for.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local iconSlotContainer = env.addon.Core.IconSlotContainer

local ICON = 134400
local SIZE = 10
local SPACING = 2
local LEAD_SCALE = 1.25
local LEAD_SIZE = SIZE * LEAD_SCALE

---A grow-up grid holding `count` icons, wrapped at `columns` per line.
---@param count number
---@param columns number
---@param invertLayout boolean
---@param leadScale number? What the first icon is drawn at, as a share of the rest.
---@return IconSlotContainer
local function NewGrid(count, columns, invertLayout, leadScale)
	local container = iconSlotContainer:New(_G.UIParent, count, SIZE, SPACING, "LayoutTest")

	container:SetGrowUp(true)
	container:SetColumns(columns, invertLayout)
	container:SetLeadScale(leadScale)

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

---The edge each of a container's icons starts at, which is where a larger icon has to line up
---with the ones below it rather than at its centre.
---@param container IconSlotContainer
---@return number[]
local function EdgesIn(container)
	local edges = {}

	for index = 1, container.Count do
		local frame = container.Slots[index].Frame
		local _, _, _, x = frame:GetPoint(1)
		edges[index] = x - frame:GetWidth() / 2
	end

	return edges
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

	fw.it("draws the icon leading the row larger and moves the rest of the line along", function()
		local container = NewGrid(5, 3, false, LEAD_SCALE)
		local offsets = OffsetsIn(container)

		assert(container.Slots[1].Frame:GetWidth() == LEAD_SIZE,
			"the lead icon takes the scale, got " .. container.Slots[1].Frame:GetWidth())
		assert(container.Slots[2].Frame:GetWidth() == SIZE,
			"the one after it keeps the row's own size, got " .. container.Slots[2].Frame:GetWidth())
		assert(offsets[2] - offsets[1] == LEAD_SIZE / 2 + SPACING + SIZE / 2,
			"and starts clear of the larger icon, got " .. (offsets[2] - offsets[1]))
	end)

	fw.it("keeps a line wrapped under a larger lead icon on the same edge", function()
		local edges = EdgesIn(NewGrid(5, 3, false, LEAD_SCALE))

		assert(edges[4] == edges[1],
			"the wrapped line starts under the lead icon, got " .. edges[4] .. " against " .. edges[1])
		assert(edges[5] == edges[4] + SIZE + SPACING, "and carries on from there, got " .. edges[5])
	end)

	-- A lead scale left out of what the layout is built from would resize the setting and not the
	-- screen, the same trap the fill direction has.
	fw.it("redraws for a change of lead scale alone", function()
		local container = NewGrid(5, 3, false)
		local before = OffsetsIn(container)

		container:SetLeadScale(LEAD_SCALE)

		local after = OffsetsIn(container)

		assert(container.Slots[1].Frame:GetWidth() == LEAD_SIZE,
			"the lead icon grew, got " .. container.Slots[1].Frame:GetWidth())
		assert(after[2] ~= before[2], "and the row moved along with it, got " .. after[2])
	end)

	-- A horizontal row draws every icon at the container's own size, so a slot that remembers
	-- being the larger one would come back from the trip still drawn small.
	fw.it("draws the lead icon larger again after a turn through a horizontal row", function()
		local container = NewGrid(5, 3, false, LEAD_SCALE)

		container:SetGrowUp(false)
		container:SetGrowUp(true)

		assert(container.Slots[1].Frame:GetWidth() == LEAD_SIZE,
			"the lead icon is back at its own size, got " .. container.Slots[1].Frame:GetWidth())
	end)

	-- The countdown text is sized from whatever the layer was told the icon is. The mock reads
	-- every applied font back at one size, so what it was told is as close as a test can get.
	fw.it("tells the lead icon's layer the size it is drawn at, not the row's", function()
		local container = NewGrid(3, 3, false, LEAD_SCALE)
		local lead = container.Slots[1].Container
		local plain = container.Slots[2].Container

		assert(lead.Cooldown.DesiredIconSize == LEAD_SIZE,
			"the countdown on it is sized off the larger icon, got "
			.. tostring(lead.Cooldown.DesiredIconSize))
		assert(lead.Frame.DesiredSize == LEAD_SIZE,
			"and so is the layer under it, got " .. tostring(lead.Frame.DesiredSize))
		assert(plain.Cooldown.DesiredIconSize == SIZE,
			"while the rest of the row keeps the row's own size, got "
			.. tostring(plain.Cooldown.DesiredIconSize))
	end)

	fw.it("refuses a lead scale that would draw the head of the row smaller", function()
		local container = NewGrid(5, 3, false)
		local before = OffsetsIn(container)

		container:SetLeadScale(0.8)

		assert(container.Slots[1].Frame:GetWidth() == SIZE,
			"a scale under 1 leaves the icon alone, got " .. container.Slots[1].Frame:GetWidth())
		assert(OffsetsIn(container)[1] == before[1],
			"and the row where it was, got " .. OffsetsIn(container)[1])
	end)
end)
