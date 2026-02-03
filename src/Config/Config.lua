---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local verticalSpacing = mini.VerticalSpacing
---@type Db
local db

---@class Db
local dbDefaults = {
	Version = 9,

	NotifiedChanges = true,

	---@class InstanceOptions : HeaderOptions
	Default = {
		Enabled = true,
		ExcludePlayer = false,

		-- TODO: after a few patches once people have moved over, remove simple/advanced mode into just one single mode
		SimpleMode = {
			Enabled = true,
			Offset = {
				X = 2,
				Y = 0,
			},
			Grow = "RIGHT"
		},

		AdvancedMode = {
			Point = "TOPLEFT",
			RelativePoint = "TOPRIGHT",
			Offset = {
				X = 2,
				Y = 0,
			},
		},

		Icons = {
			Size = 50,
			Glow = true,
			ReverseCooldown = false,
			ColorByDispelType = true,
		},
	},

	Raid = {
		Enabled = true,
		ExcludePlayer = false,

		SimpleMode = {
			Enabled = true,
			Offset = {
				X = 2,
				Y = 0,
			},
			Grow = "CENTER"
		},

		AdvancedMode = {
			Point = "TOPLEFT",
			RelativePoint = "TOPRIGHT",
			Offset = {
				X = 2,
				Y = 0,
			},
		},

		Icons = {
			Size = 50,
			Glow = true,
			ReverseCooldown = false,
			ColorByDispelType = true,
		},
	},

	---@class HealerOptions
	Healer = {
		Enabled = false,
		Sound = {
			Enabled = true,
			Channel = "Master",
		},

		Point = "CENTER",
		RelativePoint = "TOP",
		RelativeTo = "UIParent",
		Offset = {
			X = 0,
			Y = -200,
		},

		Icons = {
			Size = 72,
			Glow = true,
			ReverseCooldown = false,
			ColorByDispelType = true,
		},

		Filters = {
			Arena = true,
			BattleGrounds = false,
			World = true,
		},

		Font = {
			File = "Fonts\\FRIZQT__.TTF",
			Size = 32,
			Flags = "OUTLINE",
		},
	},

	---@class AlertOptions
	Alerts = {
		Enabled = true,
		Point = "CENTER",
		RelativePoint = "TOP",
		RelativeTo = "UIParent",

		Offset = {
			X = 0,
			Y = -100,
		},

		Icons = {
			Size = 72,
			Glow = true,
			ReverseCooldown = false,
		},
	},

	Portrait = {
		Enabled = true,
		ReverseCooldown = false,
	},

	Anchor1 = "",
	Anchor2 = "",
	Anchor3 = "",
}

local config = {}
config.DbDefaults = dbDefaults
addon.Config = config

local function GetAndUpgradeDb()
	local vars = mini:GetSavedVars()

	if vars == nil or not vars.Version then
		vars = mini:GetSavedVars(dbDefaults)
	end

	if vars.Version == 1 then
		vars.SimpleMode = vars.SimpleMode or {}
		vars.SimpleMode.Enabled = true
		vars.Version = 2
	end

	if vars.Version == 2 then
		-- made some strucure changes
		mini:CleanTable(db, dbDefaults, true, true)
		vars.Version = 3
	end

	if vars.Version == 3 then
		vars.Arena = {
			SimpleMode = mini:CopyTable(vars.SimpleMode),
			AdvancedMode = mini:CopyTable(vars.AdvancedMode),
			Icons = mini:CopyTable(vars.Icons),
			Enabled = true,
			ExcludePlayer = vars.ExcludePlayer,
		}

		vars.BattleGrounds = {
			SimpleMode = mini:CopyTable(vars.SimpleMode),
			AdvancedMode = mini:CopyTable(vars.AdvancedMode),
			Icons = mini:CopyTable(vars.Icons),
			Enabled = not vars.ArenaOnly,
			ExcludePlayer = vars.ExcludePlayer,
		}

		vars.Default = {
			SimpleMode = mini:CopyTable(vars.SimpleMode),
			AdvancedMode = mini:CopyTable(vars.AdvancedMode),
			Icons = mini:CopyTable(vars.Icons),
			Enabled = not vars.ArenaOnly,
			ExcludePlayer = vars.ExcludePlayer,
		}

		mini:CleanTable(db, dbDefaults, true, true)
		vars.Version = 4
	end

	if vars.Version == 4 then
		vars.Raid = vars.BattleGrounds
		vars.BattleGrounds = nil

		vars.Default = vars.Arena
		vars.Arena = nil
		mini:CleanTable(db, dbDefaults, true, true)
		vars.Version = 5
	end

	if vars.Version == 5 then
		if vars.Anchor1 == "CompactPartyFrameMember1" then
			vars.Anchor1 = ""
		end
		if vars.Anchor2 == "CompactPartyFrameMember2" then
			vars.Anchor2 = ""
		end
		if vars.Anchor3 == "CompactPartyFrameMember3" then
			vars.Anchor3 = ""
		end

		vars.NotifiedChanges = false
		vars.Version = 6
	end

	if vars.Version == 6 then
		vars.NotifiedChanges = false
		vars.Version = 7
	end

	if vars.Version == 7 then
		vars.NotifiedChanges = false
		vars.Version = 8
	end

	if vars.Version == 8 then
		vars.NotifiedChanges = false
		vars.Version = 9
	end

	vars = mini:GetSavedVars(dbDefaults)

	return vars
end

function config:Apply()
	if InCombatLockdown() then
		mini:Notify("Can't apply settings during combat.")
		return
	end

	addon:Refresh()
end

function config:Init()
	db = GetAndUpgradeDb()

	local panel = CreateFrame("Frame")
	panel.name = addonName

	local category = mini:AddCategory(panel)

	if not category then
		return
	end

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
	title:SetPoint("TOPLEFT", 0, -verticalSpacing)
	title:SetText(string.format("%s - %s", addonName, version))

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"Shows CC and other important spell alerts for pvp.",
		},
	})

	lines:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)

	local tabsPanel = CreateFrame("Frame", nil, panel)
	tabsPanel:SetPoint("TOPLEFT", lines, "BOTTOMLEFT", 0, -verticalSpacing)
	tabsPanel:SetPoint("BOTTOM", panel, "BOTTOM", 0, verticalSpacing * 2)

	local keys = {
		General = "General",
		Default = "Default",
		Raids = "Raids",
		Alerts = "Alerts",
		Healer = "Healer",
		Anchors = "Anchors",
	}

	local tabs = {
		{
			Key = keys.General,
			Title = "General",
			Build = function(content)
				config.General:Build(content)
			end,
		},
		{
			Key = keys.Default,
			Title = "Arena/Default",
			Build = function(content)
				config.Instance:Build(content, db.Default)
			end,
		},
		{
			Key = keys.Raids,
			Title = "BGs/Raids",
			Build = function(content)
				config.Instance:Build(content, db.Raid)
			end,
		},
		{
			Key = keys.Alerts,
			Title = "Alerts",
			Build = function(content)
				config.Alerts:Build(content, db.Alerts)
			end,
		},
		{
			Key = keys.Healer,
			Title = "Healer",
			Build = function(content)
				config.Healer:Build(content, db.Healer)
			end,
		},
		{
			Key = keys.Anchors,
			Title = "Custom Anchors",
			Build = function(content)
				config.Anchors:Build(content)
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
		OnTabChanged = function(key, _)
			-- swap the test options when the user changes tabs in case we're in test mode already
			if key == keys.Raids then
				addon:TestOptions(db.Raid)
			elseif key == keys.Default then
				addon:TestOptions(db.Default)
			end
		end,
	})

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

	local resetBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	resetBtn:SetSize(120, 26)
	resetBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, verticalSpacing)
	resetBtn:SetText("Reset")
	resetBtn:SetScript("OnClick", function()
		if InCombatLockdown() then
			mini:NotifyCombatLockdown()
			return
		end

		StaticPopup_Show("MINICC_CONFIRM", "Are you sure you wish to reset to factory settings?", nil, {
			OnYes = function()
				db = mini:ResetSavedVars(dbDefaults)

				for i = 1, #tabController.Tabs do
					local content = tabController:GetContent(tabController.Tabs[i].Key)

					if content and content.MiniRefresh then
						content:MiniRefresh()
					end
				end

				addon:Refresh()
				mini:Notify("Settings reset to default.")
			end,
		})
	end)

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, verticalSpacing)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		local options = db.Default
		local selectedTab = tabController:GetSelected()

		if selectedTab == keys.Raids then
			options = db.Raid
		end

		addon:ToggleTest(options)
	end)

	SLASH_MINICC1 = "/minicc"
	SLASH_MINICC2 = "/mcc"
	SLASH_MINICC3 = "/cc"

	SlashCmdList.MINICC = function(msg)
		-- normalize input
		msg = msg and msg:lower():match("^%s*(.-)%s*$") or ""

		if msg == "test" then
			addon:ToggleTest(db.Default)
			return
		end

		mini:OpenSettings(category, panel)
	end
end

---@class Config
---@field Init fun(self: table)
---@field Apply fun(self: table)
---@field DbDefaults Db
---@field General GeneralConfig
---@field Instance InstanceConfig
---@field Anchors AnchorsConfig
---@field Healer HealerConfig
---@field Alerts AlertsConfig

---@class HeaderOptions
---@field Enabled boolean
---@field ExcludePlayer boolean

---@class IconOptions
---@field Size number?
---@field Glow boolean?
---@field ReverseCooldown boolean?
---@field ColorByDispelType boolean?
