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

local urlWindow

---Shows the small copy popup for a card's link: the box is focused with the link highlighted, so
---Ctrl+C is the only step left. WoW has no clipboard API to copy directly.
local function ShowUrlPopup(name, url)
	if not urlWindow then
		local win = CreateFrame("Frame", addonName .. "AddonUrlWindow", UIParent, "BackdropTemplate")
		win:SetSize(460, 116)
		win:SetFrameStrata("FULLSCREEN_DIALOG")
		win:SetClampedToScreen(true)
		win:EnableMouse(true)
		win:Hide()
		win:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 16,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
		win:SetBackdropColor(0, 0, 0, 0.9)

		local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
		title:SetPoint("TOP", win, "TOP", 0, -12)
		title:SetTextColor(1, 0.82, 0)

		local box = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
		mini:FlattenEditBox(box)
		box:SetHeight(28)
		box:SetWidth(460 - 32)
		box:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -42)
		box:SetAutoFocus(false)
		-- Copy-only: any edit snaps the text back to the link, so Ctrl+C always grabs the
		-- real thing no matter what was typed over it.
		box:SetScript("OnTextChanged", function(boxSelf, userInput)
			if userInput then
				boxSelf:SetText(win.Url or "")
				boxSelf:HighlightText()
			end
		end)
		box:SetScript("OnEditFocusGained", function(boxSelf)
			boxSelf:HighlightText()
		end)
		box:SetScript("OnEscapePressed", function()
			win:Hide()
		end)
		box:SetScript("OnEnterPressed", function()
			win:Hide()
		end)

		local closeBtn = mini:Button({
			Parent = win,
			Text = CLOSE,
			Width = 80,
			OnClick = function()
				win:Hide()
			end,
		})
		closeBtn:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, -10)

		win.Title = title
		win.Box = box
		urlWindow = win
	end

	urlWindow.Title:SetText(name)
	urlWindow.Url = url
	urlWindow.Box:SetText(url)
	urlWindow:ClearAllPoints()
	urlWindow:SetPoint("CENTER", UIParent, "CENTER")
	urlWindow:Show()
	urlWindow.Box:SetFocus()
end

local function BuildAddonCard(parent, def, cardWidth)
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

	-- Cards link to a CurseForge project named after the addon; a card whose slug differs can
	-- carry an explicit Url instead.
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
		ShowUrlPopup(def.Name, url)
	end)

	return card
end

local function BuildGrid(panel, anchorFrame, addonDefs, cardWidth)
	local firstInRow, prev

	for i, def in ipairs(addonDefs) do
		local col  = (i - 1) % COLS
		local card = BuildAddonCard(panel, def, cardWidth)

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
			return PROJECTS_URL
		end,
		SetValue = function(_) end,
	})
	-- The styled field draws 6px outside the box's own left edge; anchor inside that so it
	-- lines up with the cards instead of clipping at the panel edge.
	url.EditBox:SetPoint("TOPLEFT", lastMainRowFirst, "BOTTOMLEFT", 6, -verticalSpacing)

	local styleSubtitle = mini:TextLine({
		Parent = panel,
		Text   = L["Other addons to customize MiniAuras further:"],
	})
	styleSubtitle:SetPoint("TOPLEFT", url.EditBox, "BOTTOMLEFT", -6, -verticalSpacing)

	local styleAddons = {
		{ Name = "Masque", Desc = "Powerful icon skinning tool." },
	}

	BuildGrid(panel, styleSubtitle, styleAddons, cardWidth)
end
