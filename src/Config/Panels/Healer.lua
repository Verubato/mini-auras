---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local COLUMNS = 4
local columnWidth
local enabledColumnWidth
local config = addon.Config
local helpers = addon.Config.PanelHelpers
local sounds = addon.Core.Sounds

---@class HealerCrowdControlConfig
local M = {}

config.Healer = M

---@param panel table
---@param options HealerCrowdControlModuleOptions
function M:Build(panel, options)
	columnWidth = mini:ColumnWidth(COLUMNS, 0, 0)
	-- Shared 5-column checkbox grid: the Enable-in row and settings checkbox rows all sit on
	-- the same vertical lines.
	enabledColumnWidth = mini:ColumnWidth(5, 0, 0)
	local db = mini:GetSavedVars()
	-- 12.1: the warning text (and its Text Size slider) is hidden - it needs the addon to know a
	-- healer is CC'd, and aura presence is secret there. The SOUND options stay visible: the
	-- engine plays those itself via AddAuraSound, so that feature survived. Hiding the text also
	-- frees a column, which is why several controls below are positioned differently per path.
	-- TEMPORARY: remove the gates with the legacy path once 12.1 is live.
	local useAuraContainers = addon.Utils.WoWEx:UseAuraContainers()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["A separate region for when your healer is CC'd."],
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

	local enabledEverywhere = helpers:BuildEnableRow(panel, enabledDivider, db.Modules.HealerCCModule.Enabled)

	local settingsDivider = mini:Divider({
		Parent = panel,
		Text = L["Settings"],
	})
	settingsDivider:SetPoint("LEFT", panel, "LEFT")
	settingsDivider:SetPoint("RIGHT", panel, "RIGHT")
	settingsDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing)

	local showIconsChk = mini:Checkbox({
		Parent = panel,
		LabelText = L["Show icons"],
		Tooltip = L["Show CC icons when healer is CC'd."],
		GetValue = function()
			return options.Icons.Enabled
		end,
		SetValue = function(value)
			options.Icons.Enabled = value
			config:Apply()
		end,
	})

	showIconsChk:SetPoint("TOPLEFT", settingsDivider, "BOTTOMLEFT", 0, -verticalSpacing)

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

	glowChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth, 0)
	glowChk:SetPoint("TOP", showIconsChk, "TOP", 0, 0)

	if not useAuraContainers then
		local showTextChk = mini:Checkbox({
			Parent = panel,
			LabelText = L["Show warning text"],
			Tooltip = L["Show the 'Healer in CC!' text above the icons."],
			GetValue = function()
				return options.ShowWarningText
			end,
			SetValue = function(value)
				options.ShowWarningText = value
				config:Apply()
			end,
		})

		showTextChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 2, 0)
		showTextChk:SetPoint("TOP", glowChk, "TOP", 0, 0)
	end

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

	reverseChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * (useAuraContainers and 2 or 3), 0)
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

	dispelColoursChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * (useAuraContainers and 3 or 4), 0)
	dispelColoursChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local showTooltipsChk = mini:Checkbox({
		Parent = panel,
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

	-- 12.1 fits every checkbox on one row (no warning-text option there); legacy wraps
	-- tooltips onto a second row.
	if useAuraContainers then
		showTooltipsChk:SetPoint("LEFT", panel, "LEFT", enabledColumnWidth * 4, 0)
		showTooltipsChk:SetPoint("TOP", glowChk, "TOP", 0, 0)
	else
		showTooltipsChk:SetPoint("TOPLEFT", showIconsChk, "BOTTOMLEFT", 0, -verticalSpacing)
	end

	-- On 12.1 the sound plays engine-side via C_UnitAuras.AddAuraSound (registered per healer
	-- and per known CC spell in the module), so the option works on both paths.
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
				PlaySoundFile(sounds:Resolve(options.Sound.File), options.Sound.Channel or "Master")
			end
			config:Apply()
		end,
	})

	soundChk:SetPoint("TOPLEFT", useAuraContainers and showIconsChk or showTooltipsChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local soundFileDropdown, soundFileModernDdl = helpers:BuildMediaDropdown({
		Parent = panel,
		RefreshOn = panel,
		Media = sounds,
		Width = 200,
		GetValue = function()
			return sounds:Normalise(options.Sound.File)
		end,
		SetValue = function(value)
			options.Sound.File = value
			PlaySoundFile(sounds:Resolve(value), options.Sound.Channel or "Master")
			config:Apply()
		end,
	})

	-- Lined up with the checkbox column above it rather than the 4-column grid, and pulled left
	-- on the legacy dropdown, whose frame carries a wide inset before its text starts.
	soundFileDropdown:SetPoint("LEFT", panel, "LEFT",
		enabledColumnWidth + (soundFileModernDdl and 0 or -16), 0)
	soundFileDropdown:SetPoint("TOP", soundChk, "TOP", 0, -4)

	local slidersAnchor = soundChk

	local sliderWidth = (columnWidth * 2) - horizontalSpacing

	local iconSize = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Icon Size"],
		Min = 10,
		Max = 100,
		Default = 50,
		Width = sliderWidth,
		Target = options.Icons,
		Key = "Size",
	})

	iconSize.Slider:SetPoint("TOPLEFT", slidersAnchor, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	if not useAuraContainers then
		local fontSize = mini:Slider({
			Parent = panel,
			Min = 10,
			Max = 100,
			Width = sliderWidth,
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

		fontSize.Slider:SetPoint("LEFT", panel, "LEFT", columnWidth * 2 + 4, 0)
		fontSize.Slider:SetPoint("TOP", iconSize.Slider, "TOP", 0, 0)
	end

	local iconSpacing = helpers:BuildClampedSlider({
		Parent = panel,
		LabelText = L["Icon Padding"],
		Min = 0,
		Max = 20,
		Default = 2,
		Fallback = 2,
		Width = sliderWidth,
		Target = options,
		Key = "IconSpacing",
	})

	-- 12.1 has no Text Size slider, so Icon Padding takes its place beside Icon Size;
	-- legacy keeps it on the next row.
	if useAuraContainers then
		iconSpacing.Slider:SetPoint("LEFT", panel, "LEFT", columnWidth * 2 + 4, 0)
		iconSpacing.Slider:SetPoint("TOP", iconSize.Slider, "TOP", 0, 0)
	else
		iconSpacing.Slider:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)
	end

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end
