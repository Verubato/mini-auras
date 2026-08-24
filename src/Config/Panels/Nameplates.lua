---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local dbDefaults = addon.Config.Defaults
local DROPDOWN_WIDTH = 200
local GROW_OPTIONS = {
	"LEFT",
	"RIGHT",
	"CENTER",
}
local nameplatesDisplay = addon.Modules.Nameplates.Display
local COLOR_MODE = nameplatesDisplay.ColorMode
local COLOR_MODES = {
	COLOR_MODE.None,
	COLOR_MODE.Dispel,
	COLOR_MODE.Custom,
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local moduleName = addon.Utils.ModuleName

---@class NameplatesConfig
local M = {}

config.Nameplates = M

local function ColorModeText(mode)
	if mode == COLOR_MODE.Dispel then
		return L["Dispel colours"]
	end

	if mode == COLOR_MODE.Custom then
		return L["Custom"]
	end

	return L["None"]
end

---@param parent table Tab content frame
---@param options NameplateSpellTypeOptions
---@param defaults table The shipped values for this bar, which the sliders clamp back to when
---the typed input is not a number.
local function BuildSpellTypeSettings(parent, options, defaults)
	local container = CreateFrame("Frame", nil, parent)

	container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	container:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

	local topColWidth = mini:ColumnWidth(5, 0, 0)
	local sliderWidth = columnWidth * 2 - horizontalSpacing

	local enabledChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Enabled"],
		GetValue = function()
			return options.Enabled
		end,
		SetValue = function(value)
			options.Enabled = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	enabledChk:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

	local showCrowdControlChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show CC"],
		Tooltip = L["Show crowd control spells in this bar."],
		GetValue = function()
			return options.ShowCrowdControl
		end,
		SetValue = function(value)
			options.ShowCrowdControl = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	showCrowdControlChk:SetPoint("LEFT", parent, "LEFT", topColWidth, 0)
	showCrowdControlChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local showDefChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show Defensives"],
		Tooltip = L["Show defensive spells in this bar."],
		GetValue = function()
			return options.ShowDefensives
		end,
		SetValue = function(value)
			options.ShowDefensives = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	showDefChk:SetPoint("LEFT", parent, "LEFT", topColWidth * 2, 0)
	showDefChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local showImportantChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show Important"],
		Tooltip = L["Show the important buffs Blizzard permits on nameplates (e.g. enemy offensive cooldowns)."],
		GetValue = function()
			return options.ShowImportant
		end,
		SetValue = function(value)
			options.ShowImportant = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	showImportantChk:SetPoint("LEFT", parent, "LEFT", topColWidth * 3, 0)
	showImportantChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local glowChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	glowChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local reverseChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	reverseChk:SetPoint("LEFT", parent, "LEFT", topColWidth, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return options.ShowTooltips ~= false
		end,
		SetValue = function(value)
			options.ShowTooltips = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	showTooltipsChk:SetPoint("LEFT", parent, "LEFT", topColWidth * 4, 0)
	showTooltipsChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local showMillisChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Milliseconds"],
		Tooltip = L["Show decimal milliseconds on the cooldown timer when below the configured threshold."],
		GetValue = function()
			return options.Icons.ShowMilliseconds == true
		end,
		SetValue = function(value)
			options.Icons.ShowMilliseconds = value
			config:Apply(moduleName.Nameplates)
		end,
	})

	showMillisChk:SetPoint("LEFT", parent, "LEFT", topColWidth * 2, 0)
	showMillisChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local iconSize = helpers:BuildClampedSlider({
		Parent = container,
		LabelText = L["Icon Size"],
		Tooltip = L["Width and height of each icon."],
		Min = 10,
		Max = 60,
		Default = defaults.Icons.Size,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Size",
		SettingsKey = moduleName.Nameplates,
	})

	local maxIcons = helpers:BuildClampedSlider({
		Parent = container,
		LabelText = L["Max Icons"],
		Tooltip = L["Applies to each aura category on its own, so a unit with both defensives and important buffs can show this many of each. The game no longer lets addons count auras, so a shared limit across categories is not possible."],
		Min = 1,
		Max = 8,
		Default = defaults.Icons.MaxIcons,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "MaxIcons",
		SettingsKey = moduleName.Nameplates,
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

	local growDdl = helpers:BuildGrowDropdown({
		Parent = container,
		Items = GROW_OPTIONS,
		Target = options,
		Key = "Grow",
		Width = DROPDOWN_WIDTH,
		SettingsKey = moduleName.Nameplates,
	})

	growDdl.Label:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing)

	-- One control for the whole colouring question, so there is nowhere else to look for it: the
	-- categories are either uncoloured, on the game's dispel palette, or on the picked tints. The
	-- three tints themselves live on the Settings tab, since a category should read the same
	-- colour on whichever bar it lands.
	local colorsDdl = helpers:BuildLabelledDropdown({
		Parent = container,
		LabelText = L["Icon colours"],
		Tooltip = L["Tints the glow and border with the colours on the Settings tab. Dispel colours instead give CC the game's debuff colours, e.g. blue for magic."],
		Items = COLOR_MODES,
		GetText = ColorModeText,
		Width = DROPDOWN_WIDTH,
		Target = options.Icons,
		Key = "ColorMode",
		SettingsKey = moduleName.Nameplates,
		GetValue = function()
			return nameplatesDisplay:ResolveColorMode(options.Icons)
		end,
	})

	colorsDdl.Label:SetPoint("LEFT", parent, "LEFT", topColWidth * 2, 0)
	colorsDdl.Label:SetPoint("TOP", growDdl.Label, "TOP", 0, 0)

	iconSize.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = container,
		LabelText = L["Icon Padding"],
		Tooltip = L["Space between icons."],
		Min = 0,
		Max = 20,
		Default = defaults.Icons.Spacing,
		Fallback = defaults.Icons.Spacing,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Spacing",
		SettingsKey = moduleName.Nameplates,
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local offsetX = helpers:BuildOffsetSliders({
		Parent = container,
		Offset = options.Offset,
		Width = sliderWidth,
		SettingsKey = moduleName.Nameplates,
	})

	offsetX.Slider:SetPoint("TOPLEFT", iconSpacing.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)
end

---@param parent table
---@param options NameplateModuleOptions
local function BuildSettingsTab(parent, options)
	-- Shared 5-column checkbox grid so checkbox rows align across pages. These labels are
	-- long in several locales (ruRU "Ignore Enemy Pets" needs ~220px), so the checkboxes
	-- sit two grid columns apart in a 2x2 block instead of one per column.
	local checkColumnWidth = mini:ColumnWidth(5, 0, 0)

	local enemyIgnorePetsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Ignore Enemy Pets"],
		Tooltip = L["Do not show auras on enemy pet nameplates."],
		GetValue = function()
			return options.Enemy.IgnorePets
		end,
		SetValue = function(value)
			options.Enemy.IgnorePets = value
			config:Apply(moduleName.Nameplates)
		end,
	})
	enemyIgnorePetsChk:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local friendlyIgnorePetsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Ignore Friendly Pets"],
		Tooltip = L["Do not show auras on friendly pet nameplates."],
		GetValue = function()
			return options.Friendly.IgnorePets
		end,
		SetValue = function(value)
			options.Friendly.IgnorePets = value
			config:Apply(moduleName.Nameplates)
		end,
	})
	friendlyIgnorePetsChk:SetPoint("TOP", enemyIgnorePetsChk, "TOP", 0, 0)
	friendlyIgnorePetsChk:SetPoint("LEFT", parent, "LEFT", checkColumnWidth * 2, 0)

	local scaleWithNameplateChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Scale with Nameplate"],
		Tooltip = L["Icons scale along with the nameplate scale. Use this option if you have a different size for the target nameplate (e.g. in BBF's settings)."],
		GetValue = function()
			return options.ScaleWithNameplate
		end,
		SetValue = function(value)
			options.ScaleWithNameplate = value
			config:Apply(moduleName.Nameplates)
		end,
	})
	scaleWithNameplateChk:SetPoint("TOPLEFT", enemyIgnorePetsChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local anchorToHealthBarChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Anchor to Health Bar"],
		Tooltip = L["Anchor the icons to the nameplate's health bar instead of the nameplate frame. Use this option if another addon (e.g. BetterBlizzPlates) changes the nameplate width or height."],
		GetValue = function()
			return options.AnchorToHealthBar
		end,
		SetValue = function(value)
			options.AnchorToHealthBar = value
			config:Apply(moduleName.Nameplates)
		end,
	})
	anchorToHealthBarChk:SetPoint("TOP", scaleWithNameplateChk, "TOP", 0, 0)
	anchorToHealthBarChk:SetPoint("LEFT", parent, "LEFT", checkColumnWidth * 2, 0)

	-- The category tints, on a row of their own below the checkbox pairs. Module wide rather than
	-- per bar: a category should read the same colour wherever it lands, and the bar tabs only
	-- choose between these and the game's dispel palette.
	---@param swatch table
	---@param column number Grid column the swatch starts at.
	local function PlaceSwatch(swatch, column)
		swatch:SetPoint("LEFT", parent, "LEFT", checkColumnWidth * column, 0)
		swatch:SetPoint("TOP", scaleWithNameplateChk, "BOTTOM", 0, -verticalSpacing)
	end

	local ccSwatch = mini:ColorSwatch({
		Parent = parent,
		LabelText = L["CC"],
		Tooltip = L["Change the colour of the glow on crowd control spells."],
		HasOpacity = false,
		GetValue = function()
			local color = options.CrowdControlColor
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = options.CrowdControlColor
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply(moduleName.Nameplates)
		end,
	})

	PlaceSwatch(ccSwatch, 0)

	local defensiveSwatch = mini:ColorSwatch({
		Parent = parent,
		LabelText = L["Defensive"],
		Tooltip = L["Change the colour of the glow on defensive spells."],
		HasOpacity = false,
		GetValue = function()
			local color = options.DefensiveColor
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = options.DefensiveColor
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply(moduleName.Nameplates)
		end,
	})

	PlaceSwatch(defensiveSwatch, 1)

	local importantSwatch = mini:ColorSwatch({
		Parent = parent,
		LabelText = L["Important"],
		Tooltip = L["Change the colour of the glow on important spells."],
		HasOpacity = false,
		GetValue = function()
			local color = options.ImportantColor
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = options.ImportantColor
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply(moduleName.Nameplates)
		end,
	})

	PlaceSwatch(importantSwatch, 2)
end

---@param parent table
---@param options NameplateModuleOptions
function M:Build(parent, options)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Shows CC, defensive, and important spells on nameplates (works with nameplate addons e.g. BBP, Platynator, and Plater)."],
		},
	})

	lines:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = parent,
		Text = L["Enable in"],
	})
	enabledDivider:SetPoint("LEFT", parent, "LEFT")
	enabledDivider:SetPoint("RIGHT", parent, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = helpers:BuildEnableRow(parent, enabledDivider,
		db.Modules.Nameplates.Enabled, nil, moduleName.Nameplates)

	local subPanelHeight = 285

	local tabContainer = CreateFrame("Frame", nil, parent)
	tabContainer:SetPoint("TOPLEFT",  enabledEverywhere, "BOTTOMLEFT", 0, -verticalSpacing)
	tabContainer:SetPoint("TOPRIGHT", parent,            "TOPRIGHT",   0, 0)
	tabContainer:SetHeight(subPanelHeight + 34)

	local tabCtrl = mini:CreateTabs({
		Parent = tabContainer,
		TabHeight = 28,
		StripHeight = 34,
		TabFitToParent = true,
		ContentInsets = { Top = verticalSpacing },
		Tabs = {
			{ Key = "settings",      Title = L["Settings"] },
			{ Key = "enemyBar1",     Title = L["Enemy - Bar 1"] },
			{ Key = "enemyBar2",     Title = L["Enemy - Bar 2"] },
			{ Key = "friendlyBar1",  Title = L["Friendly - Bar 1"] },
			{ Key = "friendlyBar2",  Title = L["Friendly - Bar 2"] },
		},
	})

	local plateDefaults = dbDefaults.Modules.Nameplates

	BuildSettingsTab(tabCtrl:GetContent("settings"), options)
	BuildSpellTypeSettings(tabCtrl:GetContent("enemyBar1"),     options.Enemy.Bar1, plateDefaults.Enemy.Bar1)
	BuildSpellTypeSettings(tabCtrl:GetContent("enemyBar2"),     options.Enemy.Bar2, plateDefaults.Enemy.Bar2)
	BuildSpellTypeSettings(tabCtrl:GetContent("friendlyBar1"),  options.Friendly.Bar1, plateDefaults.Friendly.Bar1)
	BuildSpellTypeSettings(tabCtrl:GetContent("friendlyBar2"),  options.Friendly.Bar2, plateDefaults.Friendly.Bar2)
end
