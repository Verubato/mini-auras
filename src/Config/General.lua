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
			"Limitations (due to Midnight):",
			"  - Can only show 1 CC; overlapping CC's will show the longest duration CC.",
			"  - Can't play a sound when CC applied (have requested this from Blizzard, stay tuned).",
			"  - Can't specify which spells are considered CC, as this is controlled by Blizzard.",
			"  - e.g. Hex currently isn't considered CC and I've forwarded this to Blizzard so hopefully they fix it.",
			"",
			"Any feedback is more than welcome!",
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
end
