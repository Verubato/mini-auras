---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local DROPDOWN_WIDTH = 200
local GROW_OPTIONS = {
	"LEFT",
	"RIGHT",
	"CENTER",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers

---@class NameplatesConfig
local M = {}

config.Nameplates = M

---@param parent table Tab content frame
---@param options NameplateSpellTypeOptions
local function BuildSpellTypeSettings(parent, options)
	local container = CreateFrame("Frame", nil, parent)

	container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
	container:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

	local topColWidth = mini:ColumnWidth(5, 0, 0)
	local sliderWidth = columnWidth * 2 - horizontalSpacing

	-- Each bar can show CC and/or defensives, so the colour tooltip covers both.
	local colorTooltip = L["Change the colour of the glow/border. CC spells use dispel type colours (e.g., blue for magic) and Defensive spells are green."]

	local enabledChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Enabled"],
		GetValue = function()
			return options.Enabled
		end,
		SetValue = function(value)
			options.Enabled = value
			config:Apply()
		end,
	})

	enabledChk:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

	local showCcChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show CC"],
		Tooltip = L["Show crowd control spells in this bar."],
		GetValue = function()
			return options.ShowCC
		end,
		SetValue = function(value)
			options.ShowCC = value
			config:Apply()
		end,
	})

	showCcChk:SetPoint("LEFT", parent, "LEFT", topColWidth, 0)
	showCcChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local showDefChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show Defensives"],
		Tooltip = L["Show defensive spells in this bar."],
		GetValue = function()
			return options.ShowDefensives
		end,
		SetValue = function(value)
			options.ShowDefensives = value
			config:Apply()
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
			config:Apply()
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
			config:Apply()
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
			config:Apply()
		end,
	})

	reverseChk:SetPoint("LEFT", parent, "LEFT", topColWidth, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local dispelColoursChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Spell colours"],
		Tooltip = colorTooltip,
		GetValue = function()
			return options.Icons.ColorByCategory
		end,
		SetValue = function(value)
			options.Icons.ColorByCategory = value
			config:Apply()
		end,
	})

	dispelColoursChk:SetPoint("LEFT", parent, "LEFT", topColWidth * 2, 0)
	dispelColoursChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return options.ShowTooltips ~= false
		end,
		SetValue = function(value)
			options.ShowTooltips = value
			config:Apply()
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
			config:Apply()
		end,
	})

	showMillisChk:SetPoint("LEFT", parent, "LEFT", topColWidth * 3, 0)
	showMillisChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local iconSize = helpers:BuildClampedSlider({
		Parent = container,
		LabelText = L["Icon Size"],
		Min = 10,
		Max = 60,
		Default = 32,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Size",
	})

	-- Each bar can hold up to 8 icons.
	local maxIcons = helpers:BuildClampedSlider({
		Parent = container,
		LabelText = L["Max Icons"],
		Min = 1,
		Max = 8,
		Default = 6,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "MaxIcons",
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

	local growDdl = helpers:BuildGrowDropdown({
		Parent = container,
		Items = GROW_OPTIONS,
		Target = options,
		Key = "Grow",
		Width = DROPDOWN_WIDTH,
	})

	growDdl.Label:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing)

	iconSize.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = container,
		LabelText = L["Icon Padding"],
		Min = 0,
		Max = 20,
		Default = 2,
		Fallback = 2,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Spacing",
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local offsetX = helpers:BuildOffsetSliders({
		Parent = container,
		Offset = options.Offset,
		Width = sliderWidth,
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
			config:Apply()
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
			config:Apply()
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
			config:Apply()
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
			config:Apply()
		end,
	})
	anchorToHealthBarChk:SetPoint("TOP", scaleWithNameplateChk, "TOP", 0, 0)
	anchorToHealthBarChk:SetPoint("LEFT", parent, "LEFT", checkColumnWidth * 2, 0)
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
		db.Modules.NameplatesModule.Enabled)

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

	BuildSettingsTab(tabCtrl:GetContent("settings"), options)
	BuildSpellTypeSettings(tabCtrl:GetContent("enemyBar1"),     options.Enemy.Bar1)
	BuildSpellTypeSettings(tabCtrl:GetContent("enemyBar2"),     options.Enemy.Bar2)
	BuildSpellTypeSettings(tabCtrl:GetContent("friendlyBar1"),  options.Friendly.Bar1)
	BuildSpellTypeSettings(tabCtrl:GetContent("friendlyBar2"),  options.Friendly.Bar2)
end
