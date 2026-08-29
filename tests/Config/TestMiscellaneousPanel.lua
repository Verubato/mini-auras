-- The miscellaneous options page, and the one switch on it that every module reads: whether the
-- test-mode captions are wanted at all.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---Whether a frame hangs off the page.
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

---The switch on the miscellaneous page carrying a given label. The panel keeps no references to
---them, so it is found the way a player reads it.
---@param addon table
---@param labelText string
---@return table?
local function SwitchFor(addon, labelText)
	local page = addon.Config.TabController:GetContent("Miscellaneous")

	fw.not_nil(page, "the miscellaneous tab exists")

	for _, frame in ipairs(WowMock.Frames) do
		if frame.__options and frame.__options.LabelText == labelText and Inside(frame, page) then
			return frame
		end
	end

	return nil
end

fw.describe("Miscellaneous page - the test mode captions", function()
	fw.it("offers a switch that ships on and writes the setting the captions read", function()
		local addon = Load()

		-- The window and its pages are built on the first ask, which for a player is opening the
		-- options. Nothing exists to drive before that.
		addon.Config:EnsureWindow()

		local switch = SwitchFor(addon, addon.L["Show Test Labels"])

		fw.not_nil(switch, "the page offers the captions switch")

		local db = addon.Framework:GetSavedVars()

		assert(db.ShowTestLabels == true, "the captions ship on")

		switch:GetScript("OnClick")(switch)

		assert(db.ShowTestLabels == false, "and the switch turns them off")
	end)
end)

fw.describe("Miscellaneous page - the sound debug messages", function()
	fw.it("offers a switch that ships on and writes the setting the registrations read", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		local switch = SwitchFor(addon, addon.L["Sound Debug Messages"])

		fw.not_nil(switch, "the page offers the debug switch")

		local db = addon.Framework:GetSavedVars()

		assert(db.SoundDebugMessages == true, "the messages ship on")

		switch:GetScript("OnClick")(switch)

		assert(db.SoundDebugMessages == false, "and the switch turns them off")
	end)
end)
