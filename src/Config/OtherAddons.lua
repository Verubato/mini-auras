---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config

---@class OtherAddonsConfig
local M = {}

config.OtherAddons = M

function M:Build(panel)
	local db = mini:GetSavedVars()
	local horizontalSpacing = mini.HorizontalSpacing
	local subtitle = mini:TextLine({
		Parent = panel,
		Text = L["Other mini addons to enhance your PvP experience:"],
	})

	subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local lines = mini:TextBlockSegmented({
		Parent = panel,

		PrefixFont = "GameFontWhite",
		TextFont = "GameFontNormal",
		SuffixFont = "GameFontWhite",

		Lines = {
			{
				Prefix = "",
				Text = L["MiniMarkers"],
				Suffix = L[" - shows markers above your team mates."],
			},
			{
				Prefix = "",
				Text = L["MiniOvershields"],
				Suffix = L[" - shows overshields on frames and nameplates."],
			},
			{
				Prefix = "",
				Text = L["MiniPressRelease"],
				Suffix = L[" - basically doubles your APM."],
			},
			{
				Prefix = "",
				Text = L["MiniArenaDebuffs"],
				Suffix = L[" - shows your debuffs on enemy arena frames."],
			},
			{
				Prefix = "",
				Text = L["MiniKillingBlow"],
				Suffix = L[" - plays sound effects when getting killing blows."],
			},
			{
				Prefix = "",
				Text = L["MiniMeter"],
				Suffix = L[" - shows fps and ping on a draggable UI element."],
			},
			{
				Prefix = "",
				Text = L["MiniQueueTimer"],
				Suffix = L[" - shows a draggable timer on your UI when in queue."],
			},
			{
				Prefix = "",
				Text = L["MiniTabTarget"],
				Suffix = L[" - changes you tab key to enemy players in PvP, and enemy units in PvE."],
			},
			{
				Prefix = "",
				Text = L["MiniCombatNotifier"],
				Suffix = L[" - notifies you when entering/leaving combat."],
			},
		},
	})

	lines:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -verticalSpacing)

	local url = mini:EditBox({
		Parent = panel,
		Width = 400,
		LabelText = "",
		GetValue = function()
			return "https://www.curseforge.com/members/verz/projects"
		end,
		SetValue = function(_) end,
	})

	url.EditBox:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 4, -verticalSpacing)

end
