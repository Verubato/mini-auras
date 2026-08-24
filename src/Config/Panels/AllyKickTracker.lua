---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local barTextures = addon.Core.BarTextures
local dbDefaults = addon.Config.Defaults
local moduleName = addon.Utils.ModuleName
local GROW_OPTIONS = { "DOWN", "UP" }

---@class AllyKickTrackerConfig
local M = {}

config.AllyKickTracker = M

---@param panel table
---@param options AllyKickTrackerModuleOptions
function M:Build(panel, options)
	-- Shared 5-column checkbox grid so checkbox rows line up with the other pages.
	local columnWidth = mini:ColumnWidth(5, 0, 0)
	local sliderWidth = mini:ColumnWidth(4, 0, 0) * 2 - horizontalSpacing

	local description = mini:TextLine({
		Parent = panel,
		Text = L["Shows a history of recent interrupts, newest first. Blizzard hides who kicked inside Mythic+, so their cooldown cannot be read. Every row simply lasts 15 seconds instead."],
	})

	description:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", description, "BOTTOM", 0, -verticalSpacing)

	local enabledWorld = helpers:BuildEnableRow(panel, enabledDivider, options.Enabled, nil,
		moduleName.AllyKickTracker)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledWorld, "BOTTOM", 0, -verticalSpacing)

	local lockedChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Lock position"],
		Tooltip = L["Stop the bars from being dragged, and let the mouse through them."],
		GetValue = function()
			return options.Locked
		end,
		SetValue = function(value)
			options.Locked = value
			config:Apply(moduleName.AllyKickTracker)
		end,
	})

	lockedChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local ownChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show self"],
		Tooltip = L["Keep a bar at the top for your own interrupt, counting down to when it is ready."],
		GetValue = function()
			return options.ShowOwnCooldown
		end,
		SetValue = function(value)
			options.ShowOwnCooldown = value
			config:Apply(moduleName.AllyKickTracker)
		end,
	})

	ownChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	ownChk:SetPoint("TOP", lockedChk, "TOP", 0, 0)

	local growDropdown = helpers:BuildGrowDropdown({
		Parent = panel,
		Items = GROW_OPTIONS,
		GetValue = function()
			return options.Grow == "UP" and "UP" or "DOWN"
		end,
		Target = options,
		Key = "Grow",
		SettingsKey = moduleName.AllyKickTracker,
	})

	growDropdown.Label:SetPoint("TOPLEFT", lockedChk, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local textureLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	textureLabel:SetText(L["Bar Texture"])
	textureLabel:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	textureLabel:SetPoint("TOP", growDropdown.Label, "TOP", 0, 0)

	local textureDropdown, isModernDropdown = helpers:BuildMediaDropdown({
		Parent = panel,
		RefreshOn = panel,
		Media = barTextures,
		-- Two columns: texture names are long and the row has nothing to its right.
		Width = columnWidth * 2,
		GetValue = function()
			return options.Bars.Texture or barTextures:GetDefaultName()
		end,
		SetValue = function(value)
			if options.Bars.Texture ~= value then
				options.Bars.Texture = value
				config:Apply(moduleName.AllyKickTracker)
			end
		end,
		-- Each row carries a strip of the texture it names, so the list previews itself.
		GetText = function(value)
			return barTextures:GetLabel(value)
		end,
	})

	textureDropdown:SetPoint("LEFT", panel, "LEFT", columnWidth + (isModernDropdown and 0 or -16), 0)
	textureDropdown:SetPoint("TOP", growDropdown, "TOP", 0, 0)

	local widthSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Bar Width"],
		Tooltip = L["Width of each bar."],
		Min = 60,
		Max = 400,
		Default = dbDefaults.Modules.AllyKickTracker.Bars.Width,
		Fallback = dbDefaults.Modules.AllyKickTracker.Bars.Width,
		Width = sliderWidth,
		Target = options.Bars,
		Key = "Width",
		SettingsKey = moduleName.AllyKickTracker,
	})
	widthSlider.Slider:SetPoint("TOPLEFT", growDropdown, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local heightSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Bar Height"],
		Tooltip = L["Height of each bar."],
		Min = 8,
		Max = 60,
		Default = dbDefaults.Modules.AllyKickTracker.Bars.Height,
		Fallback = dbDefaults.Modules.AllyKickTracker.Bars.Height,
		Width = sliderWidth,
		Target = options.Bars,
		Key = "Height",
		SettingsKey = moduleName.AllyKickTracker,
	})
	heightSlider.Slider:SetPoint("LEFT", widthSlider.Slider, "RIGHT", horizontalSpacing, 0)
	heightSlider.Slider:SetPoint("TOP", widthSlider.Slider, "TOP", 0, 0)

	local spacingSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Bar Padding"],
		Tooltip = L["Space between bars."],
		Min = 0,
		Max = 20,
		Default = dbDefaults.Modules.AllyKickTracker.BarSpacing,
		Fallback = dbDefaults.Modules.AllyKickTracker.BarSpacing,
		Width = sliderWidth,
		Target = options,
		Key = "BarSpacing",
		SettingsKey = moduleName.AllyKickTracker,
	})
	spacingSlider.Slider:SetPoint("TOPLEFT", widthSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxBarsSlider = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Max Bars"],
		Tooltip = L["Most bars shown at once. Anything past the limit is not drawn."],
		Min = 1,
		Max = 10,
		Default = dbDefaults.Modules.AllyKickTracker.MaxBars,
		Fallback = dbDefaults.Modules.AllyKickTracker.MaxBars,
		Width = sliderWidth,
		Target = options,
		Key = "MaxBars",
		SettingsKey = moduleName.AllyKickTracker,
	})
	maxBarsSlider.Slider:SetPoint("LEFT", spacingSlider.Slider, "RIGHT", horizontalSpacing, 0)
	maxBarsSlider.Slider:SetPoint("TOP", spacingSlider.Slider, "TOP", 0, 0)

	M.Panel = panel
end
