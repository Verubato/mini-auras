---@type string, Addon
local _, addon = ...
local mini = addon.Framework
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

	-- News sits directly under the title (first content block) inside a crimson callout card,
	-- so it reads as a warning rather than body text; Discord moves below it.
	local newsDivider = mini:Divider({
		Parent = panel,
		Text = L["Important News"],
	})
	newsDivider:SetPoint("TOP", subtitleText, "BOTTOM", 0, -verticalSpacing * 2)
	newsDivider:SetPoint("LEFT", panel, "LEFT", 0, 0)
	newsDivider:SetWidth(contentWidth)

	local newsCard = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	newsCard:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	newsCard:SetBackdropColor(0.78, 0.20, 0.24, 0.07)
	newsCard:SetBackdropBorderColor(0.78, 0.20, 0.24, 0.35)
	newsCard:SetPoint("TOPLEFT", newsDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	newsCard:SetPoint("TOPRIGHT", newsDivider, "BOTTOMRIGHT", 0, -verticalSpacing)

	-- Accent stripe down the card's left edge (the standard callout cue).
	local newsStripe = newsCard:CreateTexture(nil, "BORDER")
	newsStripe:SetWidth(3)
	newsStripe:SetPoint("TOPLEFT", newsCard, "TOPLEFT", 1, -1)
	newsStripe:SetPoint("BOTTOMLEFT", newsCard, "BOTTOMLEFT", 1, 1)
	newsStripe:SetColorTexture(0.78, 0.20, 0.24, 0.9)

	local newsPadding = 14
	local newsFontPath = GameFontNormal:GetFont()
	local newsText = newsCard:CreateFontString(nil, "ARTWORK")
	newsText:SetFont(newsFontPath, 14)
	newsText:SetTextColor(1, 1, 1, 1)
	newsText:SetWidth(contentWidth - newsPadding * 2 - 3)
	newsText:SetJustifyH("LEFT")
	newsText:SetSpacing(3)
	-- TEMPORARY dual path: drop the 12.0.7 message with the legacy path once 12.1 is live.
	if addon.Utils.WoWEx:UseAuraContainers() then
		newsText:SetText(L["In Blizzard's 12.1 patch, addons can no longer read any aura information. The following features are not possible in 12.1 and have been removed:\n- Cooldown tracking (friendly and enemy).\n- The warning text when the healer is CC'd.\n- Text-to-speech announcements.\n- Class colours on alert icons.\n- Glow type selection (icons always use the built-in glow).\n- Masque icon skinning."])
	else
		newsText:SetText(L["Some good news:\n- A workaround has been implemented to show important auras again for nameplates/portraits/alerts."])
	end
	newsText:SetPoint("TOPLEFT", newsCard, "TOPLEFT", newsPadding + 3, -newsPadding)
	newsCard:SetHeight(newsText:GetStringHeight() + newsPadding * 2)

	local discordBox = mini:EditBox({
		Parent = panel,
		LabelText = L["Discord"],
		GetValue = function()
			return "https://discord.gg/UruPTPHHxK"
		end,
		SetValue = function(_) end,
		Width = contentWidth / 2,
	})

	discordBox.Label:SetPoint("TOP", newsCard, "BOTTOM", 0, -verticalSpacing * 2)
	discordBox.Label:SetWidth(contentWidth / 2)
	discordBox.Label:SetJustifyH("CENTER")
	discordBox.EditBox:SetPoint("TOP", discordBox.Label, "BOTTOM", 0, -4)
end
