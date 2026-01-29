---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
local config = addon.Config

---@class HealerConfig
local M = {}

config.Healer = M

---@param panel table
---@param options HealerOptions
function M:Build(panel, options)
	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"A separate region for when you're healer is CC'd.",
		}
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

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

	enabledChk:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing)

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

	glowChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
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

	reverseChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local arenaChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Arena",
		GetValue = function()
			return options.Filters.Arena
		end,
		SetValue = function(value)
			options.Filters.Arena = value
			config:Apply()
		end,
	})

	arenaChk:SetPoint("TOPLEFT", enabledChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local battlegroudsChk = mini:Checkbox({
		Parent = panel,
		LabelText = "BattleGrounds",
		GetValue = function()
			return options.Filters.BattleGrounds
		end,
		SetValue = function(value)
			options.Filters.BattleGrounds = value
			config:Apply()
		end,
	})

	battlegroudsChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	battlegroudsChk:SetPoint("TOP", arenaChk, "TOP", 0, 0)

	local worldChk = mini:Checkbox({
		Parent = panel,
		LabelText = "World",
		GetValue = function()
			return options.Filters.World
		end,
		SetValue = function(value)
			options.Filters.World = value
			config:Apply()
		end,
	})

	worldChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	worldChk:SetPoint("TOP", arenaChk, "TOP", 0, 0)

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

	iconSize.Slider:SetPoint("TOPLEFT", arenaChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

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
			options.Font.Size = mini:ClampInt(v, 10, 100, 32)
			config:Apply()
		end,
	})

	fontSize.Slider:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("TOPLEFT", fontSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		local db = mini:GetSavedVars()
		addon:ToggleTest(db.Default)
	end)

	panel:HookScript("OnShow", function()
		panel:MiniRefresh()
	end)
end
