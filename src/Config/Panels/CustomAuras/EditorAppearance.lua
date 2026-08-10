---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local groups = addon.Modules.CustomAuras.Groups
local display = addon.Modules.CustomAuras.Display
local ui = addon.Config.CustomAurasUI
local CHECK_COLUMNS = 5
local CHECK_ROW_HEIGHT = 30
-- Clearance a slider needs above itself for the value box and its label.
local SLIDER_HEADROOM = 34
local SLIDER_ROW_HEIGHT = SLIDER_HEADROOM + 34
local SLIDER_GAP = 45
local SORT_OPTIONS = { "OLDEST", "LONGEST", "SHORTEST" }
local GROW_OPTIONS = { "LEFT", "RIGHT", "CENTER", "DOWN", "UP" }
-- A number this short does not need a dropdown's column, but the label does: "Desplazamiento X"
-- is the longest translation and needs about 110px.
local OFFSET_COLUMN = 120
local OFFSET_BOX_WIDTH = 70
-- Wider than any sane screen, so typing is never the thing that stops a group being placed.
local OFFSET_LIMIT = 2000

---Builds the appearance tab. The toggles lead: they are the ones read at a glance, while the
---dropdowns and sliders are set once and left alone.
---@param ctx CustomAurasEditorContext
function ui.BuildAppearanceTab(ctx)
	local appearancePanel = ctx.AppearancePanel
	local checkColumn = mini:ColumnWidth(CHECK_COLUMNS, 0, 0)
	-- Two sliders across the row rather than three, so each spans two dropdown columns and the
	-- pair fills the width instead of leaving a third of it empty.
	local sliderWidth = ui.DropdownColumn * 2 - SLIDER_GAP / 2

	local checkRow = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, 4)
	local checkRow2 = ctx.NewRow(appearancePanel, CHECK_ROW_HEIGHT, 4)
	local settingsControlsRow = ctx.NewRow(appearancePanel, ui.DropdownRowHeight)
	local sliderRow = ctx.NewRow(appearancePanel, SLIDER_ROW_HEIGHT)

	ctx.Dropdown(L["Order"], {
		Items = SORT_OPTIONS,
		GetText = function(value)
			if value == groups.Sort.Longest then
				return L["Longest remaining first"]
			elseif value == groups.Sort.Shortest then
				return L["Shortest remaining first"]
			end

			return L["Oldest first"]
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.Sort or groups.Sort.Oldest
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Sort = value
				ui.Apply()
			end
		end,
	}, settingsControlsRow, ui.DropdownColumn)

	ctx.Dropdown(L["Grow"], {
		Items = GROW_OPTIONS,
		GetValue = function()
			local group = ui.Current()
			return group and group.Grow or "CENTER"
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Grow = value
				ui.Apply()
			end
		end,
	}, settingsControlsRow, 0)

	---The pair a drag writes: a screen group keeps a screen position, every other anchor keeps an
	---offset from the frame it hangs off.
	---@param group CustomAuraGroup
	---@return table
	local function OffsetTarget(group)
		return group.Anchor == groups.Anchor.Screen and group.Position or group.Offset
	end

	---@param labelText string
	---@param axis string "X" or "Y"
	---@param x number
	---@return table
	local function OffsetBox(labelText, axis, x)
		local box = mini:EditBox({
			Parent = appearancePanel,
			LabelText = labelText,
			Numeric = true,
			AllowNegatives = true,
			Width = OFFSET_BOX_WIDTH,
			GetValue = function()
				local group = ui.Current()
				local target = group and OffsetTarget(group)

				-- A drag leaves a fraction behind until it stops, which is not worth showing.
				return target and math.floor((target[axis] or 0) + 0.5) or 0
			end,
			SetValue = function(value)
				local group = ui.Current()

				if not group then
					return
				end

				local target = OffsetTarget(group)

				target[axis] = mini:ClampInt(value, -OFFSET_LIMIT, OFFSET_LIMIT, target[axis])
				ui.Apply()
			end,
		})

		box.Label:SetPoint("TOPLEFT", settingsControlsRow, "TOPLEFT", x, 0)
		-- InputBoxTemplate draws its field 6px outside its own left edge.
		box.EditBox:SetPoint("TOPLEFT", box.Label, "BOTTOMLEFT", 6, -4)

		return box
	end

	local offsetXBox = OffsetBox(L["Offset X"], "X", ui.DropdownColumn * 2)
	local offsetYBox = OffsetBox(L["Offset Y"], "Y", ui.DropdownColumn * 2 + OFFSET_COLUMN)

	-- A drag writes the same fields these boxes edit, so they catch up the moment it ends.
	display:OnPositionChanged(function(groupId)
		local group = ui.Current()

		if group and group.Id == groupId then
			offsetXBox.EditBox:MiniRefresh()
			offsetYBox.EditBox:MiniRefresh()
		end
	end)

	local checkboxes = {
		{
			Column = 0,
			Label = L["Glow icons"], Tooltip = L["Show a glow around the icons."],
			Get = function(group) return group.Icons.Glow end,
			Set = function(group, value) group.Icons.Glow = value end,
		},
		{
			Column = 1,
			Label = L["Show border"], Tooltip = L["Draw a border around the icons."],
			Get = function(group) return group.Icons.Border end,
			Set = function(group, value) group.Icons.Border = value end,
		},
		{
			Column = 2,
			Label = L["Reverse swipe"], Tooltip = L["Reverses the direction of the cooldown swipe animation."],
			Get = function(group) return group.Icons.ReverseCooldown end,
			Set = function(group, value) group.Icons.ReverseCooldown = value end,
		},
		{
			Column = 3,
			Label = L["Show tooltips"], Tooltip = L["Shows a spell tooltip when hovering over an icon."],
			Get = function(group) return group.Icons.ShowTooltips end,
			Set = function(group, value) group.Icons.ShowTooltips = value end,
		},
		{
			Column = 4,
			Label = L["Pandemic"],
			Tooltip = L["Highlight an aura during its refresh window, where re-casting adds the remaining time on top. The game decides the window per spell, and only your own re-castable effects have one."],
			Get = function(group) return group.Icons.Pandemic end,
			Set = function(group, value) group.Icons.Pandemic = value end,
		},
	}

	for _, spec in ipairs(checkboxes) do
		local check = mini:Checkbox({
			Parent = appearancePanel,
			LabelText = spec.Label,
			Tooltip = spec.Tooltip,
			GetValue = function()
				local group = ui.Current()
				return group ~= nil and spec.Get(group) == true
			end,
			SetValue = function(value)
				local group = ui.Current()

				if group then
					spec.Set(group, value)
					ui.Apply()
				end
			end,
		})
		check:SetPoint("TOPLEFT", checkRow, "TOPLEFT", checkColumn * spec.Column, 0)
	end

	local swatch = mini:ColorSwatch({
		Parent = appearancePanel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border."],
		HasOpacity = false,
		GetValue = function()
			local group = ui.Current()
			local color = group and group.Icons.Color or {}
			return color.R or 1, color.G or 1, color.B or 1, color.A or 1
		end,
		SetValue = function(r, g, b, a)
			local group = ui.Current()

			if group then
				local color = group.Icons.Color
				color.R, color.G, color.B, color.A = r, g, b, a
				ui.Apply()
			end
		end,
	})
	-- Centred: the swatch is shorter than a checkbox and would otherwise sit high.
	swatch:SetPoint("TOPLEFT", checkRow2, "TOPLEFT", 0,
		-math.floor((CHECK_ROW_HEIGHT - swatch:GetHeight()) / 2))

	local pandemicSwatch = mini:ColorSwatch({
		Parent = appearancePanel,
		LabelText = L["Pandemic colour"],
		Tooltip = L["Change the colour of the pandemic ring."],
		HasOpacity = false,
		GetValue = function()
			local group = ui.Current()
			local color = group and group.Icons.PandemicColor or {}
			return color.R or 1, color.G or 0.6, color.B or 0.1, 1
		end,
		SetValue = function(r, g, b)
			local group = ui.Current()

			if group then
				local color = group.Icons.PandemicColor
				color.R, color.G, color.B = r, g, b
				ui.Apply()
			end
		end,
	})
	pandemicSwatch:SetPoint("TOPLEFT", checkRow2, "TOPLEFT", checkColumn,
		-math.floor((CHECK_ROW_HEIGHT - pandemicSwatch:GetHeight()) / 2))

	---@param label string
	---@param minimum number
	---@param maximum number
	---@param get fun(group: CustomAuraGroup): number
	---@param set fun(group: CustomAuraGroup, value: number)
	---@return table
	local function Slider(label, minimum, maximum, get, set)
		local slider = mini:Slider({
			Parent = appearancePanel,
			LabelText = label,
			Width = sliderWidth,
			Min = minimum,
			Max = maximum,
			Step = 1,
			GetValue = function()
				local group = ui.Current()
				return group and get(group) or minimum
			end,
			SetValue = function(value)
				local group = ui.Current()

				if not group then
					return
				end

				local clamped = mini:ClampInt(value, minimum, maximum, minimum)

				if get(group) ~= clamped then
					set(group, clamped)
					ui.Apply()
				end
			end,
		})

		return slider
	end

	local sizeSlider = Slider(L["Icon Size"], groups.MinIconSize, groups.MaxIconSize,
		function(group) return group.Icons.Size end,
		function(group, value) group.Icons.Size = value end)
	-- Offset by the headroom, or the slider's value box lands on the colour swatch.
	sizeSlider.Slider:SetPoint("TOPLEFT", sliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local spacingSlider = Slider(L["Icon Padding"], 0, 50,
		function(group) return group.Icons.Spacing end,
		function(group, value) group.Icons.Spacing = value end)
	spacingSlider.Slider:SetPoint("LEFT", sizeSlider.Slider, "RIGHT", SLIDER_GAP, 0)
end
