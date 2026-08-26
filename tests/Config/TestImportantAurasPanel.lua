-- The important auras options page. Its spells tab is a whitelist with a picker on top, and what
-- the picker writes depends on whether the shipped data already knows the spell.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

-- Past anything the shipped index carries, so the picker can only take it as typed.
local UNKNOWN_SPELL = 9999999

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---One curated spell the page ships tracked, picked by id so this survives a regeneration of the
---generated data.
---@param addon table
---@return number
local function CuratedId(addon)
	local categoryIds = addon.Core.AuraCategoryIds
	local lowest

	for spellId in pairs(categoryIds.Important) do
		if not categoryIds.DefaultOff[spellId] and (not lowest or spellId < lowest) then
			lowest = spellId
		end
	end

	return assert(lowest, "the curated list has no default-tracked spell")
end

---@param frame table
---@param page table
---@return boolean
local function Inside(frame, page)
	local parent = frame.GetParent and frame:GetParent()

	while parent do
		if parent == page then
			return true
		end

		parent = parent.GetParent and parent:GetParent()
	end

	return false
end

---The picker's edit box on the spells tab, which is the only box on the page that hands a spell
---to a callback.
---@param addon table
---@return table?
local function Picker(addon)
	local page = addon.Config.TabController:GetContent("ImportantAuras")

	fw.not_nil(page, "the important auras tab exists")

	for _, frame in ipairs(WowMock.Frames) do
		if frame.OnAccept and frame:GetScript("OnArrowPressed") and Inside(frame, page) then
			return frame
		end
	end

	return nil
end

---@param box table
---@param query string
local function Type(box, query)
	box:SetText(query)
	box:GetScript("OnTextChanged")(box, true)
end

fw.describe("Important Auras page - the spell picker", function()
	fw.it("puts a spell the shipped data has never seen in the custom list", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		local box = Picker(addon)

		fw.not_nil(box, "the spells tab offers the picker")

		Type(box, tostring(UNKNOWN_SPELL))
		box:GetScript("OnEnterPressed")(box)

		local overrides = addon.Framework:GetSavedVars().Modules.ImportantAuras.Spells

		fw.eq(overrides.Custom[UNKNOWN_SPELL], true, "it was added as the player's own")
	end)

	fw.it("switches a curated spell back on rather than adding it again", function()
		local addon = Load()
		local overrides = addon.Framework:GetSavedVars().Modules.ImportantAuras.Spells
		local curated = CuratedId(addon)

		overrides.Disabled[curated] = true

		addon.Config:EnsureWindow()

		local box = Picker(addon)

		Type(box, tostring(curated))
		box:GetScript("OnEnterPressed")(box)

		fw.eq(overrides.Disabled[curated], nil, "the switch that had it off is cleared")
		fw.eq(overrides.Custom[curated], nil, "and it stays in the section that owns it")
	end)
end)
