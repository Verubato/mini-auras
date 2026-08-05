---@type string, Addon
local addonName, addon = ...
local dbMigrator = addon.Config.Migrator
local mini = addon.Framework
local L = addon.L
local trinketsTracker = addon.Core.TrinketsTracker
---@type Db
local db
local M = addon.Config

M.SoundLocation = "Interface\\AddOns\\" .. addonName .. "\\Sounds\\"

M.SoundFiles = {
	"AirHorn.ogg",
	"AlertToastWarm.ogg",
	"BubblePop.ogg",
	"CinematicHit.ogg",
	"ElectricalSpark.ogg",
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

-- Blizzard settings panel splash. The accent matches the standalone window title, but the
-- framework palette is private to the GUI widgets so the value is repeated here.
local PANEL_ACCENT = { r = 0.90, g = 0.20, b = 0.20 }
local PANEL_CONTENT_WIDTH = 460
local PANEL_TEXT_WIDTH = 400
local PANEL_RULE_HALF_WIDTH = 110

---Rescales a font string, keeping the font object's face and flags.
local function SetFontSize(fontString, size)
	local path, _, flags = fontString:GetFont()

	if path then
		fontString:SetFont(path, size, flags)
	end
end

---Builds the centred splash shown under Interface > AddOns: name, version and a button
---through to the standalone window, which is where the real configuration lives.
local function BuildRedirectPanel(panel, version)
	local content = CreateFrame("Frame", nil, panel)
	content:SetSize(PANEL_CONTENT_WIDTH, 200)
	content:SetPoint("TOP", panel, "TOP", 0, -90)

	local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
	title:SetPoint("TOP", content, "TOP", 0, 0)
	title:SetText(addonName)
	title:SetTextColor(PANEL_ACCENT.r, PANEL_ACCENT.g, PANEL_ACCENT.b, 1)
	SetFontSize(title, 32)

	local versionLabel = content:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	versionLabel:SetPoint("TOP", title, "BOTTOM", 0, -4)
	versionLabel:SetText(version or "")
	versionLabel:SetTextColor(0.62, 0.60, 0.58, 1)

	-- Thin rule under the wordmark, brightest in the middle and fading out at both ends.
	-- Two halves because a single texture can only gradient in one direction. Alpha is baked
	-- into the gradient colours: SetGradient replaces vertex alpha, so SetAlpha can't dim it.
	local ruleLeft = content:CreateTexture(nil, "ARTWORK")
	ruleLeft:SetSize(PANEL_RULE_HALF_WIDTH, 1)
	ruleLeft:SetPoint("TOPRIGHT", versionLabel, "BOTTOM", 0, -14)
	ruleLeft:SetColorTexture(1, 1, 1, 1)
	ruleLeft:SetGradient("HORIZONTAL",
		CreateColor(PANEL_ACCENT.r, PANEL_ACCENT.g, PANEL_ACCENT.b, 0),
		CreateColor(PANEL_ACCENT.r, PANEL_ACCENT.g, PANEL_ACCENT.b, 0.7))

	local ruleRight = content:CreateTexture(nil, "ARTWORK")
	ruleRight:SetSize(PANEL_RULE_HALF_WIDTH, 1)
	ruleRight:SetPoint("TOPLEFT", versionLabel, "BOTTOM", 0, -14)
	ruleRight:SetColorTexture(1, 1, 1, 1)
	ruleRight:SetGradient("HORIZONTAL",
		CreateColor(PANEL_ACCENT.r, PANEL_ACCENT.g, PANEL_ACCENT.b, 0.7),
		CreateColor(PANEL_ACCENT.r, PANEL_ACCENT.g, PANEL_ACCENT.b, 0))

	local message = content:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	-- BOTTOMLEFT of the right half is where the two rules join, i.e. the horizontal centre.
	message:SetPoint("TOP", ruleRight, "BOTTOMLEFT", 0, -18)
	message:SetWidth(PANEL_TEXT_WIDTH)
	message:SetJustifyH("CENTER")
	message:SetText(L["Use /minicc, /mcc, or /cc to open the MiniCC config window."])

	local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	button:SetSize(240, 32)
	button:SetPoint("TOP", message, "BOTTOM", 0, -20)
	button:SetText(L["Open Settings"])
	SetFontSize(button:GetFontString(), 14)
	button:SetScript("OnClick", function()
		-- Close Blizzard's settings window on the way out: it opened this one, and leaving it
		-- sitting behind the config window is just a panel the user has to dismiss afterwards.
		-- HideUIPanel is protected though, so in combat this waits rather than erroring - the
		-- panel closes itself the moment combat drops.
		local settingsFrame = SettingsPanel or InterfaceOptionsFrame
		if settingsFrame and HideUIPanel then
			local function HideSettings()
				if settingsFrame:IsShown() then
					HideUIPanel(settingsFrame)
				end
			end

			if InCombatLockdown() then
				mini:RunWhenCombatEnds(HideSettings, "MiniCC_HideSettingsPanel")
			else
				HideSettings()
			end
		end

		M.Window:Show()
	end)
end

function M:Apply()
	addon:Refresh()
end

function M:Init()
	db = dbMigrator:GetAndUpgradeDb()

	-- MiniCC is the one addon that runs its own window rather than a Blizzard panel, so it
	-- takes the accented restyle. Must come before any widget is built.
	mini:SetCustomStyling(true)

	local version = C_AddOns.GetAddOnMetadata(addonName, "Version")

	-- Register a minimal WoW settings entry so sub-categories can attach to it,
	-- and the addon appears in Interface > AddOns for discoverability.
	local redirectPanel = CreateFrame("Frame")
	redirectPanel.name = addonName

	local category = mini:AddCategory(redirectPanel)

	if category then
		BuildRedirectPanel(redirectPanel, version)
	end

	-- Standalone config window
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
			Key = "Auras",
			Title = L["Auras"],
			Icon = "Interface\\Icons\\Spell_Fire_SealOfFire",
			Build = function(content)
				M.Auras:Build(content, db.Modules.AurasModule.Default, db.Modules.AurasModule.Raid)
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
			Icon = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew",
			Build = function(content)
				M.Alerts:Build(content, db.Modules.AlertsModule)
			end,
		},
		{
			Key = "Healer",
			Title = L["Healer"],
			Icon = "Interface\\Icons\\Spell_Holy_PowerWordShield",
			Build = function(content)
				M.Healer:Build(content, db.Modules.HealerCCModule)
			end,
		},
		{
			Key = "Nameplates",
			Title = L["Nameplates_Short"] or L["Nameplates"],
			Icon = "Interface\\TargetingFrame\\UI-StatusBar",
			Build = function(content)
				M.Nameplates:Build(content, db.Modules.NameplatesModule)
			end,
		},
		{
			Key = "Portraits",
			Title = L["Portraits_Short"] or L["Portraits"],
			Icon = "Interface\\Icons\\Achievement_Character_Human_Male",
			Build = function(content)
				M.Portraits:Build(content)
			end,
		},
		{
			Key = "EnemyKickTracker",
			Title = L["Enemy Kicks_Short"] or L["Enemy Kicks"],
			Icon = "Interface\\Icons\\Ability_Kick",
			Build = function(content)
				M.EnemyKickTracker:Build(content)
			end,
		},
		{
			Key = "AllyKickTracker",
			Title = L["Ally Kicks_Short"] or L["Ally Kicks"],
			-- Mind Freeze, so the tab reads as a different feature to the kick timer's own icon.
			Icon = C_Spell.GetSpellTexture(47528),
			Build = function(content)
				M.AllyKickTracker:Build(content, db.Modules.AllyKickTrackerModule)
			end,
		},
		{
			Key = "Precog",
			Title = L["Precognition"],
			-- The spell's own icon, resolved rather than guessed at from the art names.
			Icon = C_Spell.GetSpellTexture(377362),
			Build = function(content)
				M.Precog:Build(content)
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
	-- The standalone Party Trinkets module takes the friendly tracker's slot (trinket data
	-- is C_PvP-based, not aura-based, so it survives the lockdown).
	-- TEMPORARY: remove with the modules once 12.1 is live.
	if addon.Utils.WoWEx:UseAuraContainers() then
		for i = #tabs, 1, -1 do
			if tabs[i].Key == "FriendlyCooldowns" then
				tabs[i] = {
					Key = "Trinkets",
					Title = L["Party Trinkets_Short"] or L["Party Trinkets"],
					-- The icon the module itself renders, not the old jewellery art.
					Icon = trinketsTracker:GetDefaultIcon(),
					Build = function(content)
						M.Trinkets:Build(content)
					end,
				}
			elseif tabs[i].Key == "EnemyCooldowns" then
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

	-- The nameplates tab uses a health-bar texture rather than a spell icon. That art ships white
	-- so whatever draws it can tint it, so it has to be coloured here or it renders as a pale
	-- block.
	local nameplatesTab = tabController:GetTabButton("Nameplates")
	if nameplatesTab and nameplatesTab.Icon then
		nameplatesTab.Icon:SetVertexColor(0.15, 0.75, 0.15, 1)
	end

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
			local on = addon.Core.Cooldowns.Brain:ToggleDebug()
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
---@field SoundLocation string
---@field Migrator DbMigrator
---@field TabController TabReturn
---@field General GeneralConfig
---@field Portraits PortraitsConfig
---@field CrowdControl CrowdControlConfig
---@field Healer HealerCrowdControlConfig
---@field Alerts AlertsConfig
---@field Nameplates NameplatesConfig
---@field EnemyKickTracker EnemyKickTrackerConfig
---@field AllyKickTracker AllyKickTrackerConfig
---@field Precog PrecogConfig
---@field OtherAddons OtherAddonsConfig
---@field Auras AurasConfig
---@field FriendlyCooldownTracker FriendlyCooldownTrackerConfig
---@field EnemyCooldownTracker EnemyCooldownTrackerConfig
---@field Miscellaneous MiscellaneousConfig
