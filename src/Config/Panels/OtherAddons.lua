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

local CARD_BG           = { 0.08, 0.08, 0.10, 0.6 }
local CARD_BG_HOVER     = { 0.13, 0.13, 0.17, 0.9 }
local CARD_BORDER       = { 0.25, 0.25, 0.30, 0.8 }
local CARD_BORDER_HOVER = { 0.42, 0.42, 0.50, 1 }

local PROJECTS_URL = "https://verzaddons.com"
local CURSE_BASE = "https://www.curseforge.com/wow/addons/"

local addonName = (select(1, ...))
local ICON_BASE  = "Interface\\AddOns\\" .. addonName .. "\\Icons\\Addons\\"

local function BuildAddonCard(parent, def, cardWidth, onClick)
	local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	card:SetSize(cardWidth, CARD_HEIGHT)
	card:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	card:SetBackdropColor(unpack(CARD_BG))
	card:SetBackdropBorderColor(unpack(CARD_BORDER))

	local iconTex = card:CreateTexture(nil, "ARTWORK")
	iconTex:SetSize(ICON_SIZE, ICON_SIZE)
	iconTex:SetPoint("LEFT", card, "LEFT", CARD_PAD, 0)
	iconTex:SetTexture(ICON_BASE .. def.Name)

	local nameLabel = card:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	nameLabel:SetPoint("LEFT",  iconTex, "RIGHT", CARD_PAD,  8)
	nameLabel:SetPoint("RIGHT", card,    "RIGHT", -CARD_PAD, 0)
	nameLabel:SetJustifyH("LEFT")
	nameLabel:SetText(def.Name)

	local descLabel = card:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	descLabel:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 0, -3)
	descLabel:SetPoint("RIGHT",   card,      "RIGHT", -CARD_PAD, 0)
	descLabel:SetJustifyH("LEFT")
	descLabel:SetText(L[def.Desc])
	descLabel:SetTextColor(0.72, 0.72, 0.72, 1)

	-- Most cards link to a CurseForge project named after the addon; third-party projects
	-- (MiniCE) carry an explicit Url where the slug differs.
	local url = def.Url or (CURSE_BASE .. def.Name:lower())

	card:EnableMouse(true)
	card:SetScript("OnEnter", function()
		card:SetBackdropColor(unpack(CARD_BG_HOVER))
		card:SetBackdropBorderColor(unpack(CARD_BORDER_HOVER))
	end)
	card:SetScript("OnLeave", function()
		card:SetBackdropColor(unpack(CARD_BG))
		card:SetBackdropBorderColor(unpack(CARD_BORDER))
	end)
	card:SetScript("OnMouseUp", function()
		onClick(url)
	end)

	return card
end

local function BuildGrid(panel, anchorFrame, addonDefs, cardWidth, onClick)
	local firstInRow, prev

	for i, def in ipairs(addonDefs) do
		local col  = (i - 1) % COLS
		local card = BuildAddonCard(panel, def, cardWidth, onClick)

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

	-- The box shows the last clicked card's link (the addon hub by default). Focusing and
	-- highlighting it is the closest WoW gets to a clipboard copy: the user hits Ctrl+C.
	local currentUrl = PROJECTS_URL
	local url

	local function ShowUrl(link)
		currentUrl = link
		url.EditBox:MiniRefresh()
		url.EditBox:SetFocus()
		url.EditBox:HighlightText()
	end

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

	local lastMainRowFirst = BuildGrid(panel, subtitle, mainAddons, cardWidth, ShowUrl)

	url = mini:EditBox({
		Parent   = panel,
		Width    = 400,
		LabelText = "",
		GetValue = function()
			return currentUrl
		end,
		SetValue = function(_) end,
	})
	-- The styled field draws 6px outside the box's own left edge; anchor inside that so it
	-- lines up with the cards instead of clipping at the panel edge.
	url.EditBox:SetPoint("TOPLEFT", lastMainRowFirst, "BOTTOMLEFT", 6, -verticalSpacing)

	-- TEMPORARY: neither styling addon works with the 12.1 AuraButtons (Masque cannot skin
	-- them, MiniCE cannot restyle their countdown text), so the whole section is only offered
	-- on the legacy path; drop the gate with the 12.0 path unless support returns.
	if not addon.Utils.WoWEx:UseAuraContainers() then
		local styleSubtitle = mini:TextLine({
			Parent = panel,
			Text   = L["Other addons to customize MiniAuras further:"],
		})
		styleSubtitle:SetPoint("TOPLEFT", url.EditBox, "BOTTOMLEFT", -6, -verticalSpacing)

		local styleAddons = {
			{ Name = "MiniCE", Desc = "Customize the cooldown timers.", Url = CURSE_BASE .. "minice-cooldown-styler" },
			{ Name = "Masque", Desc = "Powerful icon skinning tool." },
		}

		BuildGrid(panel, styleSubtitle, styleAddons, cardWidth, ShowUrl)
	end
end
