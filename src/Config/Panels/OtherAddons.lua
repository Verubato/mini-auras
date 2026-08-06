---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local config = addon.Config

---@class OtherAddonsConfig
local M = {}

config.OtherAddons = M

local COLS       = 3
local ICON_SIZE   = 40
local CARD_PAD    = 10
local CARD_HEIGHT = 68

local addonName = (select(1, ...))
local ICON_BASE  = "Interface\\AddOns\\" .. addonName .. "\\Icons\\"

local function BuildAddonCard(parent, name, description, cardWidth, icon)
	local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	card:SetSize(cardWidth, CARD_HEIGHT)
	card:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	card:SetBackdropColor(0.08, 0.08, 0.10, 0.6)
	card:SetBackdropBorderColor(0.25, 0.25, 0.30, 0.8)

	local iconTex = card:CreateTexture(nil, "ARTWORK")
	iconTex:SetSize(ICON_SIZE, ICON_SIZE)
	iconTex:SetPoint("LEFT", card, "LEFT", CARD_PAD, 0)
	iconTex:SetTexture(ICON_BASE .. icon)

	local nameLabel = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	nameLabel:SetPoint("LEFT",  iconTex, "RIGHT", CARD_PAD,  8)
	nameLabel:SetPoint("RIGHT", card,    "RIGHT", -CARD_PAD, 0)
	nameLabel:SetJustifyH("LEFT")
	nameLabel:SetText(name)

	local descLabel = card:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	descLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -3)
	descLabel:SetPoint("RIGHT",   card,      "RIGHT", -CARD_PAD, 0)
	descLabel:SetJustifyH("LEFT")
	descLabel:SetText(description)
	descLabel:SetTextColor(0.72, 0.72, 0.72, 1)

	return card
end

local function BuildGrid(panel, anchorFrame, addonDefs, cardWidth)
	local firstInRow, prev

	for i, def in ipairs(addonDefs) do
		local col  = (i - 1) % COLS
		local card = BuildAddonCard(panel, def.Name, L[def.Desc], cardWidth, def.Name)

		if i == 1 then
			card:SetPoint("TOPLEFT", anchorFrame, "BOTTOMLEFT", 0, -verticalSpacing)
			firstInRow = card
		elseif col == 0 then
			card:SetPoint("TOPLEFT", firstInRow, "BOTTOMLEFT", 0, -verticalSpacing)
			firstInRow = card
		else
			card:SetPoint("TOPLEFT", prev, "TOPRIGHT", horizontalSpacing, 0)
		end

		prev = card
	end

	return firstInRow  -- first card of the last row, useful for anchoring below
end

function M:Build(panel)
	local cardWidth = math.floor((mini.ContentWidth - horizontalSpacing * (COLS - 1)) / COLS)

	local subtitle = mini:TextLine({
		Parent = panel,
		Text   = L["My other addons to enhance your gaming experience:"],
	})
	subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local mainAddons = {
		{ Name = "FrameSort",           Desc = "Sorts party/raid/arena frames and places you at the top/middle/bottom."    },
		{ Name = "MiniMarkers",         Desc = "Shows markers above your team mates."                                      },
		{ Name = "MiniOvershields",     Desc = "Shows overshields on frames and nameplates."                               },
		{ Name = "MiniPressRelease",    Desc = "Basically doubles your APM."                                               },
		{ Name = "MiniArenaDebuffs",    Desc = "Shows your debuffs on enemy arena frames."                                 },
		{ Name = "MiniKillingBlow",     Desc = "Plays sound effects when getting killing blows."                           },
		{ Name = "MiniMeter",           Desc = "Shows fps and ping on a draggable UI element."                             },
		{ Name = "MiniQueueTimer",      Desc = "Shows a draggable timer on your UI when in queue."                         },
		{ Name = "MiniTabTarget",       Desc = "Changes your tab key to target enemy players."                             },
		{ Name = "MiniCombatNotifier",  Desc = "Notifies you when entering or leaving combat."                             },
		{ Name = "MiniResourceDisplay", Desc = "Simple personal resource-style health + power bar you can tweak."          },
		{ Name = "MiniFader",           Desc = "Fades out certain frames including bags, micro menu, and quest tracker."   },
	}

	local lastMainRowFirst = BuildGrid(panel, subtitle, mainAddons, cardWidth)

	local url = mini:EditBox({
		Parent   = panel,
		Width    = 400,
		LabelText = "",
		GetValue = function()
			return "https://www.curseforge.com/members/verz/projects"
		end,
		SetValue = function(_) end,
	})
	url.EditBox:SetPoint("TOPLEFT", lastMainRowFirst, "BOTTOMLEFT", 4, -verticalSpacing)

	local styleSubtitle = mini:TextLine({
		Parent = panel,
		Text   = L["Other addons to customize MiniAuras further:"],
	})
	styleSubtitle:SetPoint("TOPLEFT", url.EditBox, "BOTTOMLEFT", -4, -verticalSpacing)

	local styleAddons = {
		{ Name = "MiniCE",  Desc = "Customize the cooldown timers." },
	}

	-- TEMPORARY: Masque cannot skin the 12.1 AuraButtons, so it is only offered on the legacy
	-- path; drop the gate (and the card) with the 12.0 path unless Masque support returns.
	if not addon.Utils.WoWEx:UseAuraContainers() then
		styleAddons[#styleAddons + 1] = { Name = "Masque", Desc = "Powerful icon skinning tool." }
	end

	BuildGrid(panel, styleSubtitle, styleAddons, cardWidth)
end
