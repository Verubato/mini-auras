---@type string, Addon
local addonName, addon = ...
local dbMigrator = addon.Config.Migrator
local wowEx = addon.Utils.WoWEx
local mini = addon.Framework
local L = addon.L
---@type Db
local db
-- Said once per stretch of the restriction, since a slider drag would otherwise say it per step.
local lookWarningShown = false
local M = addon.Config

local NAV_ICON_BASE = "Interface\\AddOns\\" .. addonName .. "\\Icons\\Nav\\"

-- The framework palette is private to the GUI widgets, so the window title's accent is
-- repeated here.
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

---Opens the options window, or says why it cannot. Building the window asks the client for
---keyboard propagation, which combat refuses, so the first open has to wait for the fight to end.
---@param toggle boolean? True to close the window again when it is already open.
---@return boolean handled False when combat turned the ask away.
local function OpenWindow(toggle)
	if not M.Window and InCombatLockdown() then
		mini:NotifyWithPrefix(L["The options window can't open during combat."])
		return false
	end

	local window = M:EnsureWindow()

	if toggle then
		window:Toggle()
	else
		window:Show()
	end

	return true
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
	-- into the gradient colours, since SetGradient replaces vertex alpha and SetAlpha cannot dim it.
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
	message:SetText(L["Use /miniauras, /minia, or /cc to open the MiniAuras config window."])

	local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	button:SetSize(240, 32)
	button:SetPoint("TOP", message, "BOTTOM", 0, -20)
	button:SetText(L["Open Settings"])
	-- GameFontNormalMed3 is 14pt.
	-- A raw SetFont path drops the per-locale glyph fallbacks and boxes Cyrillic text.
	button:SetNormalFontObject(GameFontNormalMed3)
	button:SetHighlightFontObject(GameFontHighlightMedium)
	button:SetScript("OnClick", function()
		-- Scheduling the hide for a window that never opened would empty the screen the moment
		-- the fight ended.
		if not OpenWindow() then
			return
		end

		-- Blizzard's settings window opened this one, so it closes on the way out. HideUIPanel is
		-- protected, so in combat the close waits for the fight to end.
		local settingsFrame = SettingsPanel or InterfaceOptionsFrame
		if settingsFrame and HideUIPanel then
			local function HideSettings()
				if settingsFrame:IsShown() then
					HideUIPanel(settingsFrame)
				end
			end

			if InCombatLockdown() then
				mini:RunWhenCombatEnds(HideSettings, "MiniAuras_HideSettingsPanel")
			else
				HideSettings()
			end
		end
	end)
end

---Says once that a look change cannot land yet. While the client is hiding aura data a button
---cannot be restyled, so a size or style edit waits for the restriction to lift. Everything else,
---budgets, colours, positions, applies as normal.
---Test mode is exempt, since it draws its own icons and shows the change straight away.
local function WarnIfLookIsParked()
	if not wowEx:IsAuraStylingRestricted() or addon:IsTestActive() then
		-- Cleared as soon as it could land, so the next fight says it again.
		lookWarningShown = false
		return
	end

	if lookWarningShown then
		return
	end

	lookWarningShown = true
	mini:NotifyWithPrefix(L["Icon size and style changes will apply when combat ends."])
end

---Applies a settings change. A ModuleName key scopes the refresh to the one module whose settings
---table changed, since sliders and colour pickers fire this per drag step. No key refreshes
---everything.
---@param settingsKey string? A ModuleName value naming the db.Modules table that changed.
function M:Apply(settingsKey)
	WarnIfLookIsParked()

	if settingsKey then
		addon:RefreshModule(settingsKey)
	else
		addon:Refresh()
	end
end

---Builds the window, its pages and the dialogs they raise. The options UI is a third of what the
---addon costs to start and most sessions never open it, so it waits for the first ask.
---@return table window
function M:EnsureWindow()
	if M.Window then
		return M.Window
	end

	local windowWidth = 1000
	local windowHeight = 690

	local window = mini:CreateStandaloneWindow({
		Name = addonName .. "ConfigFrame",
		Title = addonName,
		Subtitle = C_AddOns.GetAddOnMetadata(addonName, "Version"),
		Width = windowWidth,
		Height = windowHeight,
	})

	M.Window = window

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

	local testBtn = mini:Button({
		Parent = window.TitleBar,
		Text = L["Test"],
		Width = 80,
		OnClick = function()
			addon:ToggleTest(nil)
		end,
	})
	testBtn:SetPoint("RIGHT", window.CloseButton, "LEFT", -8, 0)

	-- The pulse rides its own texture because the button's backdrop is driven by its hover scripts.
	local accent = mini.GUI.Accent
	local testWash = testBtn:CreateTexture(nil, "OVERLAY")
	testWash:SetPoint("TOPLEFT", testBtn, "TOPLEFT", 1, -1)
	testWash:SetPoint("BOTTOMRIGHT", testBtn, "BOTTOMRIGHT", -1, 1)
	mini.GUI.SetSolid(testWash, accent.r, accent.g, accent.b, 0.35)
	testWash:Hide()

	local testPulse = testWash:CreateAnimationGroup()
	testPulse:SetLooping("BOUNCE")
	local pulseAlpha = testPulse:CreateAnimation("Alpha")
	pulseAlpha:SetFromAlpha(1)
	pulseAlpha:SetToAlpha(0.25)
	pulseAlpha:SetDuration(0.8)

	local function UpdateTestButton()
		local active = addon:IsTestActive()

		testBtn:SetText(active and L["Testing..."] or L["Test"])
		testWash:SetShown(active)

		if active then
			testPulse:Play()
		else
			testPulse:Stop()
		end
	end

	-- Test mode is toggled from several places (this button, the panels' own test toggles,
	-- slash commands), so track the manager itself rather than the button click.
	local testManager = addon.Core.TestModeManager
	local originalStart = testManager.StartTesting
	local originalStop = testManager.StopTesting

	function testManager.StartTesting(manager, ...)
		originalStart(manager, ...)
		UpdateTestButton()
	end

	function testManager.StopTesting(manager, ...)
		originalStop(manager, ...)
		UpdateTestButton()
	end

	window:HookScript("OnShow", UpdateTestButton)

	-- The nav strip sits outside Content's padding, so pages get their position back through
	-- ContentInsets.
	local tabsPanel = CreateFrame("Frame", nil, window)
	tabsPanel:SetPoint("TOPLEFT", window.TitleBar, "BOTTOMLEFT", 0, -1)
	-- The insets clear the Content frame's right padding of 12 and the window's 1px border.
	tabsPanel:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -13, 1)

	-- Sidebar icons: the addon's own art under Icons\Nav, one per tab key.
	local tabs = {
		{ Heading = L["General"] },
		{
			Key = "General",
			Title = L["Home"],
			Icon = NAV_ICON_BASE .. "General.png",
			-- The home page carries its own branding; a "Home" band above it is noise.
			PageHeader = false,
			Build = function(content)
				M.General:Build(content)
			end,
		},
		{
			Key = "PersonalAuras",
			Title = L["Personal Auras"],
			Icon = NAV_ICON_BASE .. "PersonalAuras.png",
			Build = function(content)
				M.PersonalAuras:Build(content)
			end,
		},
		{
			Key = "ImportantAuras",
			Title = L["Important Auras"],
			Icon = NAV_ICON_BASE .. "ImportantAuras.png",
			Build = function(content)
				local m = db.Modules.ImportantAuras
				M.ImportantAuras:Build(content, m.Default, m.Raid)
			end,
		},
		{
			Key = "FrameAuras",
			Title = L["Frame Auras"],
			Icon = NAV_ICON_BASE .. "FrameAuras.png",
			Build = function(content)
				M.FrameAuras:Build(content)
			end,
		},
		{
			Key = "Alerts",
			Title = L["Alerts"],
			Icon = NAV_ICON_BASE .. "Alerts.png",
			Build = function(content)
				M.Alerts:Build(content, db.Modules.Alerts)
			end,
		},
		{
			Key = "Nameplates",
			Title = L["Nameplates_Short"] or L["Nameplates"],
			Icon = NAV_ICON_BASE .. "Nameplates.png",
			Build = function(content)
				M.Nameplates:Build(content, db.Modules.Nameplates)
			end,
		},
		{
			Key = "Portraits",
			Title = L["Portraits_Short"] or L["Portraits"],
			Icon = NAV_ICON_BASE .. "Portraits.png",
			Build = function(content)
				M.Portraits:Build(content)
			end,
		},
		{ Heading = L["Crowd Control"] },
		{
			Key = "CC",
			Title = L["CC"],
			Icon = NAV_ICON_BASE .. "CC.png",
			Build = function(content)
				M.CrowdControl:Build(content, db.Modules.CrowdControl.Default, db.Modules.CrowdControl.Raid)
			end,
		},
		{
			Key = "PetCC",
			Title = L["Pet CC"],
			Icon = NAV_ICON_BASE .. "PetCC.png",
			Build = function(content)
				M.PetCrowdControl:Build(content)
			end,
		},
		{
			Key = "Healer",
			Title = L["Healer"],
			Icon = NAV_ICON_BASE .. "Healer.png",
			Build = function(content)
				M.Healer:Build(content, db.Modules.HealerCrowdControl)
			end,
		},
		{
			Key = "Trinkets",
			Title = L["Party Trinkets_Short"] or L["Party Trinkets"],
			Icon = NAV_ICON_BASE .. "Trinkets.png",
			Build = function(content)
				M.Trinkets:Build(content)
			end,
		},
		{ Heading = L["Kicks"] },
		{
			Key = "AllyKickTracker",
			Title = L["Ally Kicks_Short"] or L["Ally Kicks"],
			Icon = NAV_ICON_BASE .. "AllyKickTracker.png",
			Build = function(content)
				M.AllyKickTracker:Build(content, db.Modules.AllyKickTracker)
			end,
		},
		{
			Key = "EnemyKickTracker",
			Title = L["Enemy Kicks_Short"] or L["Enemy Kicks"],
			Icon = NAV_ICON_BASE .. "EnemyKickTracker.png",
			Build = function(content)
				M.EnemyKickTracker:Build(content)
			end,
		},
		{ Heading = L["Other"] },
		{
			Key = "Miscellaneous",
			Title = L["Miscellaneous_Short"] or L["Miscellaneous"],
			Icon = NAV_ICON_BASE .. "Miscellaneous.png",
			Build = function(content)
				M.Miscellaneous:Build(content)
			end,
		},
		{
			Key = "Profiles",
			Title = L["Profiles"],
			Icon = NAV_ICON_BASE .. "Profiles.png",
			Build = function(content)
				M.Profiles:Build(content)
			end,
		},
		{
			Key = "OtherAddons",
			Title = L["Other Mini Addons_Short"] or L["Other Mini Addons"],
			Icon = NAV_ICON_BASE .. "OtherAddons.png",
			Build = function(content)
				M.OtherAddons:Build(content)
			end,
		},
	}

	local contentPadding = 12
	local windowInset = 2 + contentPadding * 2 + 14 -- border (2), padding (24), scrollbar (14)
	local tabStripWidth = 135
	local tabHorizontalPadding = 12
	local contentWidth = windowWidth - windowInset - tabStripWidth - tabHorizontalPadding
	mini.ContentWidth = contentWidth
	mini.TextMaxWidth = contentWidth - windowInset

	local tabController = mini:CreateTabs({
		Parent = tabsPanel,
		InitialKey = "General",
		ScrollBody = true,
		ScrollContentWidth = contentWidth,
		-- Restores the content padding the flush tabsPanel no longer provides.
		ContentInsets = { Top = 4 + contentPadding + 1 },
		TabFitToParent = true,
		Vertical = true,
		-- The strip absorbs the left content padding the flush panel reclaimed.
		StripWidth = tabStripWidth + contentPadding,
		HorizontalPadding = tabHorizontalPadding,
		TabIconSize = 24,
		PageHeader = true,
		Tabs = tabs,
	})

	M.TabController = tabController

	StaticPopupDialogs["MINIAURAS_CONFIRM"] = {
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

	return M.Window
end

function M:Init()
	db = dbMigrator:GetAndUpgradeDb()

	-- MiniAuras runs its own window, so it takes the accented restyle. This must come before any
	-- widget is built.
	mini:SetCustomStyling(true)

	local version = C_AddOns.GetAddOnMetadata(addonName, "Version")

	-- Sub-categories need a parent entry to attach to, and it puts the addon in Interface > AddOns.
	local redirectPanel = CreateFrame("Frame")
	redirectPanel.name = addonName

	local category = mini:AddCategory(redirectPanel)

	if category then
		BuildRedirectPanel(redirectPanel, version)
	end

	SLASH_MINIAURAS1 = "/miniauras"
	-- Not /minia: Blizzard's main assist command owns that and wins the parse, so it never reaches us.
	SLASH_MINIAURAS2 = "/minia"
	-- The MiniCC-era aliases stay registered because people have them in macros.
	SLASH_MINIAURAS3 = "/minicc"
	SLASH_MINIAURAS4 = "/mcc"
	SLASH_MINIAURAS5 = "/cc"

	SlashCmdList.MINIAURAS = function(msg)
		msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

		if msg == "test" then
			addon:ToggleTest(nil)
			return
		end

		OpenWindow(true)
	end

	if not SLASH_RL1 then
		SLASH_RL1 = "/rl"
		SlashCmdList["RL"] = function()
			C_UI.Reload()
		end
	end
end

---@class Config
---@field Init fun(self: table)
---@field EnsureWindow fun(self: table): table
---@field Apply fun(self: table, settingsKey: string?)
---@field Migrator DbMigrator
---@field Window table? The options window, nil until EnsureWindow has built it.
---@field TabController TabReturn? Nil until EnsureWindow has built the window.
---@field General GeneralConfig
---@field Portraits PortraitsConfig
---@field CrowdControl CrowdControlConfig
---@field PetCrowdControl PetCrowdControlConfig
---@field Healer HealerCrowdControlConfig
---@field Alerts AlertsConfig
---@field Nameplates NameplatesConfig
---@field EnemyKickTracker EnemyKickTrackerConfig
---@field AllyKickTracker AllyKickTrackerConfig
---@field OtherAddons OtherAddonsConfig
---@field ImportantAuras ImportantAurasConfig
---@field FrameAuras FrameAurasConfig
---@field PersonalAuras PersonalAurasConfig
---@field Miscellaneous MiscellaneousConfig
