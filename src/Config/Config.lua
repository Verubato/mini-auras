---@type string, Addon
local addonName, addon = ...
local capabilities = addon.Capabilities
local mini = addon.Framework
local verticalSpacing = mini.VerticalSpacing
---@type Db
local db

---@class Db
local dbDefaults = {
	Version = 5,

	---@class InstanceOptions
	Default = {
		Enabled = true,
		ExcludePlayer = false,

		SimpleMode = {
			Enabled = true,
			Offset = {
				X = 2,
				Y = 0,
			},
		},

		AdvancedMode = {
			Point = "TOPLEFT",
			RelativePoint = "TOPRIGHT",
			Offset = {
				X = 2,
				Y = 0,
			},
		},

		---@class IconOptions
		Icons = {
			Size = 72,
			Glow = true,
			ReverseCooldown = false,
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
			Size = 72,
			Glow = true,
			ReverseSwipe = false,
		},
	},

	---@class HealerOptions
	Healer = {
		Enabled = false,

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
			ReverseSwipe = false,
		},
	},

	Anchor1 = "CompactPartyFrameMember1",
	Anchor2 = "CompactPartyFrameMember2",
	Anchor3 = "CompactPartyFrameMember3",
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
			"Shows CC on your party/raid frames.",
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
			if key == keys.Arena then
				addon:TestOptions(db.Arena)
			elseif key == keys.BattleGrounds then
				addon:TestOptions(db.BattleGrounds)
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
	resetBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 16)
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
