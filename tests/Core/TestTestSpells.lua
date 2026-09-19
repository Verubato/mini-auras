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

-- Loads the file fresh into a private table, since the shared env's copy already picked its set
-- when moduleEnv.build() first loaded it.
local function LoadWith(doesSpellExist)
	local target = { Core = {}, Utils = { WoWEx = env.addon.Utils.WoWEx } }
	_G.C_Spell.DoesSpellExist = doesSpellExist
	local ok, err = pcall(assert(loadfile("src/Core/TestMode/TestSpells.lua")), "MiniAuras", target)
	_G.C_Spell.DoesSpellExist = nil
	assert(ok, err)
	return target.Core.TestSpells
end

-- KickSpecIds holds spec ids rather than spell ids, so the below-30000 walk leaves it out.
local ID_FIELDS = { "CrowdControl", "Defensive", "Important", "Nameplates", "FrameAuras", "Alerts" }

---Collects every spell id reachable from `value` into `out`: bare ids, SpellId fields, and the
---numeric keys of a DispelColors map.
---@param value any
---@param out number[]
---@param key any The table key `value` was read from, nil at the top.
local function CollectIds(value, out, key)
	if key == "DispelColor" then
		return
	end

	if type(value) == "number" then
		out[#out + 1] = value
		return
	end

	if type(value) ~= "table" then
		return
	end

	if key == "DispelColors" then
		for spellId in pairs(value) do
			out[#out + 1] = spellId
		end
		return
	end

	for childKey, child in pairs(value) do
		CollectIds(child, out, childKey)
	end
end

fw.describe("TestSpells - the set picked for the client", function()
	fw.it("keeps the retail set when the probe exists", function()
		local retail = LoadWith(function() return true end)

		assert(retail.CrowdControl[3].SpellId == 254412, "retail CC still ends on Hex")
		assert(retail.Defensive[1].SpellId == 33206, "retail defensive still leads on Pain Suppression")
	end)

	fw.it("swaps to ids the older client has when the probe is missing", function()
		local classic = LoadWith(function(id) return id < 30000 end)
		local ids = {}

		for _, field in ipairs(ID_FIELDS) do
			CollectIds(classic[field], ids, field)
		end

		assert(#ids > 0, "the walk found ids to check")

		for _, spellId in ipairs(ids) do
			assert(spellId < 30000, "id " .. spellId .. " is not one the older client has")
		end
	end)

	fw.it("gives the older set the same shape", function()
		local retail = LoadWith(function() return true end)
		local classic = LoadWith(function(id) return id < 30000 end)

		local function Keys(t)
			local keys = {}

			for key in pairs(t) do
				keys[#keys + 1] = tostring(key)
			end

			table.sort(keys)

			return table.concat(keys, ",")
		end

		assert(Keys(retail) == Keys(classic), "the same top-level fields")
		assert(Keys(retail.Nameplates) == Keys(classic.Nameplates), "the same Nameplates fields")
		assert(Keys(retail.FrameAuras) == Keys(classic.FrameAuras), "the same FrameAuras fields")
		assert(Keys(retail.Alerts) == Keys(classic.Alerts), "the same Alerts fields")

		for _, entry in ipairs(classic.CrowdControl) do
			assert(entry.DispelColor, "every CC entry carries a dispel colour")
		end

		for _, category in pairs(classic.Alerts) do
			for _, entry in ipairs(category) do
				assert(entry.SpellId and entry.Class, "every alert entry carries a spell and a class")
			end
		end

		for _, spellId in ipairs(classic.FrameAuras.Debuffs) do
			assert(classic.FrameAuras.DispelColors[spellId],
				"debuff " .. spellId .. " has a dispel colour")
		end

		for _, spellId in ipairs(classic.Nameplates.CrowdControl) do
			assert(classic.Nameplates.DispelColors[spellId],
				"nameplate CC " .. spellId .. " has a dispel colour")
		end

		for _, specId in ipairs(classic.KickSpecIds) do
			local specData = env.addon.Core.KickData.SpecData[specId]

			assert(specData and specData.SpellId, "spec " .. specId .. " has a kick spell")
		end
	end)
end)
