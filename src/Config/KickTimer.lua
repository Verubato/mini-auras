---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config

---@class KickTimerConfig
local M = {}

config.KickTimer = M

function M:Build()
	local db = mini:GetSavedVars()
	local panel = CreateFrame("Frame")
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 0, -verticalSpacing)
	title:SetText("Kick timer")

	local enabled = mini:Checkbox({
		Parent = panel,
		LabelText = "Enabled",
		Tooltip = "Whether to enable or disable this module.",
		GetValue = function()
			return db.KickTimer.Enabled
		end,
		SetValue = function(value)
			db.KickTimer.Enabled = value
			config:Apply()
		end,
	})

	enabled:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -verticalSpacing)

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
		},
	})

	lines:SetPoint("TOPLEFT", enabled, "BOTTOMLEFT", 0, -verticalSpacing)

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
		Min = 20,
		Max = 120,
		Step = 1,
	})

	iconSizeSlider.Slider:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	return panel
end
