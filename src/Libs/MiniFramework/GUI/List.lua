local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L

-- Breathing room inside a styled row, whose field art runs to the row's own edges.
local TEXT_INSET = 10
local REMOVE_INSET = 4
local ROW_GAP = 2

---@param field table the row's RoundedField, or nil on an unstyled row
local function SetRowIdle(field)
	if not field then
		return
	end

	field.Fill:SetColor(GUI.FieldIdle.r, GUI.FieldIdle.g, GUI.FieldIdle.b, 0.7)
	field.Border:SetColor(GUI.LineIdle.r, GUI.LineIdle.g, GUI.LineIdle.b, 0.8)
end

---@param field table
local function SetRowHover(field)
	field.Fill:SetColor(GUI.FieldHover.r, GUI.FieldHover.g, GUI.FieldHover.b, 0.9)
	field.Border:SetColor(GUI.LineHover.r, GUI.LineHover.g, GUI.LineHover.b, 1)
end

---Creates a scrollable list of items, each with a Remove button.
---@param options ListOptions
---@return ListReturn
function M:List(options)
	if not options then
		error("List - options must not be nil.")
	end

	if not options.Parent or not options.RowWidth or not options.RowHeight then
		error("List - invalid options.")
	end

	local styled = GUI.IsStyled(options)

	local scroll = CreateFrame("ScrollFrame", nil, options.Parent, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, 0)
	scroll:SetPoint("BOTTOMRIGHT", options.Parent, "BOTTOMRIGHT", 0, 0)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)

	local rows = {}
	local items = {}

	local function RefreshScrollbar()
		-- show scroll bar if we've reached the max visible height
		local visibleHeight = scroll:GetHeight()
		local contentHeight = content:GetHeight()

		if not scroll.ScrollBar then
			return
		end

		if contentHeight <= visibleHeight then
			scroll.ScrollBar:Hide()
		else
			scroll.ScrollBar:Show()
		end
	end

	local function Refresh()
		for _, row in ipairs(rows) do
			row:Hide()
		end

		table.sort(items)

		local y = options.RowGap or (styled and -4 or -2)

		for i, item in ipairs(items) do
			local row = rows[i]

			if not row then
				row = CreateFrame("Button", nil, content)
				row:SetSize(options.RowWidth, options.RowHeight)

				if styled then
					local field = GUI.RoundedField(row, options.RowHeight, "BACKGROUND")

					row.Field = field
					SetRowIdle(field)

					row:SetScript("OnEnter", function()
						SetRowHover(field)
					end)

					row:SetScript("OnLeave", function()
						SetRowIdle(field)
					end)
				end

				row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				row.Text:SetPoint("LEFT", row, "LEFT", styled and TEXT_INSET or 0, 0)

				row.Remove = M:Button({
					Parent = row,
					-- REMOVE is a Blizzard global, already localized in every client.
					Text = REMOVE or L["Remove"],
					Width = options.RemoveButtonWidth or 80,
					Height = options.RowHeight - 2,
					-- The row and its button have to agree: a stock gold button on the dark field
					-- art reads as two different widgets stuck together.
					CustomStyling = styled,
				})
				row.Remove:SetPoint("RIGHT", row, "RIGHT", styled and -REMOVE_INSET or 0, 0)

				rows[i] = row
			end

			row:SetPoint("TOPLEFT", 0, y)
			row.Text:SetText(item)
			-- A row hidden while the mouse was over it never got its OnLeave, so it would come
			-- back out of the pool still lit.
			SetRowIdle(row.Field)
			row:Show()

			row.Remove:SetScript("OnClick", function()
				for idx, v in ipairs(items) do
					if v == item then
						table.remove(items, idx)
						break
					end
				end

				if options.OnRemove then
					options.OnRemove(item)
				end

				Refresh()
			end)

			y = y - options.RowHeight - (styled and ROW_GAP or 0)
		end

		content:SetHeight(math.max(1, -y + 10))
		RefreshScrollbar()
	end

	content:HookScript("OnShow", RefreshScrollbar)

	local api = {}

	function api.Add(_, item)
		table.insert(items, item)
		Refresh()
	end

	function api.SetItems(_, newItems)
		items = newItems or {}
		Refresh()
	end

	function api.GetItems(_)
		return items
	end

	api.ScrollFrame = scroll
	api.Content = content

	return api
end

---@class ListOptions
---@field Parent table
---@field RowGap number?
---@field RowWidth number
---@field RowHeight number
---@field RemoveButtonWidth number?
---@field CustomStyling boolean? Override the framework-wide styling default for the row buttons
---@field OnRemove fun(item: any)

---@class ListReturn
---@field ScrollFrame table
---@field Content table
---@field Add fun(self: table, item: any)
---@field SetItems fun(self: table, items: table)
---@field GetItems fun(self: table): table
