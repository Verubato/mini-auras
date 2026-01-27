---@type string, Addon
local _, addon = ...
local mini = addon.Framework
---@class GeneralConfig
local M = {}

addon.Config.General = M

function M:Build(panel)
	local columns = 3
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
	---@type Db
	local db = mini:GetSavedVars()

	local glowChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Glow icons",
		GetValue = function()
			return db.Icons.Glow
		end,
		SetValue = function(value)
			db.Icons.Glow = value
			addon:Refresh()
		end,
	})

	glowChk:SetPoint("TOPLEFT", panel, "TOPLEFT", -4, 0)

	local arenaOnlyChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Arena only",
		GetValue = function()
			return db.ArenaOnly
		end,
		SetValue = function(value)
			db.ArenaOnly = value
			addon:Refresh()
		end,
	})

	arenaOnlyChk:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	arenaOnlyChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local excludePlayerChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Exclude player",
		GetValue = function()
			return db.ExcludePlayer
		end,
		SetValue = function(value)
			db.ExcludePlayer = value
			addon:Refresh()
		end,
	})

	excludePlayerChk:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	excludePlayerChk:SetPoint("TOP", arenaOnlyChk, "TOP", 0, 0)
end
