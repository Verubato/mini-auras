---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local verticalSpacing = mini.VerticalSpacing
---@type Db
local db
---@class GeneralConfig
local M = {}

addon.Config.General = M

function M:Build(panel)
	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"Supported addons:",
			"  - ElvUI, DandersFrames, Grid2.",
			"",
			"Things that work on beta (12.0.1) that don't work on retail (12.0.0):",
			"  - Showing multiple/overlapping CC's.",
			"  - Healer in CC sound effect.",
			"  - More spells are shown on portraits.",
			"  - Hex and roots.",
			"",
			"Any feedback is more than welcome!",
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	db = mini:GetSavedVars()

	local portraitsChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Portrait icons",
		Tooltip = "Shows CC, defensives, and other important spells on the player/target/focus portraits.",
		GetValue = function()
			return db.Portrait.Enabled
		end,
		SetValue = function(value)
			db.Portrait.Enabled = value
			addon.Config:Apply()
		end,
	})

	portraitsChk:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing)
end
