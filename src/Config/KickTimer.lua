---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config

---@class KickTimerConfig
local M = {}

config.KickTimer = M

function M:Build()
	local db = mini:GetSavedVars()
	local columns = 3
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	local horizontalSpacing = mini.HorizontalSpacing

	local panel = CreateFrame("Frame")
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 0, -verticalSpacing)
	title:SetText("Kick timer")

	local text = mini:TextLine({
		Parent = panel,
		Text = "Enable if you are:",
	})

	text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -verticalSpacing)

	local healerEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = "Healer",
		Tooltip = "Whether to enable or disable this module if you are a healer.",
		GetValue = function()
			return db.KickTimer.HealerEnabled
		end,
		SetValue = function(value)
			db.KickTimer.HealerEnabled = value
			config:Apply()
		end,
	})

	healerEnabled:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -verticalSpacing)

	local casterEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = "Caster",
		Tooltip = "Whether to enable or disable this module if you are a caster.",
		GetValue = function()
			return db.KickTimer.CasterEnabled
		end,
		SetValue = function(value)
			db.KickTimer.CasterEnabled = value
			config:Apply()
		end,
	})

	casterEnabled:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	casterEnabled:SetPoint("TOP", healerEnabled, "TOP", 0, o)

	local allEnabled = mini:Checkbox({
		Parent = panel,
		LabelText = "Any",
		Tooltip = "Whether to enable or disable this module regardless of what spec you are.",
		GetValue = function()
			return db.KickTimer.AllEnabled
		end,
		SetValue = function(value)
			db.KickTimer.AllEnabled = value
			config:Apply()
		end,
	})

	allEnabled:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	allEnabled:SetPoint("TOP", healerEnabled, "TOP", 0, 0)

	local iconSizeSlider = mini:Slider({
		Parent = panel,
		LabelText = "Icon Size",
		GetValue = function()
			return db.KickTimer.Icons.Size
		end,
		SetValue = function(value)
			db.KickTimer.Icons.Size = mini:ClampInt(value, 20, 120, 50)
			config:Apply()
		end,
		Width = columns * columnWidth - horizontalSpacing,
		Min = 20,
		Max = 120,
		Step = 1,
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", healerEnabled, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"It's not great, it's not even good, but it's better than nothing.",
			"Only works if you or your team mates actually get interrupted.",
			"",
			"Limitations:",
			" - Doesn't know the real cooldown of the enemy's kick.",
			" - Doesn't work if the enemy misses kick.",
			"",
			"It guesses the kick cooldown based on the enemy specs during arena prep.",
			"For example if you are facing mage/lock/druid, then it knows the kick cooldown is 24 seconds.",
			"But if you are facing RMP, then it has to use the rogue kick cooldown of 15 seconds.",
			"It doesn't know whether the rogue or mage kicked you, so if no kicks are on cooldown then it has to assume the worst case scenario and choose the rogue's cooldown.",
			"If both kicks get used, then it could know that one cooldown is 15 seconds and the other one is 24 seconds but I haven't coded in this logic yet.",
			"",
			"Honestly I don't even know if it's worth having this in the addon, let me know your thoughts.",
		},
	})

	lines:SetPoint("TOPLEFT", iconSizeSlider.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)
	testBtn:SetPoint("TOP", title, "TOP", 0, 0)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		local options = db.Default

		addon:ToggleTest(options)
	end)

	return panel
end
