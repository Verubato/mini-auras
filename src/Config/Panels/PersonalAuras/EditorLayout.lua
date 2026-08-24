---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local groups = addon.Modules.PersonalAuras.Groups
local display = addon.Modules.PersonalAuras.Display
local ui = addon.Config.PersonalAurasUI
-- Clearance a slider needs above itself for the value box and its label.
local SLIDER_HEADROOM = 34
local SLIDER_ROW_HEIGHT = SLIDER_HEADROOM + 34
-- The last slider row keeps the headroom its value boxes need but not the padding below, which
-- only exists to hold the next row off. Losing that padding and the row gap is what stopped the
-- tab needing a scrollbar.
local LAST_SLIDER_ROW_HEIGHT = SLIDER_HEADROOM + 20
-- Safe because that headroom is most of the space between two stacked slider bars.
local LAST_SLIDER_ROW_GAP = 0
local SLIDER_GAP = 45
local SORT_OPTIONS = { "OLDEST", "LONGEST", "SHORTEST" }
local GROW_OPTIONS = { "LEFT", "RIGHT", "CENTER", "DOWN", "UP" }
-- A number this short does not need a dropdown's column, but the label does: "Desplazamiento X"
-- is the longest translation and needs about 110px.
local OFFSET_COLUMN = 120
-- Tighter than ui.DropdownColumn: the settings row holds three dropdowns and both offset boxes,
-- and stock columns would push the last offset label past the panel edge.
local SETTINGS_COLUMN = 190
local OFFSET_BOX_WIDTH = 70
-- Wider than any sane screen, so typing is never the thing that stops a group being placed.
local OFFSET_LIMIT = 2000

---Builds the layout tab: where a group sits, which way it grows and how big it is.
---Returns a refresh function: the size controls differ per shape, since a bar's height and width
---are its own settings with their own ranges.
---@param ctx PersonalAurasEditorContext
---@return fun(group: PersonalAuraGroup) refreshShape
function ui.BuildLayoutTab(ctx)
	local layoutPanel = ctx.LayoutPanel
	-- Two sliders across the row rather than three, so each spans two dropdown columns and the
	-- pair fills the width instead of leaving a third of it empty.
	local sliderWidth = ui.DropdownColumn * 2 - SLIDER_GAP / 2

	local settingsControlsRow = ctx.NewRow(layoutPanel, ui.DropdownRowHeight)
	local sliderRow = ctx.NewRow(layoutPanel, SLIDER_ROW_HEIGHT)
	-- Text scale plus, for a group drawing bars, the width an icon group has no use for.
	local secondSliderRow = ctx.NewRow(layoutPanel, LAST_SLIDER_ROW_HEIGHT, LAST_SLIDER_ROW_GAP)

	local orderDropdown = ctx.Dropdown(L["Order"], {
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
	}, settingsControlsRow, SETTINGS_COLUMN * 2)

	local growDropdown = ctx.Dropdown(L["Grow"], {
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

	-- Which layer the group draws in, for the ones that have to sit over or under something the
	-- game or another addon put there. Automatic follows whatever the group hangs off.
	local strataDropdown = ctx.Dropdown(L["Strata"], {
		Items = groups.StrataOptions,
		GetText = function(value)
			return value == groups.StrataAuto and L["Automatic"] or value
		end,
		GetValue = function()
			local group = ui.Current()
			return group and group.Strata or groups.StrataAuto
		end,
		SetValue = function(value)
			local group = ui.Current()

			if group then
				group.Strata = value
				ui.Apply()
			end
		end,
	}, settingsControlsRow, SETTINGS_COLUMN)

	---The pair a drag writes: a screen group keeps a screen position, every other anchor keeps an
	---offset from the frame it hangs off.
	---@param group PersonalAuraGroup
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
			Parent = layoutPanel,
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

	local offsetXBox = OffsetBox(L["Offset X"], "X", SETTINGS_COLUMN * 3)
	local offsetYBox = OffsetBox(L["Offset Y"], "Y", SETTINGS_COLUMN * 3 + OFFSET_COLUMN)

	-- A drag writes the same fields these boxes edit, so they catch up the moment it ends.
	display:OnPositionChanged(function(groupId)
		local group = ui.Current()

		if group and group.Id == groupId then
			offsetXBox.EditBox:MiniRefresh()
			offsetYBox.EditBox:MiniRefresh()
		end
	end)

	---@param label string
	---@param tooltip string
	---@param minimum number
	---@param maximum number
	---@param get fun(group: PersonalAuraGroup): number
	---@param set fun(group: PersonalAuraGroup, value: number)
	---@return table
	local function Slider(label, tooltip, minimum, maximum, get, set)
		local slider = mini:Slider({
			Parent = layoutPanel,
			LabelText = label,
			Tooltip = tooltip,
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

	---@param slider table
	---@param shown boolean
	local function SetSliderShown(slider, shown)
		slider.Slider:SetShown(shown)
		slider.EditBox:SetShown(shown)
		slider.Label:SetShown(shown)
	end

	-- The icon size and the bar height share a slot but not a setting: they measure different
	-- things and clamp to different ranges, so they are two sliders and only one is ever up.
	local sizeSlider = Slider(L["Icon Size"], L["Width and height of each icon."],
		groups.MinIconSize, groups.MaxIconSize,
		function(group) return group.Icons.Size end,
		function(group, value) group.Icons.Size = value end)
	-- Offset by the headroom, or the slider's value box lands on the row above.
	sizeSlider.Slider:SetPoint("TOPLEFT", sliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local heightSlider = Slider(L["Bar Height"], L["Height of each bar."],
		groups.MinBarHeight, groups.MaxBarHeight,
		function(group) return group.Icons.BarHeight end,
		function(group, value) group.Icons.BarHeight = value end)
	heightSlider.Slider:SetPoint("TOPLEFT", sliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local spacingSlider = Slider(L["Icon Padding"], L["Space between icons."], 0, 50,
		function(group) return group.Icons.Spacing end,
		function(group, value) group.Icons.Spacing = value end)
	spacingSlider.Slider:SetPoint("LEFT", sizeSlider.Slider, "RIGHT", SLIDER_GAP, 0)

	-- A percentage of the size the text would take anyway, since every text on an icon or a bar is
	-- measured off that shape rather than set in points.
	local textScaleSlider = Slider(L["Text Size (%)"],
		L["Scales this group's countdown, stack count, and bar name text, on top of the global font scale."],
		groups.MinTextScale, groups.MaxTextScale,
		function(group) return group.Icons.TextScale end,
		function(group, value) group.Icons.TextScale = value end)
	textScaleSlider.Slider:SetPoint("TOPLEFT", secondSliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local widthSlider = Slider(L["Bar Width"], L["Width of each bar."],
		groups.MinBarWidth, groups.MaxBarWidth,
		function(group) return group.Icons.BarWidth end,
		function(group, value) group.Icons.BarWidth = value end)
	widthSlider.Slider:SetPoint("LEFT", textScaleSlider.Slider, "RIGHT", SLIDER_GAP, 0)

	-- Art keeps its own pair of sides: it is decoration hung beside a unit rather than a square in
	-- a row, so neither the icon size nor the bar's ranges fit it.
	local textureWidthSlider = Slider(L["Texture Width"], L["Width of the texture."],
		groups.MinTextureSize, groups.MaxTextureSize,
		function(group) return group.Texture.Width end,
		function(group, value) group.Texture.Width = value end)
	textureWidthSlider.Slider:SetPoint("TOPLEFT", sliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local textureHeightSlider = Slider(L["Texture Height"], L["Height of the texture."],
		groups.MinTextureSize, groups.MaxTextureSize,
		function(group) return group.Texture.Height end,
		function(group, value) group.Texture.Height = value end)
	textureHeightSlider.Slider:SetPoint("LEFT", textureWidthSlider.Slider, "RIGHT", SLIDER_GAP, 0)

	local rotationSlider = Slider(L["Rotation"], L["Turn the texture clockwise, in degrees."],
		0, groups.MaxRotation,
		function(group) return group.Texture.Rotation end,
		function(group, value) group.Texture.Rotation = value end)
	rotationSlider.Slider:SetPoint("TOPLEFT", secondSliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local opacitySlider = Slider(L["Opacity (%)"], L["How solid the texture is."], 0, 100,
		function(group) return group.Texture.Opacity end,
		function(group, value) group.Texture.Opacity = value end)
	opacitySlider.Slider:SetPoint("LEFT", rotationSlider.Slider, "RIGHT", SLIDER_GAP, 0)

	---Moves a control's label along the settings row, which moves the control with it: both the
	---dropdowns and the offset boxes hang off their own caption.
	---@param label table
	---@param x number
	local function PlaceLabel(label, x)
		label:ClearAllPoints()
		label:SetPoint("TOPLEFT", settingsControlsRow, "TOPLEFT", x, 0)
	end

	---@param group PersonalAuraGroup
	local function RefreshShape(group)
		local bars = groups:DrawsBars(group)
		-- One picture, so there is no order to sort it into and no direction for it to grow in.
		local texture = groups:DrawsTexture(group)
		local icons = not bars and not texture

		SetSliderShown(sizeSlider, icons)
		SetSliderShown(heightSlider, bars)
		SetSliderShown(widthSlider, bars)
		SetSliderShown(spacingSlider, not texture)
		SetSliderShown(textScaleSlider, not texture)
		SetSliderShown(textureWidthSlider, texture)
		SetSliderShown(textureHeightSlider, texture)
		SetSliderShown(rotationSlider, texture)
		SetSliderShown(opacitySlider, texture)

		local ordered = not texture

		orderDropdown:SetShown(ordered)
		orderDropdown.MiniLabel:SetShown(ordered)
		growDropdown:SetShown(ordered)
		growDropdown.MiniLabel:SetShown(ordered)

		-- The row closes up rather than leaving holes where the order and grow dropdowns were.
		PlaceLabel(strataDropdown.MiniLabel, texture and 0 or SETTINGS_COLUMN)
		PlaceLabel(offsetXBox.Label, texture and SETTINGS_COLUMN or SETTINGS_COLUMN * 3)
		PlaceLabel(offsetYBox.Label, (texture and SETTINGS_COLUMN or SETTINGS_COLUMN * 3)
			+ OFFSET_COLUMN)

		ctx.UpdateEditorHeight()
	end

	return RefreshShape
end
