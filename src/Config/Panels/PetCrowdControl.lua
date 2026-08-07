---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
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

---@class PetCrowdControlConfig
local M = {}

config.PetCrowdControl = M

---@param panel table
---@param options PetCrowdControlModuleOptions
local function BuildPetInstance(panel, options)
	local parent = CreateFrame("Frame", nil, panel)
	local sliderWidth = columnWidth * 2 - horizontalSpacing

	local petEnabledEverywhere = helpers:BuildEnableRow(parent, nil, options.Enabled, {
		World = L["Enable pet frame CC in the open world."],
		Arena = L["Enable pet frame CC in arena."],
		BattleGrounds = L["Enable pet frame CC in battlegrounds."],
		Dungeons = L["Enable pet frame CC in dungeons."],
		Raid = L["Enable pet frame CC in raids."],
	})

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
			config:Apply()
		end,
	})

	glowChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local dispelColoursChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Dispel colours"],
		Tooltip = L["Change the colour of the glow/border based on the type of debuff."],
		GetValue = function()
			return options.Icons.ColorByDispelType
		end,
		SetValue = function(value)
			options.Icons.ColorByDispelType = value
			config:Apply()
		end,
	})

	dispelColoursChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth, 0)
	dispelColoursChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = parent,
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

	reverseChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 2, 0)
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
			config:Apply()
		end,
	})

	showTooltipsChk:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 3, 0)
	showTooltipsChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local size = helpers:BuildSizeControls({
		Parent = parent,
		Icons = options.Icons,
		PixelDefault = 24,
		PercentDefault = 50,
		Width = sliderWidth,
	})

	size.Checkbox:SetPoint("LEFT", parent, "LEFT", enabledColumnWidth * 4, 0)
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
			config:Apply()
		end,
	})

	includePetFrameChk:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local growDdl = helpers:BuildGrowDropdown({
		Parent = parent,
		Items = GROW_OPTIONS,
		Target = options,
		Key = "Grow",
		Width = DROPDOWN_WIDTH,
	})

	growDdl.Label:SetPoint("TOPLEFT", includePetFrameChk, "BOTTOMLEFT", 4, -verticalSpacing * 2)

	size.Pixel.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local maxIcons = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Max Icons"],
		Min = 1,
		Max = 5,
		Default = 3,
		Fallback = 3,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Count",
	})

	maxIcons.Slider:SetPoint("LEFT", size.Pixel.Slider, "RIGHT", horizontalSpacing, 0)

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = parent,
		LabelText = L["Icon Padding"],
		Min = 0,
		Max = 20,
		Default = 2,
		Fallback = 2,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
	})

	iconSpacing.Slider:SetPoint("TOPLEFT", size.Pixel.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local offsetX = helpers:BuildOffsetSliders({
		Parent = parent,
		Offset = options.Offset,
		Width = sliderWidth,
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

	local petPanel = BuildPetInstance(panel, db.Modules.PetCCModule)
	petPanel:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	petPanel:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
	petPanel:SetHeight(SUB_PANEL_HEIGHT)

	-- The controls all live on the inner instance frame, so the page forwards its refresh.
	panel.MiniRefresh = function()
		petPanel:MiniRefresh()
	end
end
