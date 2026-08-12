---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local groups = addon.Modules.CustomAuras.Groups
local display = addon.Modules.CustomAuras.Display
local ui = addon.Config.CustomAurasUI
-- Clearance a slider needs above itself for the value box and its label.
local SLIDER_HEADROOM = 34
local SLIDER_ROW_HEIGHT = SLIDER_HEADROOM + 34
local SLIDER_GAP = 45
-- The gap a row keeps when it is on screen, matching the editor's own default.
local ROW_GAP = 10
-- One line of text, which is all a sound-only group's layout tab holds.
local NOTE_ROW_HEIGHT = 26
local SORT_OPTIONS = { "OLDEST", "LONGEST", "SHORTEST" }
local GROW_OPTIONS = { "LEFT", "RIGHT", "CENTER", "DOWN", "UP" }
-- A number this short does not need a dropdown's column, but the label does: "Desplazamiento X"
-- is the longest translation and needs about 110px.
local OFFSET_COLUMN = 120
local OFFSET_BOX_WIDTH = 70
-- Wider than any sane screen, so typing is never the thing that stops a group being placed.
local OFFSET_LIMIT = 2000

---Builds the layout tab: where a group sits, which way it grows and how big it is.
---Returns a refresh function: the size controls differ per shape, since a bar's height and width
---are its own settings with their own ranges.
---@param ctx CustomAurasEditorContext
---@return fun(group: CustomAuraGroup) refreshShape
function ui.BuildLayoutTab(ctx)
	local layoutPanel = ctx.LayoutPanel
	-- Two sliders across the row rather than three, so each spans two dropdown columns and the
	-- pair fills the width instead of leaving a third of it empty.
	local sliderWidth = ui.DropdownColumn * 2 - SLIDER_GAP / 2

	local settingsControlsRow = ctx.NewRow(layoutPanel, ui.DropdownRowHeight)
	local sliderRow = ctx.NewRow(layoutPanel, SLIDER_ROW_HEIGHT)
	-- Put away for a group drawing icons, which has no width of its own.
	local barSliderRow = ctx.NewRow(layoutPanel, SLIDER_ROW_HEIGHT)

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
	}, settingsControlsRow, ui.DropdownColumn)

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

	-- Takes over the settings row when there is nothing to lay out, the way the appearance tab's
	-- note takes over its shape row.
	local emptyNote = layoutPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	emptyNote:SetText(L["Sound only auras don't have a position."])
	emptyNote:SetPoint("TOPLEFT", settingsControlsRow, "TOPLEFT", 0, 0)
	emptyNote:SetPoint("BOTTOMRIGHT", settingsControlsRow, "BOTTOMRIGHT", 0, 0)
	emptyNote:SetJustifyH("LEFT")
	emptyNote:SetJustifyV("TOP")

	---@param label string
	---@param minimum number
	---@param maximum number
	---@param get fun(group: CustomAuraGroup): number
	---@param set fun(group: CustomAuraGroup, value: number)
	---@return table
	local function Slider(label, minimum, maximum, get, set)
		local slider = mini:Slider({
			Parent = layoutPanel,
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

	---@param slider table
	---@param shown boolean
	local function SetSliderShown(slider, shown)
		slider.Slider:SetShown(shown)
		slider.EditBox:SetShown(shown)
		slider.Label:SetShown(shown)
	end

	-- The icon size and the bar height share a slot but not a setting: they measure different
	-- things and clamp to different ranges, so they are two sliders and only one is ever up.
	local sizeSlider = Slider(L["Icon Size"], groups.MinIconSize, groups.MaxIconSize,
		function(group) return group.Icons.Size end,
		function(group, value) group.Icons.Size = value end)
	-- Offset by the headroom, or the slider's value box lands on the row above.
	sizeSlider.Slider:SetPoint("TOPLEFT", sliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local heightSlider = Slider(L["Bar Height"], groups.MinBarHeight, groups.MaxBarHeight,
		function(group) return group.Icons.BarHeight end,
		function(group, value) group.Icons.BarHeight = value end)
	heightSlider.Slider:SetPoint("TOPLEFT", sliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	local spacingSlider = Slider(L["Icon Padding"], 0, 50,
		function(group) return group.Icons.Spacing end,
		function(group, value) group.Icons.Spacing = value end)
	spacingSlider.Slider:SetPoint("LEFT", sizeSlider.Slider, "RIGHT", SLIDER_GAP, 0)

	local widthSlider = Slider(L["Bar Width"], groups.MinBarWidth, groups.MaxBarWidth,
		function(group) return group.Icons.BarWidth end,
		function(group, value) group.Icons.BarWidth = value end)
	widthSlider.Slider:SetPoint("TOPLEFT", barSliderRow, "TOPLEFT", 4, -SLIDER_HEADROOM)

	---@param group CustomAuraGroup
	local function RefreshShape(group)
		local bars = groups:DrawsBars(group)
		-- Nothing is drawn for a sound-only group, so there is no size to set and nowhere to put
		-- it. The whole tab goes, the same way the appearance one does.
		local soundOnly = groups:IsSoundOnly(group)

		SetSliderShown(sizeSlider, not bars and not soundOnly)
		SetSliderShown(heightSlider, bars and not soundOnly)
		SetSliderShown(widthSlider, bars and not soundOnly)
		SetSliderShown(spacingSlider, not soundOnly)

		orderDropdown:SetShown(not soundOnly)
		orderDropdown.MiniLabel:SetShown(not soundOnly)
		growDropdown:SetShown(not soundOnly)
		growDropdown.MiniLabel:SetShown(not soundOnly)

		for _, box in ipairs({ offsetXBox, offsetYBox }) do
			box.EditBox:SetShown(not soundOnly)
			box.Label:SetShown(not soundOnly)
		end

		emptyNote:SetShown(soundOnly)
		settingsControlsRow:SetHeight(soundOnly and NOTE_ROW_HEIGHT or ui.DropdownRowHeight)

		-- Collapsed rather than left empty, and they hand their gaps back so the tab closes up.
		sliderRow:SetHeight(soundOnly and 1 or SLIDER_ROW_HEIGHT)
		ctx.SetRowGap(sliderRow, soundOnly and 0 or ROW_GAP)
		barSliderRow:SetHeight(bars and not soundOnly and SLIDER_ROW_HEIGHT or 1)
		ctx.SetRowGap(barSliderRow, bars and not soundOnly and ROW_GAP or 0)

		ctx.UpdateEditorHeight()
	end

	return RefreshShape
end
