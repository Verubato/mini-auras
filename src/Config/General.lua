---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
---@class GeneralConfig
local M = {}

addon.Config.General = M

function M:Build(panel)
	local contentWidth = mini.ContentWidth

	-- "MiniCC" splash title
	local titleFont = GameFontNormalHuge:GetFont()
	local titleText = panel:CreateFontString(nil, "ARTWORK")
	titleText:SetFont(titleFont, 30)
	titleText:SetText("MiniCC")
	titleText:SetTextColor(0.9, 0.2, 0.2, 1)
	titleText:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	titleText:SetWidth(contentWidth)
	titleText:SetJustifyH("CENTER")

	local subtitleText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	subtitleText:SetText(L["Mini addon, massive awareness."])
	subtitleText:SetTextColor(0.7, 0.7, 0.7, 1)
	subtitleText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -6)
	subtitleText:SetWidth(contentWidth)
	subtitleText:SetJustifyH("CENTER")

	local discordBox = mini:EditBox({
		Parent = panel,
		LabelText = L["Discord"],
		GetValue = function()
			return "https://discord.gg/UruPTPHHxK"
		end,
		SetValue = function(_) end,
		Width = contentWidth / 2,
	})

	discordBox.Label:SetPoint("TOP", subtitleText, "BOTTOM", 0, -verticalSpacing * 2)
	discordBox.Label:SetWidth(contentWidth / 2)
	discordBox.Label:SetJustifyH("CENTER")
	discordBox.EditBox:SetPoint("TOP", discordBox.Label, "BOTTOM", 0, -4)

	local newsDivider = mini:Divider({
		Parent = panel,
		Text = L["Important News"],
	})
	newsDivider:SetPoint("TOP", discordBox.EditBox, "BOTTOM", 0, -verticalSpacing * 2)
	newsDivider:SetPoint("LEFT", panel, "LEFT", 0, 0)
	newsDivider:SetWidth(contentWidth)

	local newsFontPath = GameFontNormal:GetFont()
	local newsText = panel:CreateFontString(nil, "ARTWORK")
	newsText:SetFont(newsFontPath, 14)
	newsText:SetTextColor(1, 1, 1, 1)
	newsText:SetWidth(contentWidth - 40)
	newsText:SetJustifyH("LEFT")
	newsText:SetText(L["As of Blizzard's 12.0.7 patch the following features are no longer possible:\n- Display offensives in alerts.\n- Display offensives on nameplates.\n- Display offensives on portraits.\n- Display offensives on party/raid frames.\n- Track offensive cooldowns.\n- Show precog and nullifying shroud.\n- Sound alert for important spells.\n- Text-to-speech of important spells."])
	newsText:SetPoint("TOPLEFT", newsDivider, "BOTTOMLEFT", 0, -verticalSpacing)
end
