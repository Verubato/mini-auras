---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local helpers = addon.Config.PanelHelpers
local spellSearch = addon.Core.SpellSearch
local SUGGESTION_ROWS = 8
local SUGGESTION_ROW_HEIGHT = 24
local POPUP_WIDTH = 280
-- The padding the rows sit inside, clear of the popup's border.
local POPUP_INSET = 6
-- Characters of spell name a suggestion row fits beside the id.
local MAX_SUGGESTION_NAME_LENGTH = 28

---@class SpellPicker
local M = {
	---The box's own size, so a caller can line another control up beside it and size its row.
	Width = 220,
	Height = 22,
}

addon.Config.SpellPicker = M

---@param spellId number
---@return string
local function SuggestionLabel(spellId)
	return helpers:SpellLabel(C_Spell.GetSpellName(spellId), spellId, MAX_SUGGESTION_NAME_LENGTH)
end

---@return number r
---@return number g
---@return number b
local function DefaultColor()
	return 1, 1, 1
end

---What the popup hangs off. The page a picker sits on is inside the options window's scroll
---frame, which cuts off anything drawn past its edge.
---@param frame table
---@return table
local function PopupHost(frame)
	local host = frame
	local above = host:GetParent()

	while above and above ~= UIParent do
		host = above
		above = host:GetParent()
	end

	return host
end

---An edit box that suggests spells as you type; picking one hands its id to opts.OnAccept.
---@param opts SpellPickerOptions
---@return table box
function M:Create(opts)
	local parent = opts.Parent
	local SuggestionColor = opts.LabelColor or DefaultColor
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	mini:FlattenEditBox(box)
	box:SetSize(M.Width, M.Height)
	box:SetAutoFocus(false)
	-- Per picker rather than shared: the rows are children of this picker's own popup, so a second
	-- picker reusing them would show its suggestions inside the first one's popup.
	local suggestionRows = {}

	box.OnAccept = opts.OnAccept

	-- Edit boxes have no placeholder of their own, so it is a font string behind the caret that
	-- goes away as soon as there is anything to read.
	local placeholder = box:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	placeholder:SetPoint("LEFT", box, "LEFT", 2, 0)
	placeholder:SetText(L["Spell ID / name"])

	local function UpdatePlaceholder()
		placeholder:SetShown(box:GetText() == "" and not box:HasFocus())
	end

	local popup = CreateFrame("Frame", nil, PopupHost(parent), "BackdropTemplate")
	popup:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -POPUP_INSET, -2)
	popup:SetWidth(POPUP_WIDTH)
	popup:SetFrameStrata("DIALOG")
	-- Above every row it drops over, not just its immediate parent.
	popup:SetFrameLevel(parent:GetFrameLevel() + 20)
	popup:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	popup:SetBackdropColor(0, 0, 0, 0.95)
	popup:Hide()
	-- Clicks on the padding close it; the focus handler below has already fired by then.
	popup:EnableMouse(true)
	popup:SetScript("OnMouseDown", function(popupSelf)
		popupSelf:Hide()
	end)

	-- Which suggestion the arrow keys have walked to, zero for none. Enter takes this one when
	-- there is one, and the best match otherwise.
	local highlighted = 0
	local shownRows = 0

	local function ApplyHighlight()
		for index = 1, shownRows do
			suggestionRows[index].Selected:SetShown(index == highlighted)
		end
	end

	local function HidePopup()
		popup:Hide()
		highlighted = 0
	end

	---@param step number -1 for up, 1 for down.
	local function MoveHighlight(step)
		if shownRows == 0 then
			return
		end

		if highlighted == 0 then
			-- Entering the list from the box: down starts at the top, up at the bottom.
			highlighted = step > 0 and 1 or shownRows
		else
			highlighted = (highlighted + step - 1) % shownRows + 1
		end

		ApplyHighlight()
	end

	local function ShowSuggestions()
		local results = spellSearch:Search(box:GetText(), SUGGESTION_ROWS)
		local y = -POPUP_INSET

		for index, entry in ipairs(results) do
			local row = suggestionRows[index]

			if not row then
				row = CreateFrame("Button", nil, popup)
				row:SetSize(POPUP_WIDTH - POPUP_INSET * 2, SUGGESTION_ROW_HEIGHT)
				row.Icon = helpers:CreateSpellIcon(row)
				row.Icon:SetPoint("LEFT", row, "LEFT", POPUP_INSET, 0)
				row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				row.Text:SetPoint("LEFT", row.Icon, "RIGHT", 6, 0)

				local highlight = row:CreateTexture(nil, "HIGHLIGHT")
				highlight:SetAllPoints()
				highlight:SetColorTexture(1, 1, 1, 0.08)

				-- Separate from the hover highlight, which the mouse owns.
				row.Selected = row:CreateTexture(nil, "ARTWORK")
				row.Selected:SetAllPoints()
				row.Selected:SetColorTexture(1, 0.82, 0, 0.2)
				row.Selected:Hide()

				suggestionRows[index] = row
			end

			row.SpellId = entry.Id
			row.Icon.SpellId = entry.Id
			row.Icon.Icon:SetTexture(C_Spell.GetSpellTexture(entry.Id))
			row.Text:SetText(SuggestionLabel(entry.Id))
			row.Text:SetTextColor(SuggestionColor(entry.Id))
			row:SetPoint("TOPLEFT", popup, "TOPLEFT", 0, y)
			row:SetScript("OnClick", function()
				box:SetText("")
				box:ClearFocus()
				HidePopup()
				box.OnAccept(entry.Id)
			end)
			row:Show()

			y = y - SUGGESTION_ROW_HEIGHT
		end

		for index = #results + 1, #suggestionRows do
			suggestionRows[index]:Hide()
		end

		shownRows = #results

		if shownRows == 0 then
			HidePopup()
			return
		end

		-- A new query invalidates wherever the arrows had walked to.
		highlighted = 0
		ApplyHighlight()

		popup:SetHeight(-y + POPUP_INSET)
		popup:Show()
	end

	box:SetScript("OnTextChanged", function(_, userInput)
		-- Fires for SetText as well as typing, so every path that clears the box lands here.
		UpdatePlaceholder()

		if userInput then
			ShowSuggestions()
		end
	end)

	box:SetScript("OnEditFocusGained", UpdatePlaceholder)

	-- Up and down walk the suggestions. Left and right are the caret's, so they fall through.
	box:SetScript("OnArrowPressed", function(_, key)
		if key == "DOWN" then
			MoveHighlight(1)
		elseif key == "UP" then
			MoveHighlight(-1)
		end
	end)

	box:SetScript("OnEnterPressed", function(boxSelf)
		-- Whatever the arrows landed on, else the best suggestion, which for a fully typed id
		-- is that id.
		local row = highlighted > 0 and suggestionRows[highlighted]
		local spellId = row and row.SpellId

		if not spellId and opts.AcceptsTypedIds then
			-- A whole id is an answer rather than a search, and the shipped index is only part
			-- of the game.
			spellId = spellSearch:QueryId(boxSelf:GetText())
		end

		if not spellId then
			local results = spellSearch:Search(boxSelf:GetText(), 1)

			spellId = results[1] and results[1].Id
		end

		boxSelf:SetText("")
		boxSelf:ClearFocus()
		HidePopup()

		if spellId then
			box.OnAccept(spellId)
		end
	end)

	box:SetScript("OnEscapePressed", function(boxSelf)
		boxSelf:SetText("")
		boxSelf:ClearFocus()
		HidePopup()
	end)

	box:SetScript("OnEditFocusLost", function()
		UpdatePlaceholder()

		-- A click pulls focus on mouse down, before the row sees it on mouse up. Hiding here
		-- would take the row out from under the cursor. The row closes the popup itself.
		if popup:IsMouseOver() then
			return
		end

		HidePopup()
	end)

	-- The popup hangs off the window rather than the page, so a tab change has to take it away.
	parent:HookScript("OnHide", HidePopup)

	UpdatePlaceholder()

	return box
end

---@class SpellPickerOptions
---@field Parent table The page the box belongs to; the popup is hung off the window above it.
---@field OnAccept fun(spellId: number) Takes the picked spell.
---@field LabelColor (fun(spellId: number): number, number, number)? Suggestion text colour, white by default.
---@field AcceptsTypedIds boolean? Whether Enter takes a whole id nothing matched.
