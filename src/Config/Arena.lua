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
---@type Db
local db

---@class ArenaConfig
local M = {}

config.Arena = M

local function BuildSimpleMode(parent)
	local panel = CreateFrame("Frame", nil, parent)
	local containerX = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return db.SimpleMode.Offset.X
		end,
		SetValue = function(v)
			db.SimpleMode.Offset.X = mini:ClampInt(v, -250, 250, dbDefaults.SimpleMode.Offset.X)
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
			return db.SimpleMode.Offset.Y
		end,
		SetValue = function(v)
			db.SimpleMode.Offset.Y = mini:ClampInt(v, -250, 250, dbDefaults.SimpleMode.Offset.Y)
			config:Apply()
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	return panel
end

local function BuildAdvancedMode(parent)
	local panel = CreateFrame("Frame", nil, parent)
	local containerX = mini:Slider({
		Parent = panel,
		Min = -20,
		Max = 50,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return db.AdvancedMode.Offset.X
		end,
		SetValue = function(v)
			db.AdvancedMode.Offset.X = mini:ClampInt(v, -50, 50, dbDefaults.AdvancedMode.Offset.X)
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
			return db.AdvancedMode.Offset.Y
		end,
		SetValue = function(v)
			db.AdvancedMode.Offset.Y = mini:ClampInt(v, -200, 200, dbDefaults.AdvancedMode.Offset.Y)
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
			return db.AdvancedMode.Point
		end,
		SetValue = function(value)
			if db.AdvancedMode.Point ~= value then
				db.AdvancedMode.Point = value
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
			return db.AdvancedMode.RelativePoint
		end,
		SetValue = function(value)
			if db.AdvancedMode.RelativePoint ~= value then
				db.AdvancedMode.RelativePoint = value
				config:Apply()
			end
		end,
	})

	relativeToDdl:SetWidth(dropdownWidth)
	relativeToDdl:SetPoint("LEFT", pointDdl, "RIGHT", horizontalSpacing, 0)
	relativeToLbl:SetPoint("BOTTOMLEFT", relativeToDdl, "TOPLEFT", 0, 8)
	return panel
end

function M:Build(panel)
	db = mini:GetSavedVars()

	local simpleMode = BuildSimpleMode(panel)
	local advancedMode = BuildAdvancedMode(panel)

	local function SetMode()
		if db.SimpleMode.Enabled then
			simpleMode:Show()
			advancedMode:Hide()
		else
			advancedMode:Show()
			simpleMode:Hide()
		end
	end

	local simpleChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Simple settings",
		GetValue = function()
			return db.SimpleMode.Enabled
		end,
		SetValue = function(value)
			db.SimpleMode.Enabled = value

			SetMode()
		end,
	})

	simpleChk:SetPoint("TOPLEFT", panel, "TOPLEFT", -4, 0)

	local iconSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 200,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = "Icon Size",
		GetValue = function()
			return db.Icons.Size
		end,
		SetValue = function(v)
			db.Icons.Size = mini:ClampInt(v, 10, 200, dbDefaults.Icons.Size)
			config:Apply()
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", simpleChk, "BOTTOMLEFT", 0, -verticalSpacing * 3)

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
	testBtn:SetPoint("LEFT", resetBtn, "RIGHT", horizontalSpacing, 0)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		addon:ToggleTest()
	end)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end
