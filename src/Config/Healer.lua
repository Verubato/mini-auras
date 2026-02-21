---@type string, Addon
local addonName, addon = ...
local mini = addon.Core.Framework
local L = addon.L
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
			L["A separate region for when your healer is CC'd."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in:"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = mini:Checkbox({
		Parent = panel,
		LabelText = L["Everywhere"],
		Tooltip = L["Enable this module everywhere."],
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
		LabelText = L["Arena"],
		Tooltip = L["Enable this module in arena."],
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
		LabelText = L["BGS & Raids"],
		Tooltip = L["Enable this module in BGs and raids."],
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
		LabelText = L["Dungeons"],
		Tooltip = L["Enable this module in dungeons and M+."],
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
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing)

	local glowChk = mini:Checkbox({
		Parent = panel,
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

	local showTextChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show warning text"],
		Tooltip = L["Show the 'Healer in CC!' text above the icons."],
		GetValue = function()
			return options.ShowWarningText ~= false
		end,
		SetValue = function(value)
			options.ShowWarningText = value
			config:Apply()
		end,
	})

	showTextChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	showTextChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = panel,
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

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local dispelColoursChk = mini:Checkbox({
		Parent = panel,
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

	dispelColoursChk:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local soundChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Sound"],
		Tooltip = L["Play a sound when the healer is CC'd."],
		GetValue = function()
			return options.Sound.Enabled
		end,
		SetValue = function(value)
			options.Sound.Enabled = value
			if value then
				-- Play the sound when enabled
				local soundFileName = options.Sound.File or "Sonar.ogg"
				local soundFile = config.MediaLocation .. soundFileName
				PlaySoundFile(soundFile, options.Sound.Channel or "Master")
			end
			config:Apply()
		end,
	})

	soundChk:SetPoint("TOPLEFT", dispelColoursChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local soundFileDropdown = mini:Dropdown({
		Parent = panel,
		Items = config.SoundFiles,
		Width = 200,
		GetValue = function()
			return options.Sound.File or "Sonar.ogg"
		end,
		SetValue = function(value)
			options.Sound.File = value
			-- Play the selected sound
			local soundFile = config.MediaLocation .. value
			PlaySoundFile(soundFile, options.Sound.Channel or "Master")
			config:Apply()
		end,
		GetText = function(value)
			return value:gsub("%.ogg$", "")
		end,
	})

	soundFileDropdown:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	soundFileDropdown:SetPoint("TOP", soundChk, "TOP", 0, -4)
	soundFileDropdown:SetWidth(200)

	local iconSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 200,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = L["Icon Size"],
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

	iconSize.Slider:SetPoint("TOPLEFT", soundChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local fontSize = mini:Slider({
		Parent = panel,
		Min = 10,
		Max = 100,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = L["Text Size"],
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
