local addonName, addon = ...
local M = addon.Framework
local GUI = M.GUI

local CONTENT_WIDTH = 460
local CONTENT_HEIGHT = 200
local CONTENT_TOP_OFFSET = -90
local TEXT_WIDTH = 400
local RULE_HALF_WIDTH = 110
local TITLE_SIZE = 32
local BUTTON_WIDTH = 240
local BUTTON_HEIGHT = 32

---Rescales a font string, keeping the font object's face and flags. A fetched path carries no
---per-locale glyph fallbacks, so this is only safe for the wordmark, which is the addon name.
local function SetFontSize(fontString, size)
	local path, _, flags = fontString:GetFont()

	if path then
		fontString:SetFont(path, size, flags)
	end
end

---Builds the centred splash under Interface > AddOns, pointing at the addon's own window.
---@param options RedirectPanelOptions
---@return RedirectPanelReturn
function M:RedirectPanel(options)
	if not options then
		error("RedirectPanel - options must not be nil.")
	end

	if not options.Parent then
		error("RedirectPanel - invalid options.")
	end

	local accent = GUI.TitleText
	local parent = options.Parent

	local content = CreateFrame("Frame", nil, parent)
	content:SetSize(CONTENT_WIDTH, CONTENT_HEIGHT)
	content:SetPoint("TOP", parent, "TOP", 0, CONTENT_TOP_OFFSET)

	local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
	title:SetPoint("TOP", content, "TOP", 0, 0)
	title:SetText(options.Title or addonName)
	title:SetTextColor(accent.r, accent.g, accent.b, 1)
	SetFontSize(title, TITLE_SIZE)

	local versionLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	versionLabel:SetPoint("TOP", title, "BOTTOM", 0, -4)
	versionLabel:SetText(options.Version or M:AddonVersion())
	versionLabel:SetTextColor(0.62, 0.60, 0.58, 1)

	-- Thin rule under the wordmark, brightest in the middle and fading out at both ends.
	-- Two halves because a single texture can only gradient in one direction. Alpha is baked
	-- into the gradient colours, since SetGradient replaces vertex alpha and SetAlpha cannot dim it.
	local ruleLeft = content:CreateTexture(nil, "ARTWORK")
	ruleLeft:SetSize(RULE_HALF_WIDTH, 1)
	ruleLeft:SetPoint("TOPRIGHT", versionLabel, "BOTTOM", 0, -14)
	ruleLeft:SetColorTexture(1, 1, 1, 1)
	ruleLeft:SetGradient("HORIZONTAL",
		CreateColor(accent.r, accent.g, accent.b, 0),
		CreateColor(accent.r, accent.g, accent.b, 0.7))

	local ruleRight = content:CreateTexture(nil, "ARTWORK")
	ruleRight:SetSize(RULE_HALF_WIDTH, 1)
	ruleRight:SetPoint("TOPLEFT", versionLabel, "BOTTOM", 0, -14)
	ruleRight:SetColorTexture(1, 1, 1, 1)
	ruleRight:SetGradient("HORIZONTAL",
		CreateColor(accent.r, accent.g, accent.b, 0.7),
		CreateColor(accent.r, accent.g, accent.b, 0))

	local message = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	-- BOTTOMLEFT of the right half is where the two rules join, i.e. the horizontal centre.
	message:SetPoint("TOP", ruleRight, "BOTTOMLEFT", 0, -18)
	message:SetWidth(TEXT_WIDTH)
	message:SetJustifyH("CENTER")
	message:SetText(options.Message or "")

	-- An accent-outline button clashes with the Blizzard settings screen around it.
	local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
	button:SetPoint("TOP", message, "BOTTOM", 0, -20)
	button:SetText(options.ButtonText or "")
	-- GameFontNormalMed3 is 14pt.
	-- A raw SetFont path drops the per-locale glyph fallbacks and boxes Cyrillic text.
	button:SetNormalFontObject(GameFontNormalMed3)
	button:SetHighlightFontObject(GameFontHighlightMedium)

	if options.OnClick then
		button:SetScript("OnClick", options.OnClick)
	end

	return {
		Content = content,
		Title = title,
		Version = versionLabel,
		Message = message,
		Button = button,
		Anchor = button,
	}
end

---@class RedirectPanelOptions
---@field Parent table the frame registered with AddCategory
---@field Title string? the wordmark, defaults to the addon name. Resized by path, so keep it Latin
---@field Version string? defaults to the version from the toc
---@field Message string? the centred line above the button, already localised
---@field ButtonText string? the button's label, already localised
---@field OnClick fun()?

---@class RedirectPanelReturn
---@field Content table the centred frame everything else sits in
---@field Title table
---@field Version table
---@field Message table
---@field Button table
---@field Anchor table the region to anchor anything extra beneath
