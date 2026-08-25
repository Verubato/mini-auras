-- The frame auras options page. Its switches are declared as a table of labels and keys, so the
-- only thing worth driving is that a switch actually reaches the setting it names.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---Whether a frame hangs off the page. Every module page carries a switch by this name, so the
---lookup below has to be scoped or it finds one of those first.
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

---The switch on the frame auras page carrying a given label. The panel keeps no references to
---them, so it is found the way a player reads it.
---@param addon table
---@param labelText string
---@return table?
local function SwitchFor(addon, labelText)
	local page = addon.Config.TabController:GetContent("FrameAuras")

	fw.not_nil(page, "the frame auras tab exists")

	for _, frame in ipairs(WowMock.Frames) do
		if frame.__options and frame.__options.LabelText == labelText and Inside(frame, page) then
			return frame
		end
	end

	return nil
end

fw.describe("Frame Auras page - the debuff row's switches", function()
	fw.it("offers the dispel colours, and writes them where the row reads them", function()
		local addon = Load()

		-- The window and its pages are built on the first ask, which for a player is opening the
		-- options. Nothing exists to drive before that.
		addon.Config:EnsureWindow()

		local switch = SwitchFor(addon, addon.L["Dispel colours"])

		fw.not_nil(switch, "the debuff row offers the dispel colours")

		local options = addon.Framework:GetSavedVars().Modules.FrameAuras.Debuffs

		assert(options.ColorByDispelType == true, "they ship on")

		switch:GetScript("OnClick")(switch)

		assert(options.ColorByDispelType == false, "and the switch turns them off")
	end)
end)
