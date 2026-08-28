-- The alerts options page, and how its grow control owns up to an approximate centre.

local fw = require("Framework")
local harness = require("AddonHarness")
local WowMock = require("WowMock")

local CENTER_CAVEAT = "Due to technical limitations we can't get centre aligned perfectly."

---@return table addon
local function Load()
	_G.MiniAurasDB = nil

	return harness.Run("MiniAuras", {}).Addon
end

---Whether the page is somewhere above the frame in its parent chain.
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

---The control on the alerts page carrying a given label. Other module pages label their controls
---the same way, so the lookup is scoped to this page.
---@param addon table
---@param labelText string
---@return table?
local function LabelledOn(addon, labelText)
	local page = addon.Config.TabController:GetContent("Alerts")

	fw.not_nil(page, "the alerts tab exists")

	for _, frame in ipairs(WowMock.Frames) do
		local label = frame.Label

		if label and label.GetText and label:GetText() == labelText and Inside(frame, page) then
			return frame
		end
	end

	return nil
end

---The block of text on the alerts page carrying a given line.
---@param addon table
---@param text string
---@return table?
local function NoteFor(addon, text)
	local page = addon.Config.TabController:GetContent("Alerts")

	for _, frame in ipairs(WowMock.Frames) do
		if Inside(frame, page) then
			for index = 1, frame:GetNumRegions() do
				local region = select(index, frame:GetRegions())

				if region.GetText and region:GetText() == text then
					return frame
				end
			end
		end
	end

	return nil
end

---The body line a control hands the tooltip when the pointer arrives. OnEnter carries more than
---one hook once the control's own hover styling is attached, so all of them run.
---@param frame table
---@return string?
local function TooltipBodyOf(frame)
	local captured
	local previous = rawget(GameTooltip, "AddLine")

	GameTooltip.AddLine = function(_, line)
		captured = captured or line
	end

	for _, handler in ipairs(frame.__scripts.OnEnter or {}) do
		handler(frame)
	end

	GameTooltip.AddLine = previous

	return captured
end

fw.describe("Alerts page - the grow control", function()
	fw.it("calls the centre option approximate while the profile keeps CENTER", function()
		local addon = Load()

		-- The window and its pages are built on the first ask, which for a player is opening the
		-- options. Nothing exists to drive before that.
		addon.Config:EnsureWindow()

		local dropdown = LabelledOn(addon, addon.L["Grow"])

		fw.not_nil(dropdown, "the page offers the grow dropdown")

		local options = addon.Framework:GetSavedVars().Modules.Alerts

		fw.eq(options.Grow, "CENTER", "the shipped profile grows from the centre")

		dropdown:MiniRefresh()

		fw.eq(dropdown:GetText(), "CENTER-ish", "the control hedges what the option is called")
		fw.eq(options.Grow, "CENTER", "and the stored value is left as it was")
	end)

	fw.it("hands the caveat to the tooltip rather than a caption of its own", function()
		local addon = Load()

		addon.Config:EnsureWindow()

		local dropdown = LabelledOn(addon, addon.L["Grow"])

		fw.not_nil(dropdown, "the page offers the grow dropdown")
		fw.is_nil(NoteFor(addon, addon.L[CENTER_CAVEAT]), "the page carries no caption saying it")
		fw.eq(TooltipBodyOf(dropdown), addon.L[CENTER_CAVEAT], "and hovering the control does")
	end)
end)
