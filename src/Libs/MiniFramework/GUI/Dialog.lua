local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L
local dialog

local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local function GetOrCreateDialog()
	if dialog then
		return dialog
	end

	dialog = CreateFrame("Frame", nil, UIParent, GUI.BackdropTemplate)
	dialog:SetSize(360, 140)
	dialog:SetFrameStrata("DIALOG")
	dialog:SetClampedToScreen(true)
	dialog:SetMovable(true)
	dialog:EnableMouse(true)
	dialog:RegisterForDrag("LeftButton")
	dialog:SetScript("OnDragStart", dialog.StartMoving)
	dialog:SetScript("OnDragStop", dialog.StopMovingOrSizing)
	dialog:Hide()

	GUI.ApplyBackdrop(dialog, BACKDROP, 0, 0, 0, 0.9)

	dialog.Title = dialog:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	dialog.Title:SetPoint("TOP", dialog, "TOP", 0, -8)
	dialog.Title:SetText(L["Notification"])
	dialog.Title:SetTextColor(1, 0.82, 0)

	dialog.TitleDivider = dialog:CreateTexture(nil, "ARTWORK")
	dialog.TitleDivider:SetHeight(1)
	dialog.TitleDivider:SetPoint("TOPLEFT", dialog, "TOPLEFT", 8, -28)
	dialog.TitleDivider:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -8, -28)
	GUI.SetSolid(dialog.TitleDivider, 1, 1, 1, 0.15)

	dialog.Text = dialog:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	dialog.Text:SetPoint("TOPLEFT", 12, -40)
	dialog.Text:SetPoint("TOPRIGHT", -12, -40)
	dialog.Text:SetJustifyH("LEFT")
	dialog.Text:SetJustifyV("TOP")

	dialog.CloseButton = M:Button({
		Parent = dialog,
		Text = CLOSE,
		Width = 80,
		OnClick = function()
			dialog:Hide()
		end,
	})
	dialog.CloseButton:SetPoint("BOTTOM", 0, 12)

	return dialog
end

---Shows the shared notification dialog, sized to fit the message.
---@param options DialogOptions
function M:ShowDialog(options)
	if not options then
		error("ShowDialog - options must not be nil.")
	end

	if not options.Text then
		error("ShowDialog - invalid options.")
	end

	local dlg = GetOrCreateDialog()

	-- Width must be known first
	local width = options.Width or 360
	dlg:SetWidth(width)

	dlg.Title:SetText(options.Title or L["Notification"])
	dlg.Text:SetWidth(width - 40)
	dlg.Text:SetText(options.Text)
	dlg.Text:SetWordWrap(true)

	local textHeight = dlg.Text:GetStringHeight()
	local paddingTop = 70
	local paddingBottom = 40

	dlg:SetHeight(textHeight + paddingTop + paddingBottom)
	dlg:ClearAllPoints()
	dlg:SetPoint("CENTER", UIParent, "CENTER")
	dlg:Show()
end

---Hides the shared notification dialog, if one has been created.
function M:HideDialog()
	if dialog then
		dialog:Hide()
	end
end

---@class DialogOptions
---@field Title string?
---@field Text string
---@field Width number?
