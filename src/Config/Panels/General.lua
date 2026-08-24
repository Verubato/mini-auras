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

	local titleFont = GameFontNormalHuge:GetFont()
	local titleText = panel:CreateFontString(nil, "ARTWORK")
	titleText:SetFont(titleFont, 30)
	titleText:SetText("MiniAuras")
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

	-- The name carries its own dark-orange colour escape inside the localized string, so
	-- translations can place it wherever their word order needs.
	local creditText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	creditText:SetText(L["By |cffff8c00Verz|r"])
	creditText:SetTextColor(0.55, 0.52, 0.48, 1)
	creditText:SetPoint("TOPLEFT", subtitleText, "BOTTOMLEFT", 0, -4)
	creditText:SetWidth(contentWidth)
	creditText:SetJustifyH("CENTER")

	-- News sits directly under the title inside a crimson callout card, so it reads as a warning
	-- rather than body text.
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

	-- Accent stripe down the card's left edge, the standard callout cue.
	local newsStripe = newsCard:CreateTexture(nil, "BORDER")
	newsStripe:SetWidth(3)
	newsStripe:SetPoint("TOPLEFT", newsCard, "TOPLEFT", 1, -1)
	newsStripe:SetPoint("BOTTOMLEFT", newsCard, "BOTTOMLEFT", 1, 1)
	newsStripe:SetColorTexture(0.78, 0.20, 0.24, 0.9)

	local newsPadding = 14
	local newsSpacing = 3
	-- A 14pt font object rather than SetFont with a raw file path: the path drops
	-- Blizzard's per-locale glyph fallbacks and Cyrillic renders as boxes.
	local newsText = newsCard:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
	newsText:SetTextColor(1, 1, 1, 1)
	newsText:SetWidth(contentWidth - newsPadding * 2 - 3)
	newsText:SetJustifyH("LEFT")
	newsText:SetSpacing(newsSpacing)
	newsText:SetText(L["In Blizzard's 12.1 patch, addons can no longer process aura information; only display it.\n\nWhat's removed:\n* Friendly and enemy cooldown tracking (not possible in 12.1).\n\nWhat's added/changed:\n* New personal auras functionality (think mini weak auras).\n  - When aura added show icon and play sound.\n  - Precognition & Nullifying Shroud module have been merged into this.\n* Ally kick tracker for dungeons/M+.\n* Wider range of spells on raid frames, e.g. Darkness, Spirit Link, Dark Pact, etc.\n* New custom text-to-speech voices.\n* Masque skins are applied when an icon is created, so reload after changing one.\n* UI overhaul so it looks sexier."])
	newsText:SetPoint("TOPLEFT", newsCard, "TOPLEFT", newsPadding + 3, -newsPadding)
	-- GetStringHeight leaves out the SetSpacing gaps, so wordy locales spill past the card.
	newsCard:SetHeight(newsText:GetStringHeight() + (newsText:GetNumLines() - 1) * newsSpacing + newsPadding * 2)

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
