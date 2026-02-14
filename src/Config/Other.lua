---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
---@type Db
local db
---@class OtherConfig
local M = {}

addon.Config.Other = M

function M:Build(panel)
	local columns = 4
	local columnStep = mini:ColumnWidth(columns, 0, 0)

	db = mini:GetSavedVars()

	local portraitDivider = mini:Divider({
		Parent = panel,
		Text = "Portrait Icons",
	})

	portraitDivider:SetPoint("LEFT", panel, "LEFT")
	portraitDivider:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)
	portraitDivider:SetPoint("TOP", panel, "TOP", 0, 0)

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

	portraitsChk:SetPoint("TOPLEFT", portraitDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local reverseSweepChk = mini:Checkbox({
		Parent = panel,
		LabelText = "Reverse swipe",
		Tooltip = "Reverses the direction of the cooldown swipe.",
		GetValue = function()
			return db.Portrait.ReverseCooldown
		end,
		SetValue = function(value)
			db.Portrait.ReverseCooldown = value
			addon.Config:Apply()
		end,
	})

	reverseSweepChk:SetPoint("LEFT", panel, "LEFT", columnStep, -verticalSpacing)
	reverseSweepChk:SetPoint("TOP", portraitsChk, "TOP", 0, 0)
end
