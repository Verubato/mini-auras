---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local dbDefaults = addon.Config.Defaults
local moduleName = addon.Utils.ModuleName

---@class EnemyKickTrackerConfig
local M = {}

config.EnemyKickTracker = M

function M:Build(panel)
	local db = mini:GetSavedVars()
	-- Shared 5-column checkbox grid so checkbox rows align across pages.
	local checkColumnWidth = mini:ColumnWidth(5, 0, 0)
	local horizontalSpacing = mini.HorizontalSpacing
	-- Half-page sliders, same sizing as the other config screens.
	local sliderWidth = mini:ColumnWidth(4, 0, 0) * 2 - horizontalSpacing
	local description = mini:TextLine({
		Parent = panel,
		Text = L["Shows enemy kick cooldowns in arena."],
	})

	description:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	-- The existing localized "Enable if you are:" string, minus its trailing (fullwidth) colon.
	local enableDivider = mini:Divider({
		Parent = panel,
		Text = (L["Enable if you are:"]):gsub(":$", ""):gsub("：$", ""),
	})
	enableDivider:SetPoint("LEFT", panel, "LEFT")
	enableDivider:SetPoint("RIGHT", panel, "RIGHT")
	enableDivider:SetPoint("TOP", description, "BOTTOM", 0, -verticalSpacing)

	local healerEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Healer"],
		Tooltip = L["Whether to enable or disable this module if you are a healer."],
		GetValue = function()
			return db.Modules.EnemyKickTracker.Enabled.Healer
		end,
		SetValue = function(value)
			db.Modules.EnemyKickTracker.Enabled.Healer = value
			config:Apply(moduleName.EnemyKickTracker)
		end,
	})

	healerEnabled:SetPoint("TOPLEFT", enableDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local casterEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Caster"],
		Tooltip = L["Whether to enable or disable this module if you are a caster."],
		GetValue = function()
			return db.Modules.EnemyKickTracker.Enabled.Caster
		end,
		SetValue = function(value)
			db.Modules.EnemyKickTracker.Enabled.Caster = value
			config:Apply(moduleName.EnemyKickTracker)
		end,
	})

	casterEnabled:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)
	casterEnabled:SetPoint("TOP", healerEnabled, "TOP", 0, 0)

	local allEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Any"],
		Tooltip = L["Whether to enable or disable this module regardless of what spec you are."],
		GetValue = function()
			return db.Modules.EnemyKickTracker.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.EnemyKickTracker.Enabled.Always = value
			config:Apply(moduleName.EnemyKickTracker)
		end,
	})

	allEnabled:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
	allEnabled:SetPoint("TOP", healerEnabled, "TOP", 0, 0)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", healerEnabled, "BOTTOM", 0, -verticalSpacing)

	local borderChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show border"],
		Tooltip = L["Draw a border around the icons."],
		GetValue = function()
			return db.Modules.EnemyKickTracker.Icons.Border
		end,
		SetValue = function(value)
			db.Modules.EnemyKickTracker.Icons.Border = value
			config:Apply(moduleName.EnemyKickTracker)
		end,
	})

	borderChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local colorSwatch = mini:ColorSwatch({
		Parent = panel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border."],
		HasOpacity = false,
		GetValue = function()
			local color = db.Modules.EnemyKickTracker.Icons.Color
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = db.Modules.EnemyKickTracker.Icons.Color
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply(moduleName.EnemyKickTracker)
		end,
	})

	colorSwatch:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
	colorSwatch:SetPoint("TOP", borderChk, "TOP", 0,
		-math.floor((borderChk:GetHeight() - colorSwatch:GetHeight()) / 2))

	local iconSizeSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Icon Size"],
		Tooltip = L["Width and height of each icon."],
		Min = 20,
		Max = 120,
		Default = dbDefaults.Modules.EnemyKickTracker.Icons.Size,
		Width = sliderWidth,
		Target = db.Modules.EnemyKickTracker.Icons,
		Key = "Size",
		SettingsKey = moduleName.EnemyKickTracker,
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", borderChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local iconSpacingSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Icon Padding"],
		Tooltip = L["Space between icons."],
		Min = 0,
		Max = 20,
		Default = dbDefaults.Modules.EnemyKickTracker.IconSpacing,
		Fallback = dbDefaults.Modules.EnemyKickTracker.IconSpacing,
		Width = sliderWidth,
		Target = db.Modules.EnemyKickTracker,
		Key = "IconSpacing",
		SettingsKey = moduleName.EnemyKickTracker,
	})

	iconSpacingSlider.Slider:SetPoint("LEFT", iconSizeSlider.Slider, "RIGHT", horizontalSpacing, 0)
	iconSpacingSlider.Slider:SetPoint("TOP", iconSizeSlider.Slider, "TOP", 0, 0)

	M.Panel = panel
end
