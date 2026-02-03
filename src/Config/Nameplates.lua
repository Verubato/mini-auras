---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local dropdownWidth = 200
local growOptions = {
	"LEFT",
	"RIGHT",
	"CENTER",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
local config = addon.Config

---@class NameplatesConfig
local M = {}

config.Nameplates = M

---@param parent table
---@param options NameplateOptions
local function BuildAnchorSettings(parent, options)
	local panel = CreateFrame("Frame", nil, parent)

	local growDdlLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	growDdlLbl:SetText("Grow")

	local growDdl, modernDdl = mini:Dropdown({
		Parent = panel,
		Items = growOptions,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return options.Grow
		end,
		SetValue = function(value)
			if options.Grow ~= value then
				options.Grow = value
				config:Apply()
			end
		end,
	})

	growDdl:SetWidth(dropdownWidth)
	growDdlLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	growDdl:SetPoint("TOPLEFT", growDdlLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local containerX = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return options.Offset.X
		end,
		SetValue = function(v)
			options.Offset.X = mini:ClampInt(v, -250, 250, 0)
			config:Apply()
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local containerY = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset Y",
		GetValue = function()
			return options.Offset.Y
		end,
		SetValue = function(v)
			options.Offset.Y = mini:ClampInt(v, -250, 250, 0)
			config:Apply()
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	panel:SetHeight(containerX.Slider:GetHeight() + growDdl:GetHeight() + growDdlLbl:GetHeight() + verticalSpacing * 3)

	return panel
end

---@param panel table
---@param options NameplateOptions
function M:Build(panel, options)
	local anchorPanel = BuildAnchorSettings(panel, options)

	local friendlyEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = "Friendly Enabled",
		Tooltip = "Whether to enable or disable this module for friendly nameplates.",
		GetValue = function()
			return options.FriendlyEnabled
		end,
		SetValue = function(value)
			options.FriendlyEnabled = value
			config:Apply()
		end,
	})

	friendlyEnabled:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enemyEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = "Enemy Enabled",
		Tooltip = "Whether to enable or disable this module for friendly nameplates.",
		GetValue = function()
			return options.EnemyEnabled
		end,
		SetValue = function(value)
			options.EnemyEnabled = value
			config:Apply()
		end,
	})

	enemyEnabled:SetPoint("TOPLEFT", panel, "TOPLEFT", columnWidth, 0)

	local glowChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Glow icons",
		Tooltip = "Show a glow around the CC icons.",
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	glowChk:SetPoint("TOP", enemyEnabled, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Reverse swipe",
		Tooltip = "Reverses the direction of the cooldown swipe animation.",
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply()
		end,
	})

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	reverseChk:SetPoint("TOP", enemyEnabled, "TOP", 0, 0)

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

	iconSize.Slider:SetPoint("TOPLEFT", friendlyEnabled, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	anchorPanel:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)
	anchorPanel:SetPoint("TOPRIGHT", iconSize.Slider, "BOTTOMRIGHT", 0, -verticalSpacing * 2)

	panel.OnMiniRefresh = function()
		anchorPanel:MiniRefresh()
	end
end
