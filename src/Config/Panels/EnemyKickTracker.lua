---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local dbDefaults = addon.Config.Defaults
local moduleName = addon.Utils.ModuleName

local UNKNOWN_KICK_MODES = { "class", "generic" }
local UNKNOWN_KICK_MODE_TEXT = {
	class = L["Class crest"],
	generic = L["Generic kick icon"],
}

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

	local showNameChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show name"],
		Tooltip = L["Shows the name of the enemy who kicked, above their icon."],
		GetValue = function()
			return db.Modules.EnemyKickTracker.ShowName ~= false
		end,
		SetValue = function(value)
			db.Modules.EnemyKickTracker.ShowName = value
			config:Apply(moduleName.EnemyKickTracker)
		end,
	})

	showNameChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local showBorderChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show border"],
		Tooltip = L["Show a class coloured border around the kick icons."],
		GetValue = function()
			return db.Modules.EnemyKickTracker.Icons.Border ~= false
		end,
		SetValue = function(value)
			db.Modules.EnemyKickTracker.Icons.Border = value
			config:Apply(moduleName.EnemyKickTracker)
		end,
	})

	showBorderChk:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)
	showBorderChk:SetPoint("TOP", showNameChk, "TOP", 0, 0)

	local unknownKickDropdown = mini:Dropdown({
		Parent = panel,
		LabelText = L["Unknown kicks"],
		Tooltip = L["What to show for a kick that cannot be identified."],
		Items = UNKNOWN_KICK_MODES,
		GetText = function(value)
			return UNKNOWN_KICK_MODE_TEXT[value] or tostring(value)
		end,
		GetValue = function()
			return db.Modules.EnemyKickTracker.UnknownKickIcon or "class"
		end,
		SetValue = function(value)
			db.Modules.EnemyKickTracker.UnknownKickIcon = value
			config:Apply(moduleName.EnemyKickTracker)
		end,
		Width = sliderWidth,
	})

	unknownKickDropdown.Label:SetPoint("TOPLEFT", showNameChk, "BOTTOMLEFT", 4, -verticalSpacing)

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

	iconSizeSlider.Slider:SetPoint("TOPLEFT", unknownKickDropdown.Label, "BOTTOMLEFT", 0, -verticalSpacing * 4)

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

	local fontScaleSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Font Scale"],
		Tooltip = L["Scales this module's countdown text, leaving the icon size alone."],
		Min = 0.5,
		Max = 2.0,
		Step = 0.05,
		Default = dbDefaults.Modules.EnemyKickTracker.FontScale,
		Fallback = dbDefaults.Modules.EnemyKickTracker.FontScale,
		Float = true,
		Width = sliderWidth,
		Target = db.Modules.EnemyKickTracker,
		Key = "FontScale",
		SettingsKey = moduleName.EnemyKickTracker,
	})

	fontScaleSlider.Slider:SetPoint("TOPLEFT", iconSizeSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	M.Panel = panel
end
