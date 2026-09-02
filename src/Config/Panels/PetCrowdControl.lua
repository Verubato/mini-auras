---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local dbDefaults = addon.Config.Defaults
local auraContainerDisplay = addon.Core.AuraContainerDisplay
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
-- The CC sub-panel height plus the Settings divider this page adds above the controls.
local SUB_PANEL_HEIGHT = 380
local columnWidth
local enabledColumnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local moduleName = addon.Utils.ModuleName

---@class PetCrowdControlConfig
local M = {}

config.PetCrowdControl = M

---@param panel table
---@param options PetCrowdControlModuleOptions
local function BuildPetInstance(panel, options)
	local parent = CreateFrame("Frame", nil, panel)
	local sliderWidth = columnWidth * 2 - horizontalSpacing
	local UpdateCcSwatch

	local petEnabledEverywhere = helpers:BuildEnableRow(parent, nil, options.Enabled, {
		World = L["Enable pet frame CC in the open world."],
		Arena = L["Enable pet frame CC in arena."],
		BattleGrounds = L["Enable pet frame CC in battlegrounds."],
		Dungeons = L["Enable pet frame CC in dungeons."],
		Raid = L["Enable pet frame CC in raids."],
	}, moduleName.PetCrowdControl)

	local settingsDivider = mini:Divider({
		Parent = parent,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", parent, "LEFT")
	settingsDivider:SetPoint("RIGHT", parent, "RIGHT")
	settingsDivider:SetPoint("TOP", petEnabledEverywhere, "BOTTOM", 0, -verticalSpacing)

	local glowChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the CC icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply(moduleName.PetCrowdControl)
		end,
	})

	glowChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local reverseChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply(moduleName.PetCrowdControl)
		end,
	})

	reverseChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show tooltips"],
		Tooltip = L["Shows a spell tooltip when hovering over an icon."],
		GetValue = function()
			return options.ShowTooltips ~= false
		end,
		SetValue = function(value)
			options.ShowTooltips = value
			config:Apply(moduleName.PetCrowdControl)
		end,
	})

	showTooltipsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
	showTooltipsChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local size = helpers:BuildSizeControls({
		Parent = parent,
		Icons = options.Icons,
		PixelDefault = dbDefaults.Modules.PetCrowdControl.Icons.Size,
		PercentDefault = dbDefaults.Modules.PetCrowdControl.Icons.SizePercent,
		Width = sliderWidth,
		SettingsKey = moduleName.PetCrowdControl,
	})

	size.Checkbox:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 3, 0)
	size.Checkbox:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local includePetFrameChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Show on pet unit frame"],
		Tooltip = L["Also show a CC icon container next to your own pet's unit frame (Blizzard or supported unit-frame addons), in addition to the party/raid pet frames."],
		GetValue = function()
			return options.IncludePetFrame == true
		end,
		SetValue = function(value)
			options.IncludePetFrame = value
			config:Apply(moduleName.PetCrowdControl)
		end,
	})

	includePetFrameChk:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 0, -verticalSpacing)

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
			config:Apply(moduleName.PetCrowdControl)
		end,
	})

	ccSwatch:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
	ccSwatch:SetPoint("TOP", includePetFrameChk, "TOP", 0,
		-math.floor((includePetFrameChk:GetHeight() - ccSwatch:GetHeight()) / 2))

	-- The swatch only means anything in Custom mode, so it goes away rather than sitting there doing nothing.
	function UpdateCcSwatch()
		local shown = auraContainerDisplay:ResolveColorMode(options.Icons) == auraContainerDisplay.ColorMode.Custom

		ccSwatch:SetShown(shown)
		ccSwatch.Label:SetShown(shown)
	end

	UpdateCcSwatch()

	parent.OnMiniRefresh = UpdateCcSwatch

	local growDdl = helpers:BuildGrowDropdown({
		Parent = parent,
		Items = GROW_OPTIONS,
		Target = options,
		Key = "Grow",
		Width = DROPDOWN_WIDTH,
		SettingsKey = moduleName.PetCrowdControl,
	})

	growDdl.Label:SetPoint("TOPLEFT", includePetFrameChk, "BOTTOMLEFT", 4, -verticalSpacing * 2)

	local colorsDdl = helpers:BuildColorModeDropdown({
		Parent = parent,
		Tooltip = L["Tints the glow and border with the CC colour above. Dispel colours instead give it the game's debuff colours, e.g. blue for magic. None leaves the icons uncoloured."],
		Width = DROPDOWN_WIDTH,
		Target = options.Icons,
		Key = "ColorMode",
		SettingsKey = moduleName.PetCrowdControl,
		GetValue = function()
			return auraContainerDisplay:ResolveColorMode(options.Icons)
		end,
		SetValue = function(value)
			options.Icons.ColorMode = value
			UpdateCcSwatch()
			config:Apply(moduleName.PetCrowdControl)
		end,
	})

	colorsDdl.Label:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
	colorsDdl.Label:SetPoint("TOP", growDdl.Label, "TOP", 0, 0)

	size.Pixel.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxIcons = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Max Icons"],
		Tooltip = L["Most icons shown at once on each unit."],
		Min = 1,
		Max = 5,
		Default = dbDefaults.Modules.PetCrowdControl.Icons.Count,
		Fallback = dbDefaults.Modules.PetCrowdControl.Icons.Count,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Count",
		SettingsKey = moduleName.PetCrowdControl,
	})

	maxIcons.Slider:SetPoint("LEFT", size.Pixel.Slider, "RIGHT", horizontalSpacing, 0)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Padding"],
		Tooltip = L["Space between icons."],
		Min = 0,
		Max = 20,
		Default = dbDefaults.Modules.PetCrowdControl.IconSpacing,
		Fallback = dbDefaults.Modules.PetCrowdControl.IconSpacing,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
		SettingsKey = moduleName.PetCrowdControl,
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", size.Pixel.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local fontScale = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Font Scale"],
		Tooltip = L["Scales this module's countdown text, leaving the icon size alone."],
		Min = 0.5,
		Max = 2.0,
		Step = 0.05,
		Default = dbDefaults.Modules.PetCrowdControl.FontScale,
		Fallback = dbDefaults.Modules.PetCrowdControl.FontScale,
		Float = true,
		Width = sliderWidth,
		Target = options,
		Key = "FontScale",
		SettingsKey = moduleName.PetCrowdControl,
	})

	fontScale.Slider:SetPoint("LEFT", iconSpacing.Slider, "RIGHT", horizontalSpacing, 0)
	fontScale.Slider:SetPoint("TOP", iconSpacing.Slider, "TOP", 0, 0)

	local offsetX = helpers:BuildOffsetSliders({
		Parent = parent,
		Offset = options.Offset,
		Width = sliderWidth,
		SettingsKey = moduleName.PetCrowdControl,
	})

	offsetX.Slider:SetPoint("TOPLEFT", iconSpacing.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	return parent
end

---@param panel table
function M:Build(panel)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	-- Shared 5-column checkbox grid: the Enable-in row and settings checkbox rows all sit on
	-- the same vertical lines.
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Shows CC icons on party/raid pet frames."],
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

	local petPanel = BuildPetInstance(panel, db.Modules.PetCrowdControl)
	petPanel:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	petPanel:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
	petPanel:SetHeight(SUB_PANEL_HEIGHT)

	-- The controls all live on the inner instance frame, so the page forwards its refresh.
	panel.MiniRefresh = function()
		petPanel:MiniRefresh()
	end
end
