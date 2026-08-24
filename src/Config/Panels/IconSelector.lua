---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config

-- The icon browser, over the same list Blizzard's macro UI offers. There are ~40,000 icons, so
-- the grid is virtual: one page of buttons re-pointed at a slice of the list as it scrolls.

local COLUMNS = 12
local VISIBLE_ROWS = 8
local ICON_SIZE = 36
local ICON_GAP = 4
local PITCH = ICON_SIZE + ICON_GAP
local GRID_WIDTH = COLUMNS * PITCH
local GRID_HEIGHT = VISIBLE_ROWS * PITCH
local SCROLLBAR_WIDTH = 16
local WINDOW_PADDING = 16
local WINDOW_WIDTH = GRID_WIDTH + SCROLLBAR_WIDTH + WINDOW_PADDING * 2
local WINDOW_HEIGHT = GRID_HEIGHT + 96

---@type (string|number)[]?
local icons
local window
local buttons = {}
local topRow = 0
local selected
---@type fun(icon: string|number)?
local onSelect

---@class IconSelector
local M = {}

config.IconSelector = M

---Every icon the client will hand over. Three APIs have carried this list, so each is tried in
---turn. Built once, since it never changes during a session.
---@return (string|number)[]
local function BuildIconList()
	local list = {}

	-- Current retail.
	if IconDataProviderMixin and CreateAndInitFromMixin then
		local extraType = IconDataProviderExtraType and IconDataProviderExtraType.None
		local ok, provider = pcall(CreateAndInitFromMixin, IconDataProviderMixin, extraType)

		if ok and type(provider) == "table" and provider.GetNumIcons and provider.GetIconByIndex then
			for index = 1, provider:GetNumIcons() do
				list[#list + 1] = provider:GetIconByIndex(index)
			end

			if provider.Release then
				provider:Release()
			end
		end
	end

	-- Older retail and classic.
	if #list == 0 and GetMacroIcons then
		GetMacroIcons(list)

		if GetMacroItemIcons then
			GetMacroItemIcons(list)
		end
	end

	-- Older still: indexed one at a time.
	if #list == 0 and GetNumMacroIcons and GetMacroIconInfo then
		for index = 1, GetNumMacroIcons() do
			list[#list + 1] = GetMacroIconInfo(index)
		end
	end

	return list
end

---@return (string|number)[]
local function IconList()
	if not icons then
		icons = BuildIconList()
	end

	return icons
end

---@return number
local function MaxTopRow()
	return math.max(0, math.ceil(#IconList() / COLUMNS) - VISIBLE_ROWS)
end

local function RefreshGrid()
	local list = IconList()
	local first = topRow * COLUMNS

	for index, button in ipairs(buttons) do
		local icon = list[first + index]

		button.Icon:SetTexture(icon)
		button.Value = icon
		button.Selected:SetShown(icon ~= nil and icon == selected)
		button:SetShown(icon ~= nil)
	end
end

---@param row number
local function ScrollTo(row)
	row = math.max(0, math.min(MaxTopRow(), math.floor(row + 0.5)))

	if row == topRow then
		return
	end

	topRow = row
	RefreshGrid()
end

---@param parent table
---@param index number
---@return table
local function CreateIconButton(parent, index)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(ICON_SIZE, ICON_SIZE)
	button:SetPoint("TOPLEFT", parent, "TOPLEFT",
		((index - 1) % COLUMNS) * PITCH,
		-math.floor((index - 1) / COLUMNS) * PITCH)

	button.Icon = button:CreateTexture(nil, "ARTWORK")
	button.Icon:SetAllPoints()
	button.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints()
	highlight:SetColorTexture(1, 1, 1, 0.25)

	button.Selected = button:CreateTexture(nil, "OVERLAY")
	button.Selected:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
	button.Selected:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
	button.Selected:SetColorTexture(1, 0.82, 0, 0.9)
	button.Selected:SetDrawLayer("BACKGROUND")
	button.Selected:Hide()

	button:SetScript("OnClick", function(self)
		if not self.Value then
			return
		end

		selected = self.Value

		if onSelect then
			onSelect(self.Value)
		end

		window:Hide()
	end)

	return button
end

---@return table
local function GetOrCreateWindow()
	if window then
		return window
	end

	local win = CreateFrame("Frame", addonName .. "IconSelector", UIParent, "BackdropTemplate")
	win:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
	win:SetFrameStrata("FULLSCREEN_DIALOG")
	win:SetClampedToScreen(true)
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:Hide()
	win:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	win:SetBackdropColor(0, 0, 0, 0.92)

	local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", win, "TOP", 0, -12)
	title:SetText(L["Choose an Icon"])
	title:SetTextColor(1, 0.82, 0)

	local grid = CreateFrame("Frame", nil, win)
	grid:SetSize(GRID_WIDTH, GRID_HEIGHT)
	grid:SetPoint("TOPLEFT", win, "TOPLEFT", WINDOW_PADDING, -42)
	grid:EnableMouseWheel(true)

	for index = 1, COLUMNS * VISIBLE_ROWS do
		buttons[index] = CreateIconButton(grid, index)
	end

	local scrollBar = CreateFrame("Slider", nil, win, "BackdropTemplate")
	scrollBar:SetWidth(SCROLLBAR_WIDTH - 6)
	scrollBar:SetPoint("TOPLEFT", grid, "TOPRIGHT", 6, 0)
	scrollBar:SetPoint("BOTTOMLEFT", grid, "BOTTOMRIGHT", 6, 0)
	scrollBar:SetOrientation("VERTICAL")
	scrollBar:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	scrollBar:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
	scrollBar:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.8)
	scrollBar:SetValueStep(1)
	scrollBar:SetObeyStepOnDrag(true)

	local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
	thumb:SetColorTexture(0.55, 0.55, 0.55, 0.85)
	thumb:SetSize(SCROLLBAR_WIDTH - 6, 40)
	scrollBar:SetThumbTexture(thumb)

	scrollBar:SetScript("OnValueChanged", function(_, value)
		ScrollTo(value)
	end)

	grid:SetScript("OnMouseWheel", function(_, delta)
		scrollBar:SetValue(topRow - delta * 3)
	end)

	local closeBtn = mini:Button({
		Parent = win,
		Text = CLOSE,
		Width = 90,
		OnClick = function() win:Hide() end,
	})
	closeBtn:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -WINDOW_PADDING, 14)

	-- An empty icon puts the group back to borrowing its first spell's.
	local clearBtn = mini:Button({
		Parent = win,
		Text = L["Reset"],
		Width = 90,
		OnClick = function()
			selected = nil

			if onSelect then
				onSelect("")
			end

			win:Hide()
		end,
	})
	clearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)

	local count = win:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	count:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", WINDOW_PADDING, 20)

	win.ScrollBar = scrollBar
	win.Count = count
	window = win

	return win
end

---Opens the browser. The callback is handed the chosen texture, or an empty string when the
---user resets it.
---@param current (string|number)? The icon to highlight on open.
---@param callback fun(icon: string|number)
function M:Open(current, callback)
	local win = GetOrCreateWindow()
	local list = IconList()

	selected = current
	onSelect = callback

	win.Count:SetText(string.format(L["%d icons"], #list))
	win.ScrollBar:SetMinMaxValues(0, MaxTopRow())

	-- Open on the row holding the current icon rather than at the top of forty thousand.
	local startRow = 0

	for index, icon in ipairs(list) do
		if icon == current then
			startRow = math.floor((index - 1) / COLUMNS)
			break
		end
	end

	topRow = -1
	win.ScrollBar:SetValue(math.min(startRow, MaxTopRow()))
	ScrollTo(startRow)

	win:ClearAllPoints()
	win:SetPoint("CENTER", UIParent, "CENTER")
	win:Show()
end

---@class IconSelector
---@field Open fun(self: table, current: (string|number)?, callback: fun(icon: string|number))
