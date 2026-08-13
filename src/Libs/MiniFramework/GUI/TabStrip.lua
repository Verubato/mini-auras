local _, addon = ...
local M = addon.Framework
local GUI = M.GUI

-- A row of tab buttons and nothing else. M:CreateTabs owns the content frames and sizes them to
-- fill their parent, which is wrong for a panel whose height is summed from its own rows, so this
-- hands back the strip and a selection callback and leaves the layout to the caller.

local DEFAULT_HEIGHT = 24
local DEFAULT_WIDTH = 120
local DEFAULT_SPACING = 4
local UNDERLINE_HEIGHT = 2
local BASELINE_ALPHA = 0.15
local HIGHLIGHT_ALPHA = 0.06
-- A faint plate under every tab: bare labels read as text, not as a control.
local PLATE_ALPHA = 0.06
-- Bottom alpha of the selected tab's accent wash; it fades to nothing at the top.
local WASH_ALPHA = 0.30

---Creates a horizontal strip of tab buttons.
---@param options TabStripOptions
---@return TabStripReturn
function M:TabStrip(options)
	if not options then
		error("TabStrip - options must not be nil.")
	end

	if not options.Parent or not options.Tabs or #options.Tabs == 0 then
		error("TabStrip - invalid options.")
	end

	local accent = GUI.Accent
	local idle = GUI.TabTextIdle
	local hover = GUI.TabTextHover
	local selectedColor = GUI.TabTextSelected
	local height = options.Height or DEFAULT_HEIGHT
	local width = options.Width or DEFAULT_WIDTH
	local spacing = options.Spacing or DEFAULT_SPACING

	local strip = CreateFrame("Frame", nil, options.Parent)
	strip:SetHeight(height)

	-- Runs the full width under every button, so a selected tab's accent reads as a break in the
	-- line rather than a stray underline.
	-- Unsnapped: this strip sits inside a scroll child, whose fractional alignment can snap a
	-- one-pixel line onto a zero-coverage row (see GUI.Unsnap).
	local baseline = strip:CreateTexture(nil, "ARTWORK")
	baseline:SetHeight(1)
	GUI.Unsnap(baseline)
	baseline:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0)
	baseline:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT", 0, 0)
	GUI.SetSolid(baseline, 1, 1, 1, BASELINE_ALPHA)

	local buttons = {}
	local selectedKey

	local function ApplyState()
		for _, button in ipairs(buttons) do
			local selected = button.Key == selectedKey

			button.Underline:SetShown(selected)
			button.Wash:SetShown(selected)

			if selected then
				button.Text:SetTextColor(selectedColor.r, selectedColor.g, selectedColor.b, 1)
			else
				button.Text:SetTextColor(idle.r, idle.g, idle.b, 1)
			end
		end
	end

	---@param key string
	local function Select(key)
		for _, button in ipairs(buttons) do
			if button.Key == key then
				selectedKey = key
				ApplyState()

				if options.OnSelect then
					options.OnSelect(key)
				end

				return
			end
		end
	end

	for index, tab in ipairs(options.Tabs) do
		local button = CreateFrame("Button", nil, strip)

		button.Key = tab.Key
		button:SetSize(width, height)
		button:SetPoint("LEFT", strip, "LEFT", (index - 1) * (width + spacing), 0)

		button.Text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		button.Text:SetPoint("CENTER")
		button.Text:SetText(tab.Title or tab.Key)

		button.Plate = button:CreateTexture(nil, "BACKGROUND")
		button.Plate:SetAllPoints()
		GUI.SetSolid(button.Plate, 1, 1, 1, PLATE_ALPHA)

		-- Selection wash rising from the underline, so the active tab is marked by more than
		-- text color.
		button.Wash = button:CreateTexture(nil, "BACKGROUND", nil, 1)
		button.Wash:SetAllPoints()
		GUI.SetGradientV(button.Wash, accent.r, accent.g, accent.b, WASH_ALPHA,
			accent.r, accent.g, accent.b, 0)
		button.Wash:Hide()

		local highlight = button:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		GUI.SetSolid(highlight, 1, 1, 1, HIGHLIGHT_ALPHA)

		button.Underline = button:CreateTexture(nil, "OVERLAY")
		button.Underline:SetHeight(UNDERLINE_HEIGHT)
		GUI.Unsnap(button.Underline)
		button.Underline:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
		button.Underline:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
		GUI.SetSolid(button.Underline, accent.r, accent.g, accent.b, 1)

		button:SetScript("OnClick", function(buttonSelf)
			Select(buttonSelf.Key)
		end)

		-- Brightening on hover only means anything for a tab that is not already the bright one.
		button:SetScript("OnEnter", function(buttonSelf)
			if buttonSelf.Key ~= selectedKey then
				buttonSelf.Text:SetTextColor(hover.r, hover.g, hover.b, 1)
			end
		end)
		button:SetScript("OnLeave", ApplyState)

		buttons[index] = button
	end

	selectedKey = options.InitialKey or options.Tabs[1].Key
	ApplyState()

	return {
		Frame = strip,
		Buttons = buttons,
		Select = function(_, key)
			Select(key)
		end,
		GetSelected = function()
			return selectedKey
		end,
	}
end

---@class TabStripTab
---@field Key string
---@field Title string?

---@class TabStripOptions
---@field Parent table
---@field Tabs TabStripTab[]
---@field InitialKey string?
---@field Height number?
---@field Width number? Width of one button
---@field Spacing number? Gap between buttons
---@field OnSelect fun(key: string)?

---@class TabStripReturn
---@field Frame table
---@field Buttons table[]
---@field Select fun(self: table, key: string)
---@field GetSelected fun(): string
