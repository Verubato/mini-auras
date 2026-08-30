local addonName, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L

-- Every addon embeds its own copy of the framework, and the first one to register would
-- otherwise decide this entry's wording for all the rest.
local CONFIRM_POPUP = addonName .. "_MINIFRAMEWORK_CONFIRM"

StaticPopupDialogs[CONFIRM_POPUP] = {
	-- The caller's wording arrives as an argument, so a per cent sign in it cannot be read as a
	-- format specifier.
	text = "%s",
	button2 = CANCEL or L["Cancel"],
	-- The client reads the entry at click time, so a later call would overwrite a callback left
	-- on it.
	OnAccept = function(_, data)
		data.OnAccept()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
}

local BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local dialog

---A draggable dark panel with a gold title over a rule, and a wrapping message below it.
local function BuildDialogFrame()
	local frame = CreateFrame("Frame", nil, UIParent, GUI.BackdropTemplate)
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

	dialog = BuildDialogFrame()
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

---Asks the user to confirm before something irreversible happens.
---@param options ConfirmOptions
function M:ShowConfirm(options)
	if not options then
		error("ShowConfirm - options must not be nil.")
	end

	if not options.Text or not options.OnAccept then
		error("ShowConfirm - invalid options.")
	end

	StaticPopupDialogs[CONFIRM_POPUP].button1 = options.AcceptText or (YES or L["Yes"])

	StaticPopup_Show(CONFIRM_POPUP, options.Text, nil, { OnAccept = options.OnAccept })
end

---Hides the confirmation prompt, if one is up.
function M:HideConfirm()
	StaticPopup_Hide(CONFIRM_POPUP)
end

---@class DialogOptions
---@field Title string?
---@field Text string
---@field Width number?

---@class ConfirmOptions
---@field Text string
---@field AcceptText string? defaults to the client's own "Yes"
---@field OnAccept fun()
