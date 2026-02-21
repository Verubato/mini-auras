---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
local config = addon.Config

---@class AlertsConfig
local M = {}

config.Alerts = M

---@param panel table
---@param options AlertsModuleOptions
function M:Build(panel, options)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"A separate region for showing important enemy spells.",
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Enabled",
		Tooltip = "Enable this module everywhere.",
		GetValue = function()
			return db.Modules.AlertsModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.AlertsModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabledChk:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing)

	local includeDefensivesChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Include Defensives",
		Tooltip = "Includes defensives in the alerts.",
		GetValue = function()
			-- TODO: refactor this to just "IncludeDefensives" as it also includes externals
			return options.IncludeBigDefensives
		end,
		SetValue = function(value)
			options.IncludeBigDefensives = value
			config:Apply()
		end,
	})

	includeDefensivesChk:SetPoint("TOP", enabledChk, "TOP", 0, 0)
	includeDefensivesChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)

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

	glowChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local colorByClassChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Color by class",
		Tooltip = "Color the glow/border by the enemy's class color.",
		GetValue = function()
			return options.Icons.ColorByClass
		end,
		SetValue = function(value)
			options.Icons.ColorByClass = value
			config:Apply()
		end,
	})

	colorByClassChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	colorByClassChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

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

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	reverseChk:SetPoint("TOP", colorByClassChk, "TOP", 0, 0)

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
			local newValue = mini:ClampInt(v, 10, 200, 32)
			if options.Icons.Size ~= newValue then
				options.Icons.Size = newValue
				config:Apply()
			end
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end
