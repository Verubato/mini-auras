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
end)
