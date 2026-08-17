local addonName, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L
local dropDownId = 1

-- A long item list runs off the bottom of the screen and everything below the edge becomes
-- unreachable. The modern menu system can lay a menu out as a grid, and scroll it when even
-- the grid is too tall. Older implementations can only scroll, and the LibUIDropDownMenu
-- path can do neither.
local GRID_THRESHOLD = 10
local DEFAULT_MAX_ROWS = 20
-- Approximate height of one menu row, used to turn a row budget into a pixel extent.
local ROW_EXTENT = 20
-- The face height, matching the toggle track and the slider's value chip.
local FIELD_HEIGHT = 20
local CHEVRON_SIZE = 12
local CHEVRON_INSET = 7

---Hangs a tooltip off a built dropdown. Hooked rather than set, so whatever the template
---already does on hover survives.
local function AttachTooltip(dropdown, options)
	local title = options.TooltipTitle or options.LabelText

	if not title or title:match("^%s*$") then
		title = L["Information"]
	end

	dropdown:HookScript("OnEnter", function(ddSelf)
		GameTooltip:SetOwner(ddSelf, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 0.82, 0)
		GameTooltip:AddLine(options.Tooltip, 1, 1, 1, true)
		GameTooltip:Show()
	end)

	dropdown:HookScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

---Reserves a globally unique frame name. Dropdown templates misbehave when unnamed, and
---the name must be addon-scoped or two Mini addons loaded together collide on the global.
local function NextName()
	local name = addonName .. "Dropdown" .. dropDownId
	dropDownId = dropDownId + 1

	return name
end

---Mirrors Blizzard's AutoCalculateColumns, so the resulting row count can be predicted
---without reaching into menu internals.
local function AutoColumns(count)
	if count > 36 then
		return 4
	elseif count > 24 then
		return 3
	elseif count > GRID_THRESHOLD then
		return 2
	end

	return 1
end

---Lays a modern menu out so every item stays reachable on screen.
---@param columns number? explicit column count, or nil to let the menu decide
local function ApplyMenuLayout(rootDescription, count, columns, maxRows)
	local effective = columns or AutoColumns(count)

	if effective > 1 and rootDescription.SetGridMode and MenuConstants then
		if columns then
			rootDescription:SetGridMode(MenuConstants.VerticalGridDirection, columns)
		else
			-- No column count: the menu picks one from the item count itself.
			rootDescription:SetGridMode(MenuConstants.VerticalGridDirection)
		end
	end

	-- Four columns still isn't enough for a really long list, so let it scroll as well.
	if rootDescription.SetScrollMode and math.ceil(count / effective) > maxRows then
		rootDescription:SetScrollMode(maxRows * ROW_EXTENT)
	end
end

---Swaps the retail template's parchment face for the shared soft-cornered chrome: dark
---rounded field with a 1px border, white text, chevron arrow, the common hover tint. Only
---the closed button restyles; the open menu stays stock on purpose, being Blizzard-owned
---internals across three implementations. The legacy and LibUIDropDownMenu paths keep stock
---art entirely: no styled consumer ships to the clients that use them, and restyling their
---composite art untested is all risk.
local function StyleModernFace(dd)
	if dd.Background then
		dd.Background:Hide()
	end

	-- The template's own hover art; the field tint below replaces it.
	local highlight = dd.GetHighlightTexture and dd:GetHighlightTexture()

	if highlight then
		highlight:SetAlpha(0)
	end

	local field = GUI.RoundedField(dd, FIELD_HEIGHT, "BACKGROUND")
	field.Fill:SetColor(GUI.FieldIdle.r, GUI.FieldIdle.g, GUI.FieldIdle.b, 1)
	field.Border:SetColor(GUI.LineIdle.r, GUI.LineIdle.g, GUI.LineIdle.b, 1)
	dd.Field = field

	-- The template's arrow can't be retextured: its mixin re-stamps the stock atlas on every
	-- button state change (hover, press). Blank it for good and draw our own chevron, which
	-- the mixin never touches. Alpha 0 rather than Hide, because the mixin also re-Shows it.
	if dd.Arrow then
		dd.Arrow:SetAlpha(0)
	end

	local chevron = dd:CreateTexture(nil, "ARTWORK")
	chevron:SetTexture(GUI.ChevronTexture)
	GUI.CropIcon(chevron)
	chevron:SetSize(CHEVRON_SIZE, CHEVRON_SIZE)
	chevron:SetPoint("RIGHT", dd, "RIGHT", -CHEVRON_INSET, 0)
	chevron:SetVertexColor(GUI.KnobIdle.r, GUI.KnobIdle.g, GUI.KnobIdle.b, 1)
	dd.Chevron = chevron

	local text = dd.GetFontString and dd:GetFontString()

	if text then
		text:SetTextColor(1, 1, 1, 1)
	end

	-- Hooked, not set: the template's mixin owns these scripts. The text color is re-asserted
	-- because state changes can swap the font object, which resets it.
	dd:HookScript("OnEnter", function()
		field.Fill:SetColor(GUI.FieldHover.r, GUI.FieldHover.g, GUI.FieldHover.b, 1)
		field.Border:SetColor(GUI.LineHover.r, GUI.LineHover.g, GUI.LineHover.b, 1)
		chevron:SetVertexColor(GUI.KnobHover.r, GUI.KnobHover.g, GUI.KnobHover.b, 1)

		if text then
			text:SetTextColor(1, 1, 1, 1)
		end
	end)

	dd:HookScript("OnLeave", function()
		field.Fill:SetColor(GUI.FieldIdle.r, GUI.FieldIdle.g, GUI.FieldIdle.b, 1)
		field.Border:SetColor(GUI.LineIdle.r, GUI.LineIdle.g, GUI.LineIdle.b, 1)
		chevron:SetVertexColor(GUI.KnobIdle.r, GUI.KnobIdle.g, GUI.KnobIdle.b, 1)

		if text then
			text:SetTextColor(1, 1, 1, 1)
		end
	end)
end

---Creates a dropdown menu using the specified options.
---@param options DropdownOptions
---@return table control the dropdown menu control, with a Label field when LabelText is set
---@return boolean isModern true if a modern dropdown was used, otherwise false
function M:Dropdown(options)
	if not options then
		error("Dropdown - options must not be nil.")
	end

	if not options.Parent or not options.GetValue or not options.SetValue or not options.Items then
		error("Dropdown - invalid options.")
	end

	local label
	local width = options.Width

	if options.LabelText then
		label = options.Parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetText(options.LabelText)

		-- The label eats into the requested width so the pair fits the caller's budget.
		-- Clamped because a long label against a small budget would otherwise go negative,
		-- and a non-positive width is a hard error rather than a squashed control.
		if width then
			width = math.max(1, width - M.HorizontalSpacing - label:GetStringWidth())
		end
	end

	local function GetText(value)
		return options.GetText and options.GetText(value) or tostring(value)
	end

	---Finishes off a freshly built control: sizing, label anchoring and refresh registration.
	---@param setWidth fun(dd:table, width:number) each dropdown flavor resizes differently -
	---the legacy templates only respond to their own UIDropDownMenu_SetWidth, not Frame:SetWidth.
	local function Attach(dd, isModern, setWidth)
		if width then
			setWidth(dd, width)
		end

		if label then
			dd.Label = label
			dd:SetPoint("LEFT", label, "RIGHT", M.HorizontalSpacing, 0)
		end

		if options.Tooltip then
			AttachTooltip(dd, options)
		end

		GUI.AddControlForRefresh(options.Parent, dd)

		return dd, isModern
	end

	local maxRows = options.MaxRows or DEFAULT_MAX_ROWS

	if MenuUtil and MenuUtil.CreateRadioMenu then
		local dd = CreateFrame("DropdownButton", nil, options.Parent, "WowStyle1DropdownTemplate")
		dd:SetupMenu(function(_, rootDescription)
			-- Inside SetupMenu so the layout tracks an Items list that changes at runtime.
			ApplyMenuLayout(rootDescription, #options.Items, options.Columns, maxRows)

			for _, value in ipairs(options.Items) do
				local radio = rootDescription:CreateRadio(GetText(value), function(x)
					return x == options.GetValue()
				end, function()
					options.SetValue(value)
				end, value)

				-- Modern menus only: the legacy paths have no per-row hook, and a row without
				-- its decoration is just a plain row.
				if options.DecorateItem and radio and radio.AddInitializer then
					radio:AddInitializer(function(button)
						options.DecorateItem(button, value)
					end)
				end
			end
		end)

		function dd.MiniRefresh(ddSelf)
			ddSelf:Update()
			ddSelf:SetText(GetText(options.GetValue()))
		end

		if GUI.IsStyled(options) then
			StyleModernFace(dd)
		end

		return Attach(dd, true, dd.SetWidth)
	end

	local libDD = LibStub and LibStub:GetLibrary("LibUIDropDownMenu-4.0", true)

	if libDD then
		-- needs a name to not bug out
		local dd = libDD:Create_UIDropDownMenu(NextName(), options.Parent)

		libDD:UIDropDownMenu_Initialize(dd, function()
			for _, value in ipairs(options.Items) do
				local info = libDD:UIDropDownMenu_CreateInfo()
				info.text = GetText(value)
				info.value = value

				info.checked = function()
					return options.GetValue() == value
				end

				local id = dd:GetID(info)

				-- onclick handler
				info.func = function()
					libDD:UIDropDownMenu_SetSelectedID(dd, id)
					libDD:UIDropDownMenu_SetText(dd, GetText(value))

					options.SetValue(value)
				end

				libDD:UIDropDownMenu_AddButton(info, 1)

				if options.GetValue() == value then
					libDD:UIDropDownMenu_SetSelectedID(dd, id)
				end
			end
		end)

		function dd.MiniRefresh()
			libDD:UIDropDownMenu_SetText(dd, GetText(options.GetValue()))
		end

		return Attach(dd, false, function(control, value)
			libDD:UIDropDownMenu_SetWidth(control, value)
		end)
	end

	-- UIDropDownMenuTemplate is nil, but still usable
	if UIDropDownMenu_Initialize then
		local dd = CreateFrame("Frame", NextName(), options.Parent, "UIDropDownMenuTemplate")

		UIDropDownMenu_Initialize(dd, function()
			for _, value in ipairs(options.Items) do
				local info = UIDropDownMenu_CreateInfo()
				info.text = GetText(value)
				info.value = value

				info.checked = function()
					return options.GetValue() == value
				end

				local id = dd:GetID(info)

				-- onclick handler
				info.func = function()
					UIDropDownMenu_SetSelectedID(dd, id)
					UIDropDownMenu_SetText(dd, GetText(value))

					options.SetValue(value)

					CloseDropDownMenus()
				end

				UIDropDownMenu_AddButton(info, 1)

				if options.GetValue() == value then
					UIDropDownMenu_SetSelectedID(dd, id)
				end
			end
		end)

		-- No grid on this path, but it can at least scroll rather than run off screen.
		if UIDropDownMenu_SetMaxHeight and #options.Items > maxRows then
			UIDropDownMenu_SetMaxHeight(dd, maxRows * ROW_EXTENT)
		end

		function dd.MiniRefresh()
			UIDropDownMenu_SetText(dd, GetText(options.GetValue()))
		end

		return Attach(dd, false, UIDropDownMenu_SetWidth)
	end

	error("Failed to create a dropdown control")
end

---@class DropdownOptions
---@field Parent table
---@field Items any[]
---@field LabelText string?
---@field Tooltip string? Shown on hover. Modern menus only; the legacy frames never see the hover.
---@field TooltipTitle string? Tooltip heading, for a caller that draws its own label.
---@field Width number?
---@field Columns number? Fixed column count; omit to scale with the item count, 1 to opt out
---@field MaxRows number? Rows per column before the menu scrolls, default 20
---@field GetValue fun(): any
---@field SetValue fun(value: any)
---@field GetText? fun(value: any): string
---@field DecorateItem? fun(button: table, value: any) Runs as the open menu builds each item's
---row, for per-row looks the menu system cannot express (e.g. a font list previewing itself).
---Modern menus only; the legacy paths show plain rows.
