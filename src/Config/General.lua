---@type string, Addon
local _, addon = ...
local mini = addon.Framework
---@class GeneralConfig
local M = {}

addon.Config.General = M

function M:Build(panel)
	-- mini:TextBlock({
	-- 	Parent = panel,
	-- 	Lines = {
	-- 		"Limitations (due to Midnight) are:",
	-- 		"  - Can only show 1 CC, overlapping CC's will show the longest duration CC.",
	-- 		"  - Can't play a sound when CC applied (have requested this from Blizzard, stay tuned.)",
	-- 	}
	-- })
	--
end
