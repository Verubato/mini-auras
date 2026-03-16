---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local dbMigrator = addon.Config.Migrator
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
---@class GeneralConfig
local M = {}

addon.Config.General = M

local profilePrefix = "!MiniCC!"
local profileIOWindow

local function ExportProfile()
	local db = mini:GetSavedVars()
	local serialized = C_EncodingUtil.SerializeCBOR(db)
	local encoded = C_EncodingUtil.EncodeBase64(serialized)
	return profilePrefix .. encoded
end

local function ImportProfile(str)
	if str:sub(1, #profilePrefix) ~= profilePrefix then
		return false, L["Invalid profile string."]
	end

	local encoded = str:sub(#profilePrefix + 1)
	local decoded = C_EncodingUtil.DecodeBase64(encoded)

	if not decoded or decoded == "" then
		return false, L["Failed to decode profile string."]
	end

	local ok, importedTable = pcall(C_EncodingUtil.DeserializeCBOR, decoded)
	if not ok or type(importedTable) ~= "table" then
		return false, L["Profile string is corrupted."]
	end

	-- Apply imported data in-place so existing module db references remain valid
	mini:ResetSavedVars(importedTable)

	-- Run migrations to bring the profile up to the current version
	local db = dbMigrator:GetAndUpgradeDb()

	-- Run deferred migrations immediately — UIParent:GetScale() is correct at this point
	dbMigrator:RunDeferredMigrations(db)

	-- Suppress the what's new popup
	db.WhatsNew = {}
	db.NotifiedChanges = true

	return true
end

local function RefreshAllPanels()
	local tabController = addon.Config.TabController
	for i = 1, #tabController.Tabs do
		local content = tabController:GetContent(tabController.Tabs[i].Key)
		if content and content.MiniRefresh then
			content:MiniRefresh()
		end
	end

	local trinketsPanel = addon.Config.Trinkets.Panel
	if trinketsPanel and trinketsPanel.MiniRefresh then
		trinketsPanel:MiniRefresh()
	end

	local kickTimerPanel = addon.Config.KickTimer.Panel
	if kickTimerPanel and kickTimerPanel.MiniRefresh then
		kickTimerPanel:MiniRefresh()
	end

	local precogPanel = addon.Config.PrecogGuesser.Panel
	if precogPanel and precogPanel.MiniRefresh then
		precogPanel:MiniRefresh()
	end
end

local function GetOrCreateProfileIOWindow()
	if profileIOWindow then
		return profileIOWindow
	end

	local win = CreateFrame("Frame", "MiniCCProfileIOWindow", UIParent, "BackdropTemplate")
	win:SetSize(500, 240)
	win:SetFrameStrata("DIALOG")
	win:SetClampedToScreen(true)
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", win.StopMovingOrSizing)
	win:Hide()

	win:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	win:SetBackdropColor(0, 0, 0, 0.9)

	local title = win:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", win, "TOP", 0, -10)
	title:SetText(L["Import/Export Profile"])
	title:SetTextColor(1, 0.82, 0)

	local divider = win:CreateTexture(nil, "ARTWORK")
	divider:SetHeight(1)
	divider:SetPoint("TOPLEFT", win, "TOPLEFT", 8, -28)
	divider:SetPoint("TOPRIGHT", win, "TOPRIGHT", -8, -28)
	divider:SetColorTexture(1, 1, 1, 0.15)

	local innerWidth = 500 - 32
	local exportLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	exportLabel:SetPoint("TOPLEFT", win, "TOPLEFT", 16, -42)
	exportLabel:SetText(L["Export Profile"])

	local exportBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	exportBox:SetHeight(28)
	exportBox:SetWidth(innerWidth)
	exportBox:SetPoint("TOPLEFT", exportLabel, "BOTTOMLEFT", 0, -6)
	exportBox:SetAutoFocus(false)
	exportBox:SetMaxLetters(0)
	exportBox:SetScript("OnEscapePressed", function() win:Hide() end)
	exportBox:SetScript("OnEditFocusGained", function(self)
		self:HighlightText()
	end)

	local importLabel = win:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	importLabel:SetPoint("TOPLEFT", exportBox, "BOTTOMLEFT", 0, -16)
	importLabel:SetText(L["Import Profile"])

	local importBox = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
	importBox:SetHeight(28)
	importBox:SetWidth(innerWidth)
	importBox:SetPoint("TOPLEFT", importLabel, "BOTTOMLEFT", 0, -6)
	importBox:SetAutoFocus(false)
	importBox:SetMaxLetters(0)
	importBox:SetScript("OnEscapePressed", function() win:Hide() end)

	local importBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	importBtn:SetSize(100, 22)
	importBtn:SetPoint("TOPRIGHT", importBox, "BOTTOMRIGHT", 0, -12)
	importBtn:SetText(L["Import"])
	importBtn:SetScript("OnClick", function()
		local str = importBox:GetText():gsub("%s+", "")

		if str == "" then
			mini:Notify(L["Please paste a profile string to import."])
			return
		end

		local ok, err = ImportProfile(str)
		if not ok then
			mini:Notify(err)
			return
		end

		RefreshAllPanels()
		addon:Refresh()
		mini:Notify(L["Profile imported successfully."])
		win:Hide()
	end)

	local closeBtn = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
	closeBtn:SetSize(80, 22)
	closeBtn:SetPoint("TOPRIGHT", importBtn, "TOPLEFT", -8, 0)
	closeBtn:SetText(CLOSE)
	closeBtn:SetScript("OnClick", function() win:Hide() end)

	win.ExportBox = exportBox
	win.ImportBox = importBox

	profileIOWindow = win
	return win
end

local function ShowProfileIOWindow()
	local win = GetOrCreateProfileIOWindow()
	win.ExportBox:SetText(ExportProfile())
	win.ImportBox:SetText("")
	win:ClearAllPoints()
	win:SetPoint("CENTER", UIParent, "CENTER")
	win:Show()
end

function M:Build(panel)
	local db = mini:GetSavedVars()

	local columns = 2
	local columnWidth = mini:ColumnWidth(columns, 0, 0)
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
		Width = columnWidth,
	})

	discordBox.Label:SetPoint("TOP", subtitleText, "BOTTOM", 0, -verticalSpacing * 2)
	discordBox.Label:SetWidth(columnWidth)
	discordBox.Label:SetJustifyH("CENTER")
	discordBox.EditBox:SetPoint("TOP", discordBox.Label, "BOTTOM", 0, -4)

	local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetBtn:SetSize(120, 26)
	resetBtn:SetPoint("TOPRIGHT", discordBox.EditBox, "BOTTOM", -horizontalSpacing / 2, -verticalSpacing * 2)
	resetBtn:SetText(L["Reset"])
	resetBtn:SetScript("OnClick", function()
		if InCombatLockdown() then
			mini:NotifyCombatLockdown()
			return
		end

		StaticPopup_Show("MINICC_CONFIRM", L["Are you sure you wish to reset to factory settings?"], nil, {
			OnYes = function()
				dbMigrator:ResetToFactory()

				local tabController = addon.Config.TabController
				for i = 1, #tabController.Tabs do
					local content = tabController:GetContent(tabController.Tabs[i].Key)

					if content and content.MiniRefresh then
						content:MiniRefresh()
					end
				end

				local trinketsPanel = addon.Config.Trinkets.Panel
				if trinketsPanel and trinketsPanel.MiniRefresh then
					trinketsPanel:MiniRefresh()
				end

				local kickTimerPanel = addon.Config.KickTimer.Panel
				if kickTimerPanel and kickTimerPanel.MiniRefresh then
					kickTimerPanel:MiniRefresh()
				end

				local precogPanel = addon.Config.PrecogGuesser.Panel
				if precogPanel and precogPanel.MiniRefresh then
					precogPanel:MiniRefresh()
				end

				addon:Refresh()
				mini:Notify(L["Settings reset to default."])
			end,
		})
	end)

	local importExportBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	importExportBtn:SetSize(120, 26)
	importExportBtn:SetPoint("TOPLEFT", discordBox.EditBox, "BOTTOM", horizontalSpacing / 2, -verticalSpacing * 2)
	importExportBtn:SetText(L["Import/Export"])
	importExportBtn:SetScript("OnClick", function()
		if InCombatLockdown() then
			mini:NotifyCombatLockdown()
			return
		end

		ShowProfileIOWindow()
	end)
end
