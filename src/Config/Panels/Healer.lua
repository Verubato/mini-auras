---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local sounds = addon.Core.Sounds
local dbDefaults = addon.Config.Defaults
local moduleName = addon.Utils.ModuleName

---@class HealerCrowdControlConfig
local M = {}

config.Healer = M

---@param panel table
---@param options HealerCrowdControlModuleOptions
function M:Build(panel, options)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	-- Shared 5-column checkbox grid: the Enable-in row and settings checkbox rows all sit on
	-- the same vertical lines.
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()
	local UpdateWarningColorSwatch

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["A separate region for when your healer is CC'd."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = helpers:BuildEnableRow(panel, enabledDivider, db.Modules.HealerCrowdControl.Enabled,
		nil, moduleName.HealerCrowdControl)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing)

	local showIconsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show icons"],
		Tooltip = L["Show CC icons when healer is CC'd."],
		GetValue = function()
			return options.Icons.Enabled
		end,
		SetValue = function(value)
			options.Icons.Enabled = value
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	showIconsChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local glowChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the CC icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	glowChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth, 0)
	glowChk:SetPoint("TOP", showIconsChk, "TOP", 0, 0)

	local showTextChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show warning text"],
		Tooltip = L["Show the 'Healer in CC!' text above the icons."],
		GetValue = function()
			return options.ShowWarningText
		end,
		SetValue = function(value)
			options.ShowWarningText = value
			UpdateWarningColorSwatch()
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	showTextChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 2, 0)
	showTextChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	reverseChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 3, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local dispelColoursChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Dispel colours"],
		Tooltip = L["Change the colour of the glow/border based on the type of debuff."],
		GetValue = function()
			return options.Icons.ColorByDispelType
		end,
		SetValue = function(value)
			options.Icons.ColorByDispelType = value
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	dispelColoursChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 4, 0)
	dispelColoursChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return options.ShowTooltips ~= false
		end,
		SetValue = function(value)
			options.ShowTooltips = value
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	showTooltipsChk:SetPoint("TOPLEFT", showIconsChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local warningColorSwatch = mini:ColorSwatch({
		Parent = panel,
		LabelText = L["Text colour"],
		Tooltip = L["Change the colour of the 'Healer in CC!' warning text."],
		HasOpacity = false,
		GetValue = function()
			local color = options.WarningTextColor
			return color.R, color.G, color.B, 1
		end,
		SetValue = function(r, g, b)
			local color = options.WarningTextColor
			color.R, color.G, color.B = r, g, b
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	warningColorSwatch:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth, 0)
	warningColorSwatch:SetPoint("TOP", showTooltipsChk, "TOP", 0,
		-math.floor((showTooltipsChk:GetHeight() - warningColorSwatch:GetHeight()) / 2))

	-- With the warning text switched off there is nothing for the swatch to colour, so it goes
	-- away rather than sitting there doing nothing.
	function UpdateWarningColorSwatch()
		local shown = options.ShowWarningText == true

		warningColorSwatch:SetShown(shown)
		warningColorSwatch.Label:SetShown(shown)
	end

	UpdateWarningColorSwatch()

	panel.OnMiniRefresh = UpdateWarningColorSwatch

	-- On 12.1 the sound plays engine-side via C_UnitAuras.AddAuraSound (registered per healer
	-- and per known CC spell in the module), so the option works on both paths.
	local soundChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Sound"],
		Tooltip = L["Play a sound when the healer is CC'd."],
		GetValue = function()
			return options.Sound.Enabled
		end,
		SetValue = function(value)
			options.Sound.Enabled = value
			if value then
				PlaySoundFile(sounds:Resolve(options.Sound.File), options.Sound.Channel or "Master")
			end
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	soundChk:SetPoint("TOPLEFT", showTooltipsChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local soundFileDropdown, soundFileModernDdl = helpers:BuildMediaDropdown({
		Parent = panel,
		RefreshOn = panel,
		Media = sounds,
		Width = 200,
		GetValue = function()
			return sounds:Normalise(options.Sound.File)
		end,
		SetValue = function(value)
			options.Sound.File = value
			PlaySoundFile(sounds:Resolve(value), options.Sound.Channel or "Master")
			config:Apply(moduleName.HealerCrowdControl)
		end,
	})

	-- Lined up with the checkbox column above it rather than the 4-column grid, and pulled left
	-- on the legacy dropdown, whose frame carries a wide inset before its text starts.
	soundFileDropdown:SetPoint("LEFT", panel, "LEFT",
		enabledColumnWidth + (soundFileModernDdl and 0 or -16), 0)
	soundFileDropdown:SetPoint("TOP", soundChk, "TOP", 0, -4)

	local slidersAnchor = soundChk

	local sliderWidth = (columnWidth * 2) - horizontalSpacing

	local iconSize = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Icon Size"],
		Tooltip = L["Width and height of each icon."],
		Min = 10,
		Max = 100,
		Default = dbDefaults.Modules.HealerCrowdControl.Icons.Size,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Size",
		SettingsKey = moduleName.HealerCrowdControl,
	})

	iconSize.Slider:SetPoint("TOPLEFT", slidersAnchor, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local maxIcons = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Max Icons"],
		Tooltip = L["Most icons shown at once on each unit."],
		Min = 1,
		Max = 5,
		Default = dbDefaults.Modules.HealerCrowdControl.Icons.MaxIcons,
		Fallback = dbDefaults.Modules.HealerCrowdControl.Icons.MaxIcons,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "MaxIcons",
		SettingsKey = moduleName.HealerCrowdControl,
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)
	maxIcons.Slider:SetPoint("TOP", iconSize.Slider, "TOP", 0, 0)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Icon Padding"],
		Tooltip = L["Space between icons."],
		Min = 0,
		Max = 20,
		Default = dbDefaults.Modules.HealerCrowdControl.IconSpacing,
		Fallback = dbDefaults.Modules.HealerCrowdControl.IconSpacing,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
		SettingsKey = moduleName.HealerCrowdControl,
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local fontSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 100,
		Width = sliderWidth,
		Step = 1,
		LabelText = L["Text Size"],
		Tooltip = L["Size of the warning text."],
		GetValue = function()
			return options.Font.Size
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 10, 100, 32)
			if options.Font.Size ~= newValue then
				options.Font.Size = newValue
				config:Apply(moduleName.HealerCrowdControl)
			end
		end,
	})

	fontSize.Slider:SetPoint("LEFT", iconSpacing.Slider, "RIGHT", horizontalSpacing, 0)
	fontSize.Slider:SetPoint("TOP", iconSpacing.Slider, "TOP", 0, 0)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end
