local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L
local dialog
local confirm

local BACKDROP = {
	bgFile = "Interface\Tooltips\UI-Tooltip-Background",
	edgeFile = "Interface\Tooltips\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

---The chrome both dialogs share: a draggable dark panel with a gold title over a rule, and a
---wrapping message below it. The caller adds its own buttons.
local function BuildDialogFrame(width, height)
	local frame = CreateFrame("Frame", nil, UIParent, GUI.BackdropTemplate)
	frame:SetSize(width, height)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:Hide()

	GUI.ApplyBackdrop(frame, BACKDROP, 0, 0, 0, 0.9)

	frame.Title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	frame.Title:SetPoint("TOP", frame, "TOP", 0, -8)
	frame.Title:SetTextColor(1, 0.82, 0)

	frame.TitleDivider = frame:CreateTexture(nil, "ARTWORK")
	frame.TitleDivider:SetHeight(1)
	frame.TitleDivider:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -28)
	frame.TitleDivider:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -28)
	GUI.SetSolid(frame.TitleDivider, 1, 1, 1, 0.15)

	frame.Text = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightLarge")
	frame.Text:SetPoint("TOPLEFT", 12, -40)
	frame.Text:SetPoint("TOPRIGHT", -12, -40)
	frame.Text:SetJustifyH("LEFT")
	frame.Text:SetJustifyV("TOP")

	return frame
end

local function GetOrCreateDialog()
	if dialog then
		return dialog
	end

	dialog = BuildDialogFrame(360, 140)
	dialog.Title:SetText(L["Notification"])

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

local function GetOrCreateConfirm()
	if confirm then
		return confirm
	end

	confirm = BuildDialogFrame(380, 150)

	confirm.AcceptButton = M:Button({
		Parent = confirm,
		Width = 110,
		-- The dialog is chrome with no Blizzard equivalent, so it stays styled even in the addons
		-- that hold stock art for the buttons on their settings panel.
		CustomStyling = true,
		Danger = true,
		OnClick = function()
			local accept = confirm.OnAccept

			confirm:Hide()

			if accept then
				accept()
			end
		end,
	})
	confirm.AcceptButton:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -6, 12)

	confirm.CancelButton = M:Button({
		Parent = confirm,
		Text = CANCEL or L["Cancel"],
		Width = 110,
		CustomStyling = true,
		OnClick = function()
			confirm:Hide()
		end,
	})
	confirm.CancelButton:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", 6, 12)

	return confirm
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

---Asks the user to confirm before something irreversible happens. The dialog closes before
---OnAccept runs, so the callback is free to open a window of its own.
---@param options ConfirmOptions
function M:ShowConfirm(options)
	if not options then
		error("ShowConfirm - options must not be nil.")
	end

	if not options.Text or not options.OnAccept then
		error("ShowConfirm - invalid options.")
	end

	local dlg = GetOrCreateConfirm()

	local width = options.Width or 380
	dlg:SetWidth(width)

	dlg.Title:SetText(options.Title or L["Confirm"])
	dlg.Text:SetText(options.Text)
	dlg.Text:SetWordWrap(true)
	dlg.AcceptButton:SetText(options.AcceptText or (YES or L["Yes"]))
	dlg.OnAccept = options.OnAccept

	local textHeight = dlg.Text:GetStringHeight()
	local paddingTop = 60
	local paddingBottom = 50

	dlg:SetHeight(textHeight + paddingTop + paddingBottom)
	dlg:ClearAllPoints()
	dlg:SetPoint("CENTER", UIParent, "CENTER")
	dlg:Show()
end

---Hides the shared confirmation dialog, if one has been created.
function M:HideConfirm()
	if confirm then
		confirm:Hide()
	end
end

---@class DialogOptions
---@field Title string?
---@field Text string
---@field Width number?

---@class ConfirmOptions
---@field Title string?
---@field Text string
---@field AcceptText string? defaults to the client's own "Yes"
---@field OnAccept fun()
---@field Width number?
