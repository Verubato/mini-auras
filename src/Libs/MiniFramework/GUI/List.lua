local _, addon = ...
local M = addon.Framework
local L = M.L

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

		local y = options.RowGap or -2

		for i, item in ipairs(items) do
			local row = rows[i]

			if not row then
				row = CreateFrame("Button", nil, content)
				row:SetSize(options.RowWidth, options.RowHeight)

				row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				row.Text:SetPoint("LEFT", 0, 0)

				row.Remove = M:Button({
					Parent = row,
					-- REMOVE is a Blizzard global, already localized in every client.
					Text = REMOVE or L["Remove"],
					Width = options.RemoveButtonWidth or 80,
					Height = options.RowHeight - 2,
					CustomStyling = options.CustomStyling,
				})
				row.Remove:SetPoint("RIGHT", 0, 0)

				rows[i] = row
			end

			row:SetPoint("TOPLEFT", 0, y)
			row.Text:SetText(item)
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

			y = y - options.RowHeight
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
