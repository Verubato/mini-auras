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
	"DOWN",
	"UP",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local moduleName = addon.Utils.ModuleName

---@class CrowdControlConfig
local M = {}

config.CrowdControl = M

---@param panel table
---@param options CrowdControlInstanceOptions
---@param defaults CrowdControlInstanceOptions The shipped values for this group, which the
---sliders clamp back to when the typed input is not a number.
local function BuildInstance(panel, options, defaults)
	local parent = CreateFrame("Frame", nil, panel)
	local sliderWidth = columnWidth * 2 - horizontalSpacing
	local UpdateCcSwatch

	local excludePlayerChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Exclude self"],
		Tooltip = L["Exclude yourself from showing CC icons."],
		GetValue = function()
			return options.ExcludePlayer
		end,
		SetValue = function(value)
			options.ExcludePlayer = value
			config:Apply(moduleName.CrowdControl)
		end,
	})

	excludePlayerChk:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local glowChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the CC icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply(moduleName.CrowdControl)
		end,
	})

	glowChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)
	glowChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local dispelColoursChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Dispel colours"],
		Tooltip = L["Change the colour of the glow/border based on the type of debuff."],
		GetValue = function()
			return options.Icons.ColorByDispelType
		end,
		SetValue = function(value)
			options.Icons.ColorByDispelType = value
			UpdateCcSwatch()
			config:Apply(moduleName.CrowdControl)
		end,
	})

	dispelColoursChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
	dispelColoursChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply(moduleName.CrowdControl)
		end,
	})

	reverseChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 3, 0)
	reverseChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return options.ShowTooltips ~= false
		end,
		SetValue = function(value)
			options.ShowTooltips = value
			config:Apply(moduleName.CrowdControl)
		end,
	})

	showTooltipsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 4, 0)
	showTooltipsChk:SetPoint("TOP", excludePlayerChk, "TOP", 0, 0)

	local showMillisChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Milliseconds"],
		Tooltip = L["Show decimal milliseconds on the cooldown timer when below the configured threshold."],
		GetValue = function()
			return options.Icons.ShowMilliseconds == true
		end,
		SetValue = function(value)
			options.Icons.ShowMilliseconds = value
			config:Apply(moduleName.CrowdControl)
		end,
	})

	showMillisChk:SetPoint("TOPLEFT", excludePlayerChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local ccSwatch = mini:ColorSwatch({
		Parent = parent,
		LabelText = L["CC"],
		Tooltip = L["Change the colour of the glow on crowd control spells."],
		HasOpacity = false,
		GetValue = function()
			local color = options.Icons.Color
			return color.R, color.G, color.B, color.A
		end,
		SetValue = function(r, g, b, a)
			local color = options.Icons.Color
			color.R, color.G, color.B, color.A = r, g, b, a
			config:Apply(moduleName.CrowdControl)
		end,
	})

	ccSwatch:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
	ccSwatch:SetPoint("TOP", showMillisChk, "TOP", 0,
		-math.floor((showMillisChk:GetHeight() - ccSwatch:GetHeight()) / 2))

	-- The dispel palette wins over this colour, so with it on the swatch has nothing to say and
	-- goes away rather than sitting there doing nothing.
	function UpdateCcSwatch()
		local shown = options.Icons.ColorByDispelType ~= true

		ccSwatch:SetShown(shown)
		ccSwatch.Label:SetShown(shown)
	end

	UpdateCcSwatch()

	parent.OnMiniRefresh = UpdateCcSwatch

	local size = helpers:BuildSizeControls({
		Parent = parent,
		Icons = options.Icons,
		PixelDefault = defaults.Icons.Size,
		PercentDefault = defaults.Icons.SizePercent,
		Width = sliderWidth,
		SettingsKey = moduleName.CrowdControl,
	})

	size.Checkbox:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)
	size.Checkbox:SetPoint("TOP", showMillisChk, "TOP", 0, 0)

	local growDdl = helpers:BuildGrowDropdown({
		Parent = parent,
		Items = GROW_OPTIONS,
		Target = options,
		Key = "Grow",
		Width = DROPDOWN_WIDTH,
		SettingsKey = moduleName.CrowdControl,
	})

	growDdl.Label:SetPoint("TOPLEFT", showMillisChk, "BOTTOMLEFT", 4, -verticalSpacing * 2)

	size.Pixel.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxIcons = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Max Icons"],
		Tooltip = L["Most icons shown at once on each unit."],
		Min = 1,
		Max = 5,
		Default = defaults.Icons.Count,
		Fallback = defaults.Icons.Count,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Count",
		SettingsKey = moduleName.CrowdControl,
	})

	maxIcons.Slider:SetPoint("LEFT", size.Pixel.Slider, "RIGHT", horizontalSpacing, 0)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Padding"],
		Tooltip = L["Space between icons."],
		Min = 0,
		Max = 20,
		Default = defaults.IconSpacing,
		Fallback = defaults.IconSpacing,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
		SettingsKey = moduleName.CrowdControl,
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", size.Pixel.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local offsetX = helpers:BuildOffsetSliders({
		Parent = parent,
		Offset = options.Offset,
		Width = sliderWidth,
		SettingsKey = moduleName.CrowdControl,
	})

	offsetX.Slider:SetPoint("TOPLEFT", iconSpacing.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	return parent
end

---@param panel table
---@param default CrowdControlInstanceOptions
---@param raid CrowdControlInstanceOptions
function M:Build(panel, default, raid)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	-- Shared 5-column checkbox grid: the Enable-in row and settings checkbox rows all sit on
	-- the same vertical lines.
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Shows CC icons on party/raid frames."],
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

	local enabledEverywhere = helpers:BuildEnableRow(panel, enabledDivider, db.Modules.CrowdControl.Enabled,
		nil, moduleName.CrowdControl)

	local subPanelHeight = 340
	local tabContainer = CreateFrame("Frame", nil, panel)
	tabContainer:SetPoint("TOPLEFT",  enabledEverywhere, "BOTTOMLEFT",  0, -verticalSpacing)
	tabContainer:SetPoint("TOPRIGHT", panel,             "TOPRIGHT",    0, 0)
	tabContainer:SetHeight(subPanelHeight + 34)

	local tabIsRaid = { default = false, raid = true }

	local tabCtrl = mini:CreateTabs({
		Parent = tabContainer,
		TabHeight = 28,
		StripHeight = 34,
		TabFitToParent = true,
		ContentInsets = { Top = verticalSpacing },
		Tabs = {
			{ Key = "default", Title = L["World/Arena/Dungeons"] },
			{ Key = "raid",    Title = L["Raids/Battlegrounds"] },
		},
		OnTabChanged = function(key)
			local isRaid = tabIsRaid[key]
			if isRaid ~= nil then
				addon.CurrentTestIsRaid = isRaid
				if addon:IsTestActive() then
					addon:TestWithOptions(isRaid)
				end
			end
		end,
	})

	local defaultContent = tabCtrl:GetContent("default")
	local defaultPanel = BuildInstance(defaultContent, default, dbDefaults.Modules.CrowdControl.Default)
	defaultPanel:SetPoint("TOPLEFT",  defaultContent, "TOPLEFT",  0, 0)
	defaultPanel:SetPoint("TOPRIGHT", defaultContent, "TOPRIGHT", 0, 0)
	defaultPanel:SetHeight(subPanelHeight)

	local raidContent = tabCtrl:GetContent("raid")
	local raidPanel = BuildInstance(raidContent, raid, dbDefaults.Modules.CrowdControl.Raid)
	raidPanel:SetPoint("TOPLEFT",  raidContent, "TOPLEFT",  0, 0)
	raidPanel:SetPoint("TOPRIGHT", raidContent, "TOPRIGHT", 0, 0)
	raidPanel:SetHeight(subPanelHeight)

	panel.OnMiniRefresh = function()
		defaultPanel:MiniRefresh()
		raidPanel:MiniRefresh()
	end
end
