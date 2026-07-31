---@type string, Addon
local addonName, addon = ...
local dbMigrator = addon.Config.Migrator
local mini = addon.Core.Framework
local L = addon.L
---@type Db
local db
local M = addon.Config

M.MediaLocation = "Interface\\AddOns\\" .. addonName .. "\\Media\\"

M.SoundFiles = {
	"AirHorn.ogg",
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

local LOCALE = GetLocale()

if LOCALE == "zhCN" or LOCALE == "zhTW" then
	table.insert(M.SoundFiles, "XiaYike.ogg")
end

function M:Apply()
	if InCombatLockdown() then
		mini:Notify(L["Can't apply settings during combat."])
		return
	end

	addon:Refresh()
end

function M:Init()
	db = dbMigrator:GetAndUpgradeDb()

	-- Register a minimal WoW settings entry so sub-categories can attach to it,
	-- and the addon appears in Interface > AddOns for discoverability.
	local redirectPanel = CreateFrame("Frame")
	redirectPanel.name = addonName

	local category = mini:AddCategory(redirectPanel)

	if category then
		local redirectMsg = redirectPanel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		redirectMsg:SetPoint("TOPLEFT", 16, -16)
		redirectMsg:SetText(L["Use /minicc, /mcc, or /cc to open the MiniCC config window."])

		local redirectBtn = CreateFrame("Button", nil, redirectPanel, "UIPanelButtonTemplate")
		redirectBtn:SetSize(200, 26)
		redirectBtn:SetPoint("TOPLEFT", redirectMsg, "BOTTOMLEFT", 0, -12)
		redirectBtn:SetText(L["Open Settings"])
		redirectBtn:SetScript("OnClick", function()
			M.Window:Show()
		end)
	end

	-- Standalone config window
	local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
	local windowWidth = 1000
	local windowHeight = 690

	local window = mini:CreateStandaloneWindow({
		Name = addonName .. "ConfigFrame",
		Title = addonName,
		Subtitle = version,
		Width = windowWidth,
		Height = windowHeight,
	})

	M.Window = window

	-- Center the window when it becomes visible from a hidden state.
	local windowPreviouslyHidden = true
	window:HookScript("OnHide", function()
		windowPreviouslyHidden = true
	end)
	window:HookScript("OnShow", function(w)
		if windowPreviouslyHidden then
			windowPreviouslyHidden = false
			w:ClearAllPoints()
			w:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
		end
	end)

	-- Test button in the title bar
	local testBtn = mini:Button({
		Parent = window.TitleBar,
		Text = L["Test"],
		Width = 80,
		OnClick = function()
			addon:ToggleTest(nil)
		end,
	})
	testBtn:SetPoint("RIGHT", window.CloseButton, "LEFT", -8, 0)

	-- Tabs fill the content area of the window
	local tabsPanel = window.Content

	-- Sidebar icons: desaturated by CreateTabs until the tab is selected.
	local tabs = {
		{
			Key = "General",
			Title = L["Home"],
			Icon = "Interface\\Icons\\INV_Misc_Rune_01",
			Build = function(content)
				M.General:Build(content)
			end,
		},
		{
			Key = "CC",
			Title = L["CC"],
			Icon = "Interface\\Icons\\Spell_Nature_Polymorph",
			Build = function(content)
				M.CrowdControl:Build(content, db.Modules.CCModule.Default, db.Modules.CCModule.Raid)
			end,
		},
		{
			Key = "Indicator",
			Title = L["Auras"],
			Icon = "Interface\\Icons\\Spell_Holy_PowerWordShield",
			Build = function(content)
				M.FriendlyIndicator:Build(content, db.Modules.FriendlyIndicatorModule.Default, db.Modules.FriendlyIndicatorModule.Raid)
			end,
		},
		{
			Key = "FriendlyCooldowns",
			Title = L["Friendly Cooldowns_Short"] or L["Friendly Cooldowns"],
			Icon = "Interface\\Icons\\Spell_Holy_GuardianSpirit",
			Build = function(content)
				local m = db.Modules.FriendlyCooldownTrackerModule
			M.FriendlyCooldownTracker:Build(content, m.Default, m.Raid)
			end,
		},
		{
			Key = "EnemyCooldowns",
			Title = L["Enemy Cooldowns_Short"] or L["Enemy Cooldowns"],
			Icon = "Interface\\Icons\\Ability_CriticalStrike",
			Build = function(content)
				M.EnemyCooldownTracker:Build(content, db.Modules.EnemyCooldownTrackerModule)
			end,
		},
		{
			Key = "Alerts",
			Title = L["Alerts"],
			Icon = "Interface\\Icons\\Ability_Warrior_BattleShout",
			Build = function(content)
				M.Alerts:Build(content, db.Modules.AlertsModule)
			end,
		},
		{
			Key = "Healer",
			Title = L["Healer"],
			Icon = "Interface\\Icons\\Spell_Holy_FlashHeal",
			Build = function(content)
				M.Healer:Build(content, db.Modules.HealerCCModule)
			end,
		},
		{
			Key = "Nameplates",
			Title = L["Nameplates_Short"] or L["Nameplates"],
			Icon = "Interface\\Icons\\Ability_Hunter_SniperShot",
			Build = function(content)
				M.Nameplates:Build(content, db.Modules.NameplatesModule)
			end,
		},
		{
			Key = "Portraits",
			Title = L["Portraits_Short"] or L["Portraits"],
			Icon = "Interface\\Icons\\INV_Misc_Head_Human_01",
			Build = function(content)
				M.Portraits:Build(content)
			end,
		},
		{
			Key = "KickTimer",
			Title = L["Kick timer_Short"] or L["Kick timer"],
			Icon = "Interface\\Icons\\Ability_Kick",
			Build = function(content)
				M.KickTimer:Build(content)
			end,
		},
		{
			Key = "Precog",
			Title = L["Precognition"],
			Icon = "Interface\\Icons\\Spell_Holy_MindVision",
			Build = function(content)
				M.PrecogGuesser:Build(content)
			end,
		},
		{
			Key = "Miscellaneous",
			Title = L["Miscellaneous_Short"] or L["Miscellaneous"],
			Icon = "Interface\\Icons\\Trade_Engineering",
			Build = function(content)
				M.Miscellaneous:Build(content)
			end,
		},
		{
			Key = "Profiles",
			Title = L["Profiles"],
			Icon = "Interface\\Icons\\INV_Misc_Note_01",
			Build = function(content)
				M.Profiles:Build(content)
			end,
		},
		{
			Key = "OtherAddons",
			Title = L["Other Mini Addons_Short"] or L["Other Mini Addons"],
			Icon = "Interface\\Icons\\INV_Misc_Bag_08",
			Build = function(content)
				M.OtherAddons:Build(content)
			end,
		},
	}

	-- Cooldown tracking (friendly and enemy) is disabled on 12.1 - it infers cooldowns from
	-- aura data, which addons can no longer read - so those config tabs are hidden there.
	-- TEMPORARY: remove with the modules once 12.1 is live.
	if addon.Utils.WoWEx:UseAuraContainers() then
		for i = #tabs, 1, -1 do
			if tabs[i].Key == "FriendlyCooldowns" or tabs[i].Key == "EnemyCooldowns" then
				table.remove(tabs, i)
			end
		end
	end

	local contentPadding = 12
	local windowInset = 2 + contentPadding * 2 + 14 -- border (2), padding (24), scrollbar (14)
	local tabStripWidth = 130
	local tabHorizontalPadding = 12
	local contentWidth = windowWidth - windowInset - tabStripWidth - tabHorizontalPadding
	mini.ContentWidth = contentWidth
	mini.TextMaxWidth = contentWidth - windowInset

	local tabController = mini:CreateTabs({
		Parent = tabsPanel,
		InitialKey = "General",
		ScrollBody = true,
		ScrollContentWidth = contentWidth,
		ContentInsets = { Top = 4 },
		TabFitToParent = true,
		Vertical = true,
		StripWidth = tabStripWidth,
		HorizontalPadding = tabHorizontalPadding,
		Tabs = tabs,
	})

	M.TabController = tabController

	StaticPopupDialogs["MINICC_RELOAD_CONFIRM"] = {
		text = L["Language changed. Reload UI now?"],
		button1 = YES,
		button2 = NO,
		OnAccept = function()
			C_UI.Reload()
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
	}

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
		msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

		if msg == "test" then
			addon:ToggleTest(nil)
			return
		end

		if msg == "debug" then
			local on = addon.Modules.Cooldowns.Brain:ToggleDebug()
			mini:Notify(on and "Cooldown debug logging ON" or "Cooldown debug logging OFF")
			return
		end

		window:Toggle()
	end

	-- add a /rl alias if the user doesn't have one defined already
	if not SLASH_RL1 then
		SLASH_RL1 = "/rl"
		SlashCmdList["RL"] = function()
			C_UI.Reload()
		end
	end
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
---@field PrecogGuesser PrecogGuesserConfig
---@field OtherAddons OtherAddonsConfig
---@field FriendlyIndicator FriendlyIndicatorConfig
---@field FriendlyCooldownTracker FriendlyCooldownTrackerConfig
---@field EnemyCooldownTracker EnemyCooldownTrackerConfig
---@field Miscellaneous MiscellaneousConfig
