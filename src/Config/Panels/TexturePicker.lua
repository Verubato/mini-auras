---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local L = addon.L
local config = addon.Config
local artTextures = addon.Core.ArtTextures

-- The texture browser, over the art in Core/Display/Media/ArtTextures: the addon's own shapes
-- first, then the game's proc art. The grid is virtual like the icon one.
--
-- The path field below the grid is the way out of the list: anything the client has, including a
-- file another addon ships, works by typing where it lives.

local COLUMNS = 5
local VISIBLE_ROWS = 4
local CELL_WIDTH = 96
local CELL_HEIGHT = 84
local CELL_GAP = 4
local LABEL_HEIGHT = 14
local PITCH_X = CELL_WIDTH + CELL_GAP
local PITCH_Y = CELL_HEIGHT + CELL_GAP
local GRID_WIDTH = COLUMNS * PITCH_X
local GRID_HEIGHT = VISIBLE_ROWS * PITCH_Y
local SCROLLBAR_WIDTH = 16
local WINDOW_PADDING = 16
local WINDOW_WIDTH = GRID_WIDTH + SCROLLBAR_WIDTH + WINDOW_PADDING * 2
local WINDOW_HEIGHT = GRID_HEIGHT + 190
local BOX_WIDTH = 320
-- The art is drawn over a black background because that is what it was made for. A lit cell would
-- show every overlay as a grey box.
local CELL_BACKGROUND = { 0.04, 0.04, 0.05 }

local window
local buttons = {}
local topRow = 0
local selected
local search = ""
---@type ArtTextureEntry[]
local shown = {}
---@type fun(asset: string|number)?
local onSelect

---@class TexturePicker
local M = {}

config.TexturePicker = M

---Refills the list the grid is showing from the current search. Kept rather than re-filtered per
---scroll: the filter hands back a shared table that the next call overwrites.
local function Rebuild()
	local matches = artTextures:Filter(search)

	wipe(shown)

	for index = 1, #matches do
		shown[index] = matches[index]
	end
end

---@return number
local function MaxTopRow()
	return math.max(0, math.ceil(#shown / COLUMNS) - VISIBLE_ROWS)
end

local function RefreshGrid()
	local first = topRow * COLUMNS

	for index, button in ipairs(buttons) do
		local entry = shown[first + index]

		button.Value = entry and entry.Asset
		artTextures:SetAsset(button.Art, entry and entry.Asset)
		button.Caption:SetText(entry and entry.Label or "")
		button.Selected:SetShown(entry ~= nil and entry.Asset == selected)
		button:SetShown(entry ~= nil)
	end

	window.Count:SetText(string.format(L["%d textures"], #shown))
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

---Narrows the grid to what the search box holds, back at the top of the list.
---@param text string?
local function ApplySearch(text)
	text = tostring(text or "")

	if text == search then
		return
	end

	search = text

	Rebuild()

	topRow = -1
	window.ScrollBar:SetMinMaxValues(0, MaxTopRow())
	window.ScrollBar:SetValue(0)
	ScrollTo(0)
end

---@param asset string|number
local function Choose(asset)
	selected = asset

	if onSelect then
		onSelect(asset)
	end

	window:Hide()
end

---@param parent table
---@param index number
---@return table
local function CreateTextureButton(parent, index)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(CELL_WIDTH, CELL_HEIGHT)
	button:SetPoint("TOPLEFT", parent, "TOPLEFT",
		((index - 1) % COLUMNS) * PITCH_X,
		-math.floor((index - 1) / COLUMNS) * PITCH_Y)

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
	background:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, LABEL_HEIGHT)
	background:SetColorTexture(CELL_BACKGROUND[1], CELL_BACKGROUND[2], CELL_BACKGROUND[3], 1)

	button.Art = button:CreateTexture(nil, "ARTWORK")
	button.Art:SetPoint("TOPLEFT", background, "TOPLEFT", 2, -2)
	button.Art:SetPoint("BOTTOMRIGHT", background, "BOTTOMRIGHT", -2, 2)
	button.Art:SetBlendMode("ADD")

	button.Caption = button:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	button.Caption:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 0)
	button.Caption:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 0)
	button.Caption:SetHeight(LABEL_HEIGHT)
	button.Caption:SetWordWrap(false)

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints(background)
	highlight:SetColorTexture(1, 1, 1, 0.15)

	button.Selected = button:CreateTexture(nil, "OVERLAY")
	button.Selected:SetPoint("TOPLEFT", background, "TOPLEFT", -2, 2)
	button.Selected:SetPoint("BOTTOMRIGHT", background, "BOTTOMRIGHT", 2, -2)
	button.Selected:SetColorTexture(1, 0.82, 0, 0.9)
	button.Selected:SetDrawLayer("BACKGROUND")
	button.Selected:Hide()

	button:SetScript("OnClick", function(self)
		if self.Value then
			Choose(self.Value)
		end
	end)

	return button
end

---@return table
local function GetOrCreateWindow()
	if window then
		return window
	end

	local win = CreateFrame("Frame", addonName .. "TexturePicker", UIParent, "BackdropTemplate")
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
	title:SetText(L["Choose a Texture"])
	title:SetTextColor(1, 0.82, 0)

	-- Above the grid rather than below it, because it decides what the grid holds.
	local searchBox = mini:EditBox({
		Parent = win,
		Width = BOX_WIDTH,
		GetValue = function()
			return search
		end,
		SetValue = ApplySearch,
	})
	local searchLabel = win:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	searchLabel:SetPoint("TOPLEFT", win, "TOPLEFT", WINDOW_PADDING, -44)
	searchLabel:SetText(L["Search"])

	-- InputBoxTemplate draws its field 6px outside its own left edge.
	searchBox.EditBox:SetPoint("LEFT", searchLabel, "RIGHT", 14, 0)
	-- Narrowed as it is typed rather than on Enter: a list this long is unusable if it only
	-- answers once the whole word is in.
	searchBox.EditBox:SetScript("OnTextChanged", function(box)
		ApplySearch(box:GetText())
	end)

	local grid = CreateFrame("Frame", nil, win)
	grid:SetSize(GRID_WIDTH, GRID_HEIGHT)
	grid:SetPoint("TOPLEFT", win, "TOPLEFT", WINDOW_PADDING, -72)
	grid:EnableMouseWheel(true)

	for index = 1, COLUMNS * VISIBLE_ROWS do
		buttons[index] = CreateTextureButton(grid, index)
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

	-- Typing a path is how anything the list does not carry gets used, so the field takes the
	-- choice on its own: what is in it when it is committed is the answer.
	local pathBox = mini:EditBox({
		Parent = win,
		LabelText = L["Texture path"],
		Width = BOX_WIDTH,
		GetValue = function()
			return type(selected) == "string" and selected or ""
		end,
		SetValue = function(value)
			Choose(tostring(value or ""))
		end,
	})
	pathBox.Label:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 6, -14)
	pathBox.EditBox:SetPoint("TOPLEFT", pathBox.Label, "BOTTOMLEFT", 6, -4)

	local closeBtn = mini:Button({
		Parent = win,
		Text = CLOSE,
		Width = 90,
		OnClick = function() win:Hide() end,
	})
	closeBtn:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -WINDOW_PADDING, 14)

	-- An empty asset is a group with no art, which is the state a new texture group starts in.
	local clearBtn = mini:Button({
		Parent = win,
		Text = L["Reset"],
		Width = 90,
		OnClick = function()
			Choose("")
		end,
	})
	clearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)

	local count = win:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	count:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", WINDOW_PADDING, 20)

	win.ScrollBar = scrollBar
	win.SearchBox = searchBox
	win.PathBox = pathBox
	win.Count = count
	window = win

	return win
end

---Opens the browser. The callback is handed the chosen art (a file id for the client's, a path
---for the addon's own), the path that was typed, or an empty string when the user resets it.
---@param current (string|number)? The art to highlight on open.
---@param callback fun(asset: string|number)
function M:Open(current, callback)
	local win = GetOrCreateWindow()

	selected = current
	onSelect = callback
	search = ""

	Rebuild()

	win.SearchBox.EditBox:SetText("")
	win.PathBox.EditBox:MiniRefresh()
	win.ScrollBar:SetMinMaxValues(0, MaxTopRow())

	-- Open on the row holding the current texture rather than at the top of a thousand.
	local startRow = 0

	for index, entry in ipairs(shown) do
		if entry.Asset == current then
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

---@class TexturePicker
---@field Open fun(self: table, current: (string|number)?, callback: fun(asset: string|number))
