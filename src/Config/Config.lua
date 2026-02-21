---@type string, Addon
local addonName, addon = ...
local dbMigrator = addon.Config.Migrator
local mini = addon.Core.Framework
local L = addon.L
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
---@type Db
local db
local M = addon.Config

M.MediaLocation = "Interface\\AddOns\\" .. addonName .. "\\Media\\"

M.SoundFiles = {
	"AlertToastWarm.ogg",
	"BubblePop.ogg",
	"CinematicHit.ogg",
	"Error.ogg",
	"Notification18.ogg",
	"Notification38.ogg",
	"Sonar.ogg",
	"SuddenShock.ogg",
	"WatchOut.ogg",
	"WhooshSwing.ogg",
}

function M:Apply()
	if InCombatLockdown() then
		mini:Notify(L["Can't apply settings during combat."])
		return
	end

	addon:Refresh()
end

function M:Init()
	db = dbMigrator:GetAndUpgradeDb()

	local scroll = CreateFrame("ScrollFrame", nil, nil, "UIPanelScrollFrameTemplate")
	scroll.name = addonName

	local category = mini:AddCategory(scroll)

	if not category then
		return
	end

	local panel = CreateFrame("Frame", nil, scroll)
	local width, height = mini:SettingsSize()

	panel:SetWidth(width)
	panel:SetHeight(height)

	scroll:SetScrollChild(panel)

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(scrollSelf, delta)
		local step = 20

		local current = scrollSelf:GetVerticalScroll()
		local max = scrollSelf:GetVerticalScrollRange()

		if delta > 0 then
			scrollSelf:SetVerticalScroll(math.max(current - step, 0))
		else
			scrollSelf:SetVerticalScroll(math.min(current + step, max))
		end
	end)

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
	title:SetPoint("TOPLEFT", 0, -verticalSpacing)
	title:SetText(string.format("%s - %s", addonName, version))

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Shows CC and other important spell alerts."],
		},
	})

	lines:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

	local tabsPanel = CreateFrame("Frame", nil, panel)
	tabsPanel:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing)
	tabsPanel:SetPoint("BOTTOM", panel, "BOTTOM", 0, verticalSpacing * 2)

	local keys = {
		General = "General",
		CC = "CC",
		CDs = "CDs",
		Alerts = "Alerts",
		Healer = "Healer",
		Nameplates = "Nameplates",
		Portraits = "Portraits",
	}

	local tabs = {
		{
			Key = keys.General,
			Title = L["General"],
			Build = function(content)
				M.General:Build(content)
			end,
		},
		{
			Key = keys.CC,
			Title = L["CC"],
			Build = function(content)
				M.CrowdControl:Build(content, db.Modules.CCModule.Default, db.Modules.CCModule.Raid)
			end,
		},
		{
			Key = keys.CDs,
			Title = L["CDs"],
			Build = function(content)
				M.FriendlyIndicator:Build(content, db.Modules.FriendlyIndicatorModule)
			end,
		},
		{
			Key = keys.Alerts,
			Title = L["Alerts"],
			Build = function(content)
				M.Alerts:Build(content, db.Modules.AlertsModule)
			end,
		},
		{
			Key = keys.Healer,
			Title = L["Healer"],
			Build = function(content)
				M.Healer:Build(content, db.Modules.HealerCCModule)
			end,
		},
		{
			Key = keys.Nameplates,
			Title = L["Nameplates_Short"] or L["Nameplates"],
			Build = function(content)
				M.Nameplates:Build(content, db.Modules.NameplatesModule)
			end,
		},
		{
			Key = keys.Portraits,
			Title = L["Portraits_Short"] or L["Portraits"],
			Build = function(content)
				M.Portraits:Build(content)
			end,
		},
	}

	local tabController = mini:CreateTabs({
		Parent = tabsPanel,
		InitialKey = "general",
		ContentInsets = {
			Top = verticalSpacing,
		},
		Tabs = tabs,
	})

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("RIGHT", panel, "RIGHT", -horizontalSpacing, 0)
	testBtn:SetPoint("TOP", title, "TOP", 0, 0)
	testBtn:SetText(L["Test"])
	testBtn:SetScript("OnClick", function()
		local options = db.Modules.CCModule.Default
		addon:ToggleTest(options)
	end)

	M.TabController = tabController

	StaticPopupDialogs["MINICC_CONFIRM"] = {
		text = "%s",
		button1 = YES,
		button2 = NO,
		OnAccept = function(_, data)
			if data and data.OnYes then
				data.OnYes()
			end
		end,
		OnCancel = function(_, data)
			if data and data.OnNo then
				data.OnNo()
			end
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
	}

	SLASH_MINICC1 = "/minicc"
	SLASH_MINICC2 = "/mcc"
	SLASH_MINICC3 = "/cc"

	SlashCmdList.MINICC = function(msg)
		-- normalize input
		msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

		if msg == "test" then
			addon:ToggleTest(db.Modules.CCModule.Default)
			return
		end

		mini:OpenSettings(category, panel)
	end

	local kickTimerPanel = M.KickTimer:Build()
	kickTimerPanel.name = L["Kick timer_Short"] or L["Kick timer"]

	mini:AddSubCategory(category, kickTimerPanel)

	local trinketsPanel = M.Trinkets:Build()
	trinketsPanel.name = L["Party Trinkets_Short"] or L["Party Trinkets"]

	mini:AddSubCategory(category, trinketsPanel)

	local otherAddonsPanel = M.OtherAddons:Build()
	otherAddonsPanel.name = L["Other Mini Addons_Short"] or L["Other Mini Addons"]

	mini:AddSubCategory(category, otherAddonsPanel)
end

---@class Config
---@field Init fun(self: table)
---@field Apply fun(self: table)
---@field SoundFiles string[]
---@field MediaLocation string
---@field Migrator DbMigrator
---@field TabController TabReturn
---@field General GeneralConfig
---@field Portraits PortraitsConfig
---@field CrowdControl CrowdControlConfig
---@field Healer HealerCrowdControlConfig
---@field Alerts AlertsConfig
---@field Nameplates NameplatesConfig
---@field KickTimer KickTimerConfig
---@field Trinkets TrinketsConfig
---@field OtherAddons OtherAddonsConfig
---@field FriendlyIndicator FriendlyIndicatorConfig
