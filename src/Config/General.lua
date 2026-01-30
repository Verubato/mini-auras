---@type string, Addon
local _, addon = ...
local mini = addon.Framework
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
			"  - Hex and roots.",
			"",
			"Any feedback is more than welcome!",
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
end
