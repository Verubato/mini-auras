---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local capabilities = addon.Capabilities
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
local config = addon.Config

---@class HealerCrowdControlConfig
local M = {}

config.Healer = M

---@param panel table
---@param options HealerCrowdControlModuleOptions
function M:Build(panel, options)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"A separate region for when your healer is CC'd.",
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = "Enable in:",
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = mini:Checkbox({
		Parent = panel,
		LabelText = "Everywhere",
		Tooltip = "Enable this module everywhere",
		GetValue = function()
			return db.Modules.HealerCCModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.HealerCCModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabledEverywhere:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent = panel,
		LabelText = "Arena",
		Tooltip = "Enable this module in arena",
		GetValue = function()
			return db.Modules.HealerCCModule.Enabled.Arena
		end,
		SetValue = function(value)
			db.Modules.HealerCCModule.Enabled.Arena = value
			config:Apply()
		end,
	})

	enabledArena:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	enabledArena:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledRaids = mini:Checkbox({
		Parent = panel,
		LabelText = "BGS & Raids",
		Tooltip = "Enable this module in BGs and raids.",
		GetValue = function()
			return db.Modules.HealerCCModule.Enabled.Raids
		end,
		SetValue = function(value)
			db.Modules.HealerCCModule.Enabled.Raids = value
			config:Apply()
		end,
	})

	enabledRaids:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	enabledRaids:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent = panel,
		LabelText = "Dungeons",
		Tooltip = "Enable this module in dungeons and M+.",
		GetValue = function()
			return db.Modules.HealerCCModule.Enabled.Dungeons
		end,
		SetValue = function(value)
			db.Modules.HealerCCModule.Enabled.Dungeons = value
			config:Apply()
		end,
	})

	enabledDungeons:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = "Settings",
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing)

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

	glowChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

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

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local soundChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Sound",
		Tooltip = "Play a sound when the healer is CC'd.",
		GetValue = function()
			return options.Sound.Enabled
		end,
		SetValue = function(value)
			options.Sound.Enabled = value
			config:Apply()
		end,
	})

	soundChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	soundChk:SetPoint("TOP", reverseChk, "TOP", 0, 0)

	local dispelColoursChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Dispel colours",
		Tooltip = "Change the colour of the glow/border based on the type of debuff.",
		GetValue = function()
			return options.Icons.ColorByDispelType
		end,
		SetValue = function(value)
			options.Icons.ColorByDispelType = value
			config:Apply()
		end,
	})

	dispelColoursChk:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 0, -verticalSpacing)

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

	iconSize.Slider:SetPoint("TOPLEFT", dispelColoursChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local fontSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 100,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = "Text Size",
		GetValue = function()
			return options.Font.Size
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 10, 100, 32)
			if options.Font.Size ~= newValue then
				options.Font.Size = newValue
				config:Apply()
			end
		end,
	})

	fontSize.Slider:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end
