-- Captions on the options pages read white rather than Blizzard's gold. The colour rides on the
-- font object a caption was built with, so a test reads that template back.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---The font template behind the caption carrying a given text.
---@param text string
---@return string?
local function TemplateFor(text)
	for _, frame in ipairs(WowMock.Frames) do
		for _, region in ipairs({ frame:GetRegions() }) do
			if region.GetText and region:GetText() == text then
				return region.__template
			end
		end
	end

	return nil
end

---Clicks every button carrying a label, over a snapshot of the frame list.
---A click builds frames of its own, so walking the live list would never finish.
---@param text string
---@return number clicked
local function ClickAll(text)
	local snapshot = {}

	for index, frame in ipairs(WowMock.Frames) do
		snapshot[index] = frame
	end

	local clicked = 0

	for _, frame in ipairs(snapshot) do
		local label = frame.GetText and frame:GetText()

		if label == text and frame.Click then
			frame:Click()
			clicked = clicked + 1
		end
	end

	return clicked
end

fw.describe("Config - caption colours", function()
	fw.it("names an addon on its card in white", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		fw.eq(TemplateFor("FrameSort"), "GameFontHighlight", "the card's addon name")
	end)

	fw.it("captions both boxes in each import and export window in white", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		-- One button per page carries this label, and each opens a different window.
		fw.eq(ClickAll(addon.L["Import/Export"]), 2, "both import and export buttons")

		fw.eq(TemplateFor(addon.L["Export"]), "GameFontHighlight", "the aura export caption")
		fw.eq(TemplateFor(addon.L["Import"]), "GameFontHighlight", "the aura import caption")
		fw.eq(TemplateFor(addon.L["Export Profile"]), "GameFontHighlight", "the profile export caption")
		fw.eq(TemplateFor(addon.L["Import Profile"]), "GameFontHighlight", "the profile import caption")
	end)
end)
