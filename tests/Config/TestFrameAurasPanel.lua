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

---The switch carrying a label on one particular tab of the frame auras page. Both aura rows offer
---the countdown switch under the same label, so the tab is named by a switch only it has. Every
---switch on a tab is built as a direct child of that tab's own page.
---@param addon table
---@param labelText string
---@param tabLabel string A label carried by one tab and no other.
---@return table?
local function SwitchOnTabWith(addon, labelText, tabLabel)
	local page = addon.Config.TabController:GetContent("FrameAuras")
	local sibling = SwitchFor(addon, tabLabel)

	fw.not_nil(sibling, "the page offers " .. tabLabel .. ", which names the tab")

	for _, frame in ipairs(WowMock.Frames) do
		if frame.__options and frame.__options.LabelText == labelText and Inside(frame, page)
			and frame:GetParent() == sibling:GetParent()
		then
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

fw.describe("Frame Auras page - the countdown numbers on each row", function()
	fw.it("gives each tab a switch that writes its own row and not the other", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		-- Mine belongs to the buff tab and Dispellable to the debuff tab, so each names the tab
		-- its switch has to be sitting on.
		local buffs = SwitchOnTabWith(addon, addon.L["Show numbers"], addon.L["Mine"])
		local debuffs = SwitchOnTabWith(addon, addon.L["Show numbers"], addon.L["Dispellable"])

		fw.not_nil(buffs, "the buff tab offers the numbers switch")
		fw.not_nil(debuffs, "and so does the debuff tab")
		assert(buffs ~= debuffs, "each tab has one of its own")

		local frameAuras = addon.Framework:GetSavedVars().Modules.FrameAuras

		assert(frameAuras.Buffs.EnableNumbers == true and frameAuras.Debuffs.EnableNumbers == true,
			"both rows ship counting down")

		buffs:GetScript("OnClick")(buffs)

		assert(frameAuras.Buffs.EnableNumbers == false, "the buff tab's switch writes the buff row")
		assert(frameAuras.Debuffs.EnableNumbers == true, "and leaves the debuff row counting")

		debuffs:GetScript("OnClick")(debuffs)

		assert(frameAuras.Debuffs.EnableNumbers == false, "the debuff tab's switch writes the debuff row")
	end)
end)
