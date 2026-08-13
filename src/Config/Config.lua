---@type string, Addon
local addonName, addon = ...
local dbMigrator = addon.Config.Migrator
local mini = addon.Framework
local L = addon.L
---@type Db
local db
local M = addon.Config

local NAV_ICON_BASE = "Interface\\AddOns\\" .. addonName .. "\\Icons\\Nav\\"

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
	message:SetText(L["Use /miniauras, /minia, or /cc to open the MiniAuras config window."])

	local button = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	button:SetSize(240, 32)
	button:SetPoint("TOP", message, "BOTTOM", 0, -20)
	button:SetText(L["Open Settings"])
	-- 14pt via font objects, not a raw SetFont path: the path drops the per-locale
	-- glyph fallbacks (Cyrillic boxes), and hover swaps font objects anyway.
	button:SetNormalFontObject(GameFontNormalMed3)
	button:SetHighlightFontObject(GameFontHighlightMedium)
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
				mini:RunWhenCombatEnds(HideSettings, "MiniAuras_HideSettingsPanel")
			else
				HideSettings()
			end
		end

		M.Window:Show()
	end)
end

---Applies a settings change. A ModuleName key scopes the refresh to the one module whose
---settings table changed - sliders and colour pickers fire this per drag step, so refreshing all
---eleven modules each time is real cost. No key means the change has addon-wide reach and
---everything refreshes.
---@param settingsKey string? A ModuleName value naming the db.Modules table that changed.
function M:Apply(settingsKey)
	if settingsKey then
		addon:RefreshModule(settingsKey)
	else
		addon:Refresh()
	end
end

function M:Init()
	db = dbMigrator:GetAndUpgradeDb()

	-- MiniAuras is the one addon that runs its own window rather than a Blizzard panel, so it
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

	-- While test mode is live the button fills with a pulsing accent wash and says so, so the
	-- fake icons on screen always have a visible explanation. The wash is a separate texture:
	-- the button's own backdrop is driven by its hover scripts and can't be animated.
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

	-- The nav strip sits flush with the window's left edge and the title bar's accent line,
	-- rather than inside Content's padding; pages keep their old position via ContentInsets.
	local tabsPanel = CreateFrame("Frame", nil, window)
	tabsPanel:SetPoint("TOPLEFT", window.TitleBar, "BOTTOMLEFT", 0, -1)
	-- Anchored to the window rather than window.Content so the nav strip and pages run flush
	-- to the bottom border, like the strip already does at the top and left. The x inset keeps
	-- the Content frame's right padding (ContentPadding 12 + 1px border); y 1 clears the border.
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
			Key = "CustomAuras",
			Title = L["Custom Auras_Short"] or L["Custom Auras"],
			Icon = NAV_ICON_BASE .. "CustomAuras.png",
			Build = function(content)
				M.CustomAuras:Build(content)
			end,
		},
		{
			Key = "RaidFrameAuras",
			Title = L["Raid Frame Auras_Short"] or L["Raid Frame Auras"],
			Icon = NAV_ICON_BASE .. "RaidFrameAuras.png",
			Build = function(content)
				local m = db.Modules.RaidFrameAurasModule
				M.RaidFrameAuras:Build(content, m.Default, m.Raid)
			end,
		},
		{
			Key = "Alerts",
			Title = L["Alerts"],
			Icon = NAV_ICON_BASE .. "Alerts.png",
			Build = function(content)
				M.Alerts:Build(content, db.Modules.AlertsModule)
			end,
		},
		{
			Key = "Nameplates",
			Title = L["Nameplates_Short"] or L["Nameplates"],
			Icon = NAV_ICON_BASE .. "Nameplates.png",
			Build = function(content)
				M.Nameplates:Build(content, db.Modules.NameplatesModule)
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
				M.CrowdControl:Build(content, db.Modules.CCModule.Default, db.Modules.CCModule.Raid)
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
				M.Healer:Build(content, db.Modules.HealerCCModule)
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
				M.AllyKickTracker:Build(content, db.Modules.AllyKickTrackerModule)
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
		-- Restores the content padding the flush tabsPanel no longer provides, so pages sit
		-- exactly where they did when the tabs were parented to window.Content.
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

	SLASH_MINIAURAS1 = "/miniauras"
	-- Not /minia: Blizzard's main assist command owns that and wins the parse, so it never reaches us.
	SLASH_MINIAURAS2 = "/minia"
	-- The MiniCC-era aliases stay registered; people have them in macros and muscle memory.
	SLASH_MINIAURAS3 = "/minicc"
	SLASH_MINIAURAS4 = "/mcc"
	SLASH_MINIAURAS5 = "/cc"

	SlashCmdList.MINIAURAS = function(msg)
		msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

		if msg == "test" then
			addon:ToggleTest(nil)
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
---@field Apply fun(self: table, settingsKey: string?)
---@field Migrator DbMigrator
---@field TabController TabReturn
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
---@field RaidFrameAuras RaidFrameAurasConfig
---@field CustomAuras CustomAurasConfig
---@field Miscellaneous MiscellaneousConfig
