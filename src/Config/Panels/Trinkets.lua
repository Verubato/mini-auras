---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config
local helpers = addon.Config.PanelHelpers

---@class TrinketsConfig
local M = {}

config.Trinkets = M

function M:Build(panel)
	local db = mini:GetSavedVars()
	local columns = 3
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	local enabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Enabled"],
		Tooltip = L["Whether to enable or disable this module."],
		GetValue = function()
			return db.Modules.TrinketsModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.TrinketsModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabled:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local excludePlayerChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Exclude self"],
		Tooltip = L["Exclude yourself from showing trinket icons."],
		GetValue = function()
			return db.Modules.TrinketsModule.ExcludePlayer
		end,
		SetValue = function(value)
			db.Modules.TrinketsModule.ExcludePlayer = value
			config:Apply()
		end,
	})

	excludePlayerChk:SetPoint("TOP", enabled, "TOP", 0, 0)
	excludePlayerChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)

	local colorSwatch = mini:ColorSwatch({
		Parent = panel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border."],
		HasOpacity = false,
		GetValue = function()
			local color = db.Modules.TrinketsModule.Icons.Color
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = db.Modules.TrinketsModule.Icons.Color
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply()
		end,
	})

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabled, "BOTTOM", 0, -verticalSpacing)

	local borderChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show border"],
		Tooltip = L["Draw a border around the icons."],
		GetValue = function()
			return db.Modules.TrinketsModule.Icons.Border
		end,
		SetValue = function(value)
			db.Modules.TrinketsModule.Icons.Border = value
			config:Apply()
		end,
	})

	borderChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	-- Beside the border toggle it feeds, in Settings rather than up in the enable row.
	-- Centred on the row: the swatch is shorter than a checkbox, so sharing its TOP edge
	-- leaves it sitting low against the labels.
	colorSwatch:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	colorSwatch:SetPoint("TOP", borderChk, "TOP", 0,
		-math.floor((borderChk:GetHeight() - colorSwatch:GetHeight()) / 2))

	local iconSizeSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Icon Size"],
		Min = 10,
		Max = 100,
		Default = 40,
		Width = columns * columnWidth - horizontalSpacing,
		Target = db.Modules.TrinketsModule.Icons,
		Key = "Size",
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", borderChk, "BOTTOMLEFT", 4, -verticalSpacing * 2)

	local offsetXSlider = helpers:BuildOffsetSliders({
		Parent = panel,
		Offset = db.Modules.TrinketsModule.Offset,
		Width = (columns / 2) * columnWidth - horizontalSpacing,
		Range = 200,
	})

	offsetXSlider.Slider:SetPoint("TOPLEFT", iconSizeSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Limitations:"],
			L[" - Doesn't work if your team mates trinket in the starting room."],
			L[" - Only works inside arena."],
		},
	})

	lines:SetPoint("TOPLEFT", offsetXSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	M.Panel = panel
end
