-- What TestSpells:FillContainer draws when the budget outruns the list. A preview row can lead
-- with a stand-in for a whole category, and coming round again must not draw one of those twice.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local iconSlotContainer = env.addon.Core.IconSlotContainer
local testSpells = env.addon.Core.TestSpells

-- Real ids so the client answers with a texture for each. Which spells they are does not matter
-- here.
local LEAD = 408
local SPELLS = { 34914, 589, 980, 146739 }
local SIZE = 10
local SPACING = 2

---A row of `count` icons filled from a list whose first `leadCount` entries lead it.
---@param previewSpells number[]
---@param leadCount number
---@param count number
---@return IconSlotContainer
local function Fill(previewSpells, leadCount, count)
	local container = iconSlotContainer:New(_G.UIParent, count, SIZE, SPACING, "FillTest")

	testSpells:FillContainer(container, previewSpells, 1, {
		Count = count,
		Repeat = true,
		LeadCount = leadCount,
		-- The only way a slot remembers which spell it was given.
		ShowTooltips = true,
	})

	return container
end

---@param container IconSlotContainer
---@param slotIndex number
---@return number?
local function SpellIn(container, slotIndex)
	return container.Slots[slotIndex] and container.Slots[slotIndex].SpellId
end

---@param container IconSlotContainer
---@param spellId number
---@return number
local function Times(container, spellId)
	local seen = 0

	for slot = 1, container.Count do
		if SpellIn(container, slot) == spellId then
			seen = seen + 1
		end
	end

	return seen
end

fw.describe("TestSpells - a preview row drawn round again", function()
	fw.it("never draws the stand-in leading it a second time", function()
		local list = { LEAD, SPELLS[1], SPELLS[2], SPELLS[3], SPELLS[4] }
		local row = Fill(list, 1, 9)

		assert(Times(row, LEAD) == 1,
			"the stand-in is in the row once, got " .. Times(row, LEAD) .. " of it")
		assert(SpellIn(row, #list + 1) == SPELLS[1],
			"and the row comes round past it, got " .. tostring(SpellIn(row, #list + 1)))
	end)

	fw.it("comes round to the head of a list that nothing leads", function()
		local row = Fill(SPELLS, 0, #SPELLS + 2)

		assert(SpellIn(row, #SPELLS + 1) == SPELLS[1],
			"the plain list starts over from its first spell, got "
			.. tostring(SpellIn(row, #SPELLS + 1)))
		assert(SpellIn(row, #SPELLS + 2) == SPELLS[2], "and carries on from there")
	end)

	fw.it("stops where the list ends when every entry in it leads the row", function()
		local row = Fill({ LEAD }, 1, 9)

		assert(row:GetUsedSlotCount() == 1,
			"the one spell it has is the whole row, got " .. row:GetUsedSlotCount())
	end)
end)
