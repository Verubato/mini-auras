---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config

---@class KickTimerConfig
local M = {}

config.KickTimer = M

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
			return db.Modules.KickTimerModule.Enabled.Healer
		end,
		SetValue = function(value)
			db.Modules.KickTimerModule.Enabled.Healer = value
			config:Apply()
		end,
	})

	healerEnabled:SetPoint("TOPLEFT", enableDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local casterEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Caster"],
		Tooltip = L["Whether to enable or disable this module if you are a caster."],
		GetValue = function()
			return db.Modules.KickTimerModule.Enabled.Caster
		end,
		SetValue = function(value)
			db.Modules.KickTimerModule.Enabled.Caster = value
			config:Apply()
		end,
	})

	casterEnabled:SetPoint("LEFT", panel, "LEFT", checkColumnWidth, 0)
	casterEnabled:SetPoint("TOP", healerEnabled, "TOP", 0, 0)

	local allEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Any"],
		Tooltip = L["Whether to enable or disable this module regardless of what spec you are."],
		GetValue = function()
			return db.Modules.KickTimerModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.KickTimerModule.Enabled.Always = value
			config:Apply()
		end,
	})

	allEnabled:SetPoint("LEFT", panel, "LEFT", checkColumnWidth * 2, 0)
	allEnabled:SetPoint("TOP", healerEnabled, "TOP", 0, 0)

	local iconSizeSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Icon Size"],
		GetValue = function()
			return db.Modules.KickTimerModule.Icons.Size
		end,
		SetValue = function(value)
			local newValue = mini:ClampInt(value, 20, 120, 50)
			if db.Modules.KickTimerModule.Icons.Size ~= newValue then
				db.Modules.KickTimerModule.Icons.Size = newValue
				config:Apply()
			end
		end,
		Width = sliderWidth,
		Min = 20,
		Max = 120,
		Step = 1,
	})

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", healerEnabled, "BOTTOM", 0, -verticalSpacing)

	iconSizeSlider.Slider:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 4, -verticalSpacing * 2)


	local iconSpacingSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Icon Padding"],
		GetValue = function()
			return db.Modules.KickTimerModule.IconSpacing or 2
		end,
		SetValue = function(value)
			local newValue = mini:ClampInt(value, 0, 20, 2)
			if db.Modules.KickTimerModule.IconSpacing ~= newValue then
				db.Modules.KickTimerModule.IconSpacing = newValue
				config:Apply()
			end
		end,
		Width = sliderWidth,
		Min = 0,
		Max = 20,
		Step = 1,
	})

	iconSpacingSlider.Slider:SetPoint("LEFT", iconSizeSlider.Slider, "RIGHT", horizontalSpacing, 0)
	iconSpacingSlider.Slider:SetPoint("TOP", iconSizeSlider.Slider, "TOP", 0, 0)

	local colorSwatch = mini:ColorSwatch({
		Parent = panel,
		LabelText = L["Colour"],
		Tooltip = L["Change the colour of the icon's glow and border."],
		HasOpacity = false,
		GetValue = function()
			local color = db.Modules.KickTimerModule.Icons.Color
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = db.Modules.KickTimerModule.Icons.Color
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply()
		end,
	})

	-- Its own row under the two sliders; sharing theirs put it behind the padding slider.
	colorSwatch:SetPoint("TOPLEFT", iconSizeSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	M.Panel = panel
end
