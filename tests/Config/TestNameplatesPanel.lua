-- The nameplate options page. Its scaling switch is the one control on the page that reaches a
-- second module, so that is what is worth driving here.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---Builds the page the way opening the options does, since nothing exists to drive before that.
---@param addon table
---@return table content
local function ShowPage(addon)
	addon.Config:EnsureWindow()

	local content = addon.Config.TabController:GetContent("Nameplates")

	fw.not_nil(content, "the nameplates tab exists")

	return content
end

---Whether a frame hangs off the page. Every module page carries switches under shared labels, so
---the lookup has to be scoped or it finds one belonging to another page.
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

---@param page table
---@param labelText string
---@return table?
local function SwitchFor(page, labelText)
	for _, frame in ipairs(WowMock.Frames) do
		if frame.__options and frame.__options.LabelText == labelText and Inside(frame, page) then
			return frame
		end
	end

	return nil
end

---Builds the page with the client's stealable filter present or absent, since the controls it
---gates are decided as the page is built.
---@param addon table
---@param present boolean
---@return table page
local function ShowPageWithFilter(addon, present)
	local realEnum = _G.Enum

	-- The mock's Enum invents a member for any name asked of it, so removing one means answering for it.
	_G.Enum = setmetatable({}, {
		__index = function(_, key)
			if key == "CustomAuraButtonDispelTypeStealableFilter" then
				return present and { Stealable = 0, NotStealable = 1 } or nil
			end

			return realEnum[key]
		end,
	})

	local ok, page = pcall(ShowPage, addon)

	_G.Enum = realEnum
	assert(ok, page)

	return page
end

---Every switch on the page carrying a label, in build order.
---@param page table
---@param labelText string
---@return table[]
local function SwitchesFor(page, labelText)
	local found = {}

	for _, frame in ipairs(WowMock.Frames) do
		if frame.__options and frame.__options.LabelText == labelText and Inside(frame, page) then
			found[#found + 1] = frame
		end
	end

	return found
end

---The colour swatches on the page carrying a label.
---@param page table
---@param labelText string
---@return table[]
local function SwatchesFor(page, labelText)
	local found = {}

	for _, frame in ipairs(WowMock.Frames) do
		local label = frame.Label

		if label and label.GetText and label:GetText() == labelText and Inside(frame, page) then
			found[#found + 1] = frame
		end
	end

	return found
end

fw.describe("Config - the nameplates page", function()
	fw.it("refreshes personal auras as well when the scaling switch is flipped", function()
		local addon = Load()
		local page = ShowPage(addon)
		local switch = SwitchFor(page, "Scale with Nameplate")

		fw.not_nil(switch, "the scaling switch is built")

		local applied = {}
		local realApply = addon.Config.Apply

		addon.Config.Apply = function(self, key)
			applied[#applied + 1] = key

			return realApply(self, key)
		end

		switch.__options.SetValue(false)
		addon.Config.Apply = realApply

		local sawNameplates, sawPersonalAuras = false, false

		for _, key in ipairs(applied) do
			sawNameplates = sawNameplates or key == "Nameplates"
			sawPersonalAuras = sawPersonalAuras or key == "PersonalAuras"
		end

		fw.truthy(sawNameplates, "the nameplate module is refreshed")
		-- Its nameplate-anchored copies read this option, and a scoped apply reaches only the
		-- module it names.
		fw.truthy(sawPersonalAuras, "and so is personal auras")
	end)

	fw.it("offers the purgeable-only glow on the enemy bars and nowhere else", function()
		local addon = Load()
		local page = ShowPageWithFilter(addon, true)

		fw.eq(#SwitchesFor(page, "Glow icons"), 4, "every bar has its glow switch")
		fw.eq(#SwitchesFor(page, "Only glow purgeable"), 2, "only the two enemy bars narrow it")
	end)

	fw.it("writes the purgeable-only glow to an enemy bar and applies the module", function()
		local addon = Load()
		local page = ShowPageWithFilter(addon, true)
		local options = addon.Framework:GetSavedVars().Modules.Nameplates
		local switch = SwitchesFor(page, "Only glow purgeable")[1]

		fw.eq(switch.__options.GetValue(), false, "off by default")

		local applied = {}
		local realApply = addon.Config.Apply

		addon.Config.Apply = function(self, key)
			applied[#applied + 1] = key

			return realApply(self, key)
		end

		switch.__options.SetValue(true)
		addon.Config.Apply = realApply

		fw.eq(options.Enemy.Bar1.Icons.GlowPurgeableOnly, true, "the enemy bar the switch sits on carries it")
		fw.eq(applied[#applied], "Nameplates", "the nameplate module is refreshed")
	end)

	fw.it("leaves both controls out on a client without the stealable filter", function()
		local addon = Load()
		local page = ShowPageWithFilter(addon, false)

		fw.eq(#SwitchesFor(page, "Only glow purgeable"), 0, "no switch")
		fw.eq(#SwatchesFor(page, "Purgeable"), 0, "and no swatch")
	end)

	fw.it("writes the purgeable colour the swatch picks", function()
		local addon = Load()
		local page = ShowPageWithFilter(addon, true)
		local options = addon.Framework:GetSavedVars().Modules.Nameplates
		local swatch = SwatchesFor(page, "Purgeable")[1]

		fw.not_nil(swatch, "the swatch is built")

		local setup
		local realPicker = _G.ColorPickerFrame

		_G.ColorPickerFrame = {
			SetupColorPickerAndShow = function(_, info)
				setup = info
			end,
			GetColorRGB = function()
				return 0.1, 0.2, 0.3
			end,
			GetColorAlpha = function()
				return 1
			end,
		}

		swatch:GetScript("OnClick")(swatch)

		fw.eq(setup.r, 0.35, "it opens on the shipped colour")
		setup.swatchFunc()
		_G.ColorPickerFrame = realPicker

		local color = options.PurgeColor

		fw.eq(color.R, 0.1, "red")
		fw.eq(color.G, 0.2, "green")
		fw.eq(color.B, 0.3, "blue")
	end)
end)
