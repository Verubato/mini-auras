-- The CC and Pet CC options pages. Both share the same three-way Icon colours dropdown, which
-- replaces the on/off dispel checkbox they used to carry, and the CC colour swatch that only
-- means anything in Custom mode.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---Whether a frame hangs off the page. Every module page carries controls under shared labels, so
---the lookup below has to be scoped or it finds one belonging to another page.
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

---Every dropdown on a page whose caption reads a given label.
---@param page table
---@param labelText string
---@return table[]
local function DropdownsFor(page, labelText)
	local found = {}

	for _, frame in ipairs(WowMock.Frames) do
		local label = frame.Label

		if label and label.GetText and label:GetText() == labelText and Inside(frame, page) then
			found[#found + 1] = frame
		end
	end

	return found
end

---Whether a checkbox with the given caption still hangs off the page. A checkbox's caption lives
---on its own Text field, not the Label a dropdown carries, so proving the old one is gone needs
---its own lookup.
---@param page table
---@param labelText string
---@return boolean
local function HasCheckbox(page, labelText)
	for _, frame in ipairs(WowMock.Frames) do
		local text = frame.Text

		if text and text.GetText and text:GetText() == labelText and Inside(frame, page) then
			return true
		end
	end

	return false
end

---The colour swatch sharing a control's own parent, which is how the CC pages keep the dropdown
---and the swatch it governs paired without a shared label to key off.
---@param page table
---@param sibling table
---@param labelText string
---@return table?
local function SwatchBeside(page, sibling, labelText)
	for _, frame in ipairs(WowMock.Frames) do
		local label = frame.Label

		if label and label.GetText and label:GetText() == labelText and Inside(frame, page)
			and frame:GetParent() == sibling:GetParent()
		then
			return frame
		end
	end

	return nil
end

---Reads a dropdown's current value through its own menu, the way the built-in ItemsIn helpers on
---other panel tests do, rather than reaching into the closure that built it.
---@param dropdown table
---@return string?
local function CurrentValue(dropdown)
	local current
	local description = {}

	function description.CreateRadio(_, _, isSelected, _, value)
		if isSelected(value) then
			current = value
		end

		return description
	end

	function description.SetGridMode() end
	function description.SetScrollMode() end

	dropdown.__menuGenerator(dropdown, description)

	return current
end

---Picks a dropdown's row for the given value and runs its click handler.
---@param dropdown table
---@param value string
local function SelectValue(dropdown, value)
	local description = {}

	function description.CreateRadio(_, _, _, onClick, itemValue)
		if itemValue == value then
			onClick()
		end

		return description
	end

	function description.SetGridMode() end
	function description.SetScrollMode() end

	dropdown.__menuGenerator(dropdown, description)
end

---Asserts the swatch beside a colour dropdown is shown only in Custom mode.
---@param page table
---@param dropdown table
---@param swatchLabel string
local function AssertSwatchTracksMode(page, dropdown, swatchLabel)
	local swatch = SwatchBeside(page, dropdown, swatchLabel)

	fw.not_nil(swatch, "the colour dropdown has a swatch beside it")

	SelectValue(dropdown, "DISPEL")
	assert(not swatch:IsShown(), "the palette is doing the colouring, so the swatch has nothing to say")

	SelectValue(dropdown, "NONE")
	assert(not swatch:IsShown(), "no colour at all leaves the swatch just as idle")

	SelectValue(dropdown, "CUSTOM")
	assert(swatch:IsShown(), "only Custom mode reads the swatch")
end

fw.describe("Config - the CC page's icon colours dropdown", function()
	fw.it("swaps in for the old dispel checkbox and drives the swatch on both tabs", function()
		local addon = Load()
		local db = addon.Framework:GetSavedVars()

		-- Distinct starting modes, so the two tabs' otherwise identical dropdowns can be told apart
		-- by which one currently reads which value.
		db.Modules.CrowdControl.Default.Icons.ColorMode = "CUSTOM"
		db.Modules.CrowdControl.Raid.Icons.ColorMode = "DISPEL"

		addon.Config:EnsureWindow()

		local page = addon.Config.TabController:GetContent("CC")
		fw.not_nil(page, "the CC tab exists")

		assert(not HasCheckbox(page, addon.L["Dispel colours"]),
			"the old checkbox must not still be on the page")

		local dropdowns = DropdownsFor(page, addon.L["Icon colours"])
		fw.eq(#dropdowns, 2, "both the World/Arena/Dungeons and Raids/Battlegrounds tabs offer it")

		local defaultDropdown, raidDropdown
		for _, dropdown in ipairs(dropdowns) do
			if CurrentValue(dropdown) == "CUSTOM" then
				defaultDropdown = dropdown
			else
				raidDropdown = dropdown
			end
		end

		fw.not_nil(defaultDropdown, "the seeded Custom mode identifies the default tab's dropdown")
		fw.not_nil(raidDropdown, "leaving the other as the raid tab's")

		AssertSwatchTracksMode(page, defaultDropdown, addon.L["CC"])
		fw.eq(db.Modules.CrowdControl.Default.Icons.ColorMode, "CUSTOM",
			"driving the default tab's dropdown writes the default instance")

		AssertSwatchTracksMode(page, raidDropdown, addon.L["CC"])
		fw.eq(db.Modules.CrowdControl.Raid.Icons.ColorMode, "CUSTOM",
			"and the raid tab's dropdown writes its own instance, not the default one")
	end)
end)

fw.describe("Config - the pet CC page's icon colours dropdown", function()
	fw.it("swaps in for the old dispel checkbox and drives the swatch", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		local page = addon.Config.TabController:GetContent("PetCC")
		fw.not_nil(page, "the pet CC tab exists")

		assert(not HasCheckbox(page, addon.L["Dispel colours"]),
			"the old checkbox must not still be on the page")

		local dropdowns = DropdownsFor(page, addon.L["Icon colours"])
		fw.eq(#dropdowns, 1, "the page has a single instance, so a single dropdown")

		AssertSwatchTracksMode(page, dropdowns[1], addon.L["CC"])
	end)
end)
