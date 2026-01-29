---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local dropdownWidth = 200
local anchorPoints = {
	"TOPLEFT",
	"TOP",
	"TOPRIGHT",
	"LEFT",
	"CENTER",
	"RIGHT",
	"BOTTOMLEFT",
	"BOTTOM",
	"BOTTOMRIGHT",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
local config = addon.Config

---@class InstanceConfig
local M = {}

config.Instance = M

---@param parent table
---@param options InstanceOptions
local function BuildSimpleMode(parent, options)
	local panel = CreateFrame("Frame", nil, parent)
	local containerX = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return options.SimpleMode.Offset.X
		end,
		SetValue = function(v)
			options.SimpleMode.Offset.X = mini:ClampInt(v, -250, 250, 0)
			config:Apply()
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local containerY = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset Y",
		GetValue = function()
			return options.SimpleMode.Offset.Y
		end,
		SetValue = function(v)
			options.SimpleMode.Offset.Y = mini:ClampInt(v, -250, 250, 0)
			config:Apply()
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	return panel
end

---@param parent table
---@param options InstanceOptions
local function BuildAdvancedMode(parent, options)
	local panel = CreateFrame("Frame", nil, parent)
	local containerX = mini:Slider({
		Parent = panel,
		Min = -20,
		Max = 50,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return options.AdvancedMode.Offset.X
		end,
		SetValue = function(v)
			options.AdvancedMode.Offset.X = mini:ClampInt(v, -50, 50, 0)
			config:Apply()
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local containerY = mini:Slider({
		Parent = panel,
		Min = -20,
		Max = 50,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset Y",
		GetValue = function()
			return options.AdvancedMode.Offset.Y
		end,
		SetValue = function(v)
			options.AdvancedMode.Offset.Y = mini:ClampInt(v, -200, 200, 0)
			config:Apply()
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	local pointDdlLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	pointDdlLbl:SetText("Anchor Point")

	local pointDdl, modernDdl = mini:Dropdown({
		Parent = panel,
		Items = anchorPoints,
		Width = columnWidth,
		GetValue = function()
			return options.AdvancedMode.Point
		end,
		SetValue = function(value)
			if options.AdvancedMode.Point ~= value then
				options.AdvancedMode.Point = value
				config:Apply()
			end
		end,
	})

	pointDdl:SetWidth(dropdownWidth)
	pointDdlLbl:SetPoint("TOPLEFT", containerX.Slider, "BOTTOMLEFT", -4, -verticalSpacing)
	-- no idea why by default it's off by 16 points
	pointDdl:SetPoint("TOPLEFT", pointDdlLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local relativeToLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	relativeToLbl:SetText("Relative to")

	local relativeToDdl = mini:Dropdown({
		Parent = panel,
		Items = anchorPoints,
		Width = columnWidth,
		GetValue = function()
			return options.AdvancedMode.RelativePoint
		end,
		SetValue = function(value)
			if options.AdvancedMode.RelativePoint ~= value then
				options.AdvancedMode.RelativePoint = value
				config:Apply()
			end
		end,
	})

	relativeToDdl:SetWidth(dropdownWidth)
	relativeToDdl:SetPoint("LEFT", pointDdl, "RIGHT", horizontalSpacing, 0)
	relativeToLbl:SetPoint("BOTTOMLEFT", relativeToDdl, "TOPLEFT", 0, 8)
	return panel
end

---@param panel table
---@param options InstanceOptions
function M:Build(panel, options)
	local simpleMode = BuildSimpleMode(panel, options)
	local advancedMode = BuildAdvancedMode(panel, options)

	local function SetMode()
		if options.SimpleMode.Enabled then
			simpleMode:Show()
			advancedMode:Hide()
		else
			advancedMode:Show()
			simpleMode:Hide()
		end
	end

	local enabledChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Enabled",
		GetValue = function()
			return options.Enabled
		end,
		SetValue = function(value)
			options.Enabled = value

			config:Apply()
		end,
	})

	enabledChk:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local excludePlayerChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Exclude self",
		GetValue = function()
			return options.ExcludePlayer
		end,
		SetValue = function(value)
			options.ExcludePlayer = value
			addon:Refresh()
		end,
	})

	excludePlayerChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	excludePlayerChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local glowChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Glow icons",
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	glowChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Reverse swipe",
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply()
		end,
	})

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	reverseChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)

	local simpleChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Simple settings",
		GetValue = function()
			return options.SimpleMode.Enabled
		end,
		SetValue = function(value)
			options.SimpleMode.Enabled = value

			SetMode()
			config:Apply()
		end,
	})

	simpleChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local iconSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 200,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = "Icon Size",
		GetValue = function()
			return options.Icons.Size
		end,
		SetValue = function(v)
			options.Icons.Size = mini:ClampInt(v, 10, 200, 32)
			config:Apply()
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", simpleChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	simpleMode:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)
	simpleMode:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)

	advancedMode:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)
	advancedMode:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)

	local baseRefresh = panel.MiniRefresh
	panel.MiniRefresh = function(panelSelf)
		if baseRefresh then
			baseRefresh(panelSelf)
		end

		SetMode()
	end

	SetMode()

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("TOPLEFT", advancedMode, "BOTTOMLEFT", 0, -verticalSpacing * 2)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		addon:ToggleTest(options)
	end)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
		addon:TestOptions(options)
	end)
end
