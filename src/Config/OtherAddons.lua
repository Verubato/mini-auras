---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
local config = addon.Config

---@class OtherAddonsConfig
local M = {}

config.OtherAddons = M

function M:Build()
	local db = mini:GetSavedVars()
	local horizontalSpacing = mini.HorizontalSpacing

	local panel = CreateFrame("Frame")
	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 0, -verticalSpacing)
	title:SetText("Other Mini Addons")

	local subtitle = mini:TextLine({
		Parent = panel,
		Text = "Other mini addons to enhance your PvP experience:",
	})

	subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)

	local lines = mini:TextBlockSegmented({
		Parent = panel,

		PrefixFont = "GameFontWhite",
		TextFont = "GameFontNormal",
		SuffixFont = "GameFontWhite",

		Lines = {
			{
				Prefix = "",
				Text = "MiniMarkers",
				Suffix = " - shows markers above your team mates.",
			},
			{
				Prefix = "",
				Text = "MiniOvershields",
				Suffix = " - shows overshields on frames and nameplates.",
			},
			{
				Prefix = "",
				Text = "MiniPressRelease",
				Suffix = " - basically doubles your APM.",
			},
			{
				Prefix = "",
				Text = "MiniArenaDebuffs",
				Suffix = " - shows your debuffs on enemy arena frames.",
			},
			{
				Prefix = "",
				Text = "MiniKillingBlow",
				Suffix = " - plays sound effects when getting killing blows.",
			},
			{
				Prefix = "",
				Text = "MiniMeter",
				Suffix = " - shows fps and ping on a draggable UI element.",
			},
			{
				Prefix = "",
				Text = "MiniQueueTimer",
				Suffix = " - shows a draggable timer on your UI when in queue.",
			},
			{
				Prefix = "",
				Text = "MiniTabTarget",
				Suffix = " - changes you tab key to enemy players in PvP, and enemy units in PvE.",
			},
			{
				Prefix = "",
				Text = "MiniCombatNotifier",
				Suffix = " - notifies you when entering/leaving combat.",
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

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)
	testBtn:SetPoint("TOP", title, "TOP", 0, 0)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		local options = db.Modules.CcModule.Default

		addon:ToggleTest(options)
	end)

	return panel
end
