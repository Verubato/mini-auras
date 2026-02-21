---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config

---@class TrinketsConfig
local M = {}

config.Trinkets = M

function M:Build()
	local db = mini:GetSavedVars()
	local columns = 3
	local columnWidth = mini:ColumnWidth(columns, 0, 0)

	local panel = CreateFrame("Frame")
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 0, -verticalSpacing)
	title:SetText(L["Party Trinkets"])

	local enabled = mini:Checkbox({
		Parent = panel,
		LabelText = L["Enabled"],
		Tooltip = L["Whether to enable or disable this module."],
		GetValue = function()
			return db.Modules.TrinketsModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.TrinketsModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabled:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -verticalSpacing)

	local excludePlayerChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Exclude self"],
		Tooltip = L["Exclude yourself from showing trinket icons."],
		GetValue = function()
			return db.Modules.TrinketsModule.ExcludePlayer
		end,
		SetValue = function(value)
			db.Modules.TrinketsModule.ExcludePlayer = value
			config:Apply()
		end,
	})

	excludePlayerChk:SetPoint("TOP", enabled, "TOP", 0, 0)
	excludePlayerChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)

	local iconSizeSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Icon Size"],
		GetValue = function()
			return db.Modules.TrinketsModule.Icons.Size
		end,
		SetValue = function(value)
			local newValue = mini:ClampInt(value, 10, 100, 40)
			if db.Modules.TrinketsModule.Icons.Size ~= newValue then
				db.Modules.TrinketsModule.Icons.Size = newValue
				config:Apply()
			end
		end,
		Width = columns * columnWidth - horizontalSpacing,
		Min = 10,
		Max = 100,
		Step = 1,
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", enabled, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local offsetXSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Offset X"],
		GetValue = function()
			return db.Modules.TrinketsModule.Offset.X
		end,
		SetValue = function(value)
			local newValue = mini:ClampInt(value, -200, 200, 0)
			if db.Modules.TrinketsModule.Offset.X ~= newValue then
				db.Modules.TrinketsModule.Offset.X = newValue
				config:Apply()
			end
		end,
		Width = (columns / 2) * columnWidth - horizontalSpacing,
		Min = -200,
		Max = 200,
		Step = 1,
	})

	offsetXSlider.Slider:SetPoint("TOPLEFT", iconSizeSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local offsetYSlider = mini:Slider({
		Parent = panel,
		LabelText = L["Offset Y"],
		GetValue = function()
			return db.Modules.TrinketsModule.Offset.Y
		end,
		SetValue = function(value)
			local newValue = mini:ClampInt(value, -200, 200, 0)
			if db.Modules.TrinketsModule.Offset.Y ~= newValue then
				db.Modules.TrinketsModule.Offset.Y = newValue
				config:Apply()
			end
		end,
		Width = (columns / 2) * columnWidth - horizontalSpacing,
		Min = -200,
		Max = 200,
		Step = 1,
	})

	offsetYSlider.Slider:SetPoint("LEFT", offsetXSlider.Slider, "RIGHT", horizontalSpacing, 0)

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Limitations:"],
			L[" - Doesn't work if your team mates trinket in the starting room."],
			L[" - Doesn't work in the open world."],
		},
	})

	lines:SetPoint("TOPLEFT", offsetXSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)
	testBtn:SetPoint("TOP", title, "TOP", 0, 0)
	testBtn:SetText(L["Test"])
	testBtn:SetScript("OnClick", function()
		local options = db.Modules.CCModule.Default

		addon:ToggleTest(options)
	end)

	return panel
end
