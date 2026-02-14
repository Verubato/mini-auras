---@type string, Addon
local addonName, addon = ...
local mini = addon.Core.Framework
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
---@type Db
local db

---@class Db
local dbDefaults = {
	Version = 19,
	WhatsNew = {},
	NotifiedChanges = true,
	Modules = {
		---@class CcModuleOptions
		CcModule = {
			Enabled = {
				Always = true,
				Arena = true,
				Raids = false,
				Dungeons = true,
			},

			---@class CcInstanceOptions
			Default = {
				ExcludePlayer = false,
				Offset = {
					X = 2,
					Y = 0,
				},
				Grow = "RIGHT",

				Icons = {
					Size = 50,
					Glow = true,
					ReverseCooldown = true,
					ColorByDispelType = true,
				},
			},

			---@type CcInstanceOptions
			Raid = {
				ExcludePlayer = false,
				Offset = {
					X = 2,
					Y = 0,
				},
				Grow = "CENTER",

				Icons = {
					Size = 50,
					Glow = true,
					ReverseCooldown = true,
					ColorByDispelType = true,
				},
			},
		},
		---@class HealerCcModuleOptions
		HealerCcModule = {
			Enabled = {
				Always = true,
				Arena = true,
				Raids = false,
				Dungeons = true,
			},

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
				ReverseCooldown = true,
				ColorByDispelType = true,
			},

			Font = {
				File = "Fonts\\FRIZQT__.TTF",
				Size = 32,
				Flags = "OUTLINE",
			},
		},
		---@class PortraitModuleOptions
		PortraitModule = {
			Enabled = {
				Always = true,
			},

			ReverseCooldown = true,
		},
		---@class AlertsModuleOptions
		AlertsModule = {
			Enabled = {
				Always = true,
			},

			IncludeBigDefensives = true,
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
				ReverseCooldown = true,
				ColorByClass = true,
			},
		},
		---@class NameplateModuleOptions
		NameplatesModule = {
			Enabled = {
				Always = true,
				Arena = true,
				Raids = false,
				Dungeons = false,
			},

			---@class NameplateFactionOptions
			Friendly = {
				IgnorePets = true,
				---@class NameplateSpellTypeOptions
				CC = {
					Enabled = false,
					Grow = "RIGHT",
					Offset = {
						X = 2,
						Y = 0,
					},

					Icons = {
						Size = 50,
						Glow = true,
						ReverseCooldown = true,
						ColorByDispelType = true,
						MaxIcons = 5,
					},
				},
				Important = {
					Enabled = false,
					Grow = "LEFT",
					Offset = {
						X = -2,
						Y = 0,
					},

					Icons = {
						Size = 50,
						Glow = true,
						ReverseCooldown = true,
						ColorByDispelType = true,
						MaxIcons = 5,
					},
				},
				Combined = {
					Enabled = false,
					Grow = "RIGHT",
					Offset = {
						X = 2,
						Y = 0,
					},

					Icons = {
						Size = 50,
						Glow = true,
						ReverseCooldown = true,
						ColorByDispelType = true,
						MaxIcons = 5,
					},
				},
			},
			Enemy = {
				IgnorePets = true,
				CC = {
					Enabled = true,
					Grow = "RIGHT",
					Offset = {
						X = 2,
						Y = 0,
					},

					Icons = {
						Size = 50,
						Glow = true,
						ReverseCooldown = true,
						ColorByDispelType = true,
						MaxIcons = 5,
					},
				},
				Important = {
					Enabled = true,
					Grow = "LEFT",
					Offset = {
						X = -2,
						Y = 0,
					},

					Icons = {
						Size = 50,
						Glow = true,
						ColorByDispelType = true,
						MaxIcons = 5,
					},
				},
				Combined = {
					Enabled = false,
					Grow = "RIGHT",
					Offset = {
						X = 2,
						Y = 0,
					},

					Icons = {
						Size = 50,
						Glow = true,
						ReverseCooldown = true,
						ColorByDispelType = true,
						MaxIcons = 5,
					},
				},
			},
		},
		---@class KickTimerModuleOptions
		KickTimerModule = {
			Enabled = {
				Always = false,
				Caster = true,
				Healer = true,
			},

			Point = "CENTER",
			RelativeTo = "UIParent",
			RelativePoint = "CENTER",
			Offset = {
				X = 0,
				Y = -200,
			},

			Icons = {
				Size = 50,
				Glow = false,
				ReverseCooldown = true,
			},
		},
		---@class TrinketsModuleOptions
		TrinketsModule = {
			Enabled = {
				Always = true,
			},

			Point = "RIGHT",
			RelativePoint = "LEFT",
			Offset = {
				X = -2,
				Y = 0,
			},

			Icons = {
				Size = 50,
				Glow = false,
				ReverseCooldown = false,
				ShowText = true,
			},

			Font = {
				File = "GameFontHighlightSmall",
			},
		},
		---@class FriendlyIndicatorModuleOptions
		FriendlyIndicatorModule = {
			Enabled = {
				Always = true,
				Arena = true,
				Raids = true,
				Dungeons = true,
			},

			ExcludePlayer = false,

			Offset = {
				X = 0,
				Y = 0,
			},
			Grow = "CENTER",

			Icons = {
				Size = 40,
				Glow = true,
				ReverseCooldown = true,
			},
		},
	},
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
		mini:CleanTable(vars, dbDefaults, true, true)
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

		mini:CleanTable(vars, dbDefaults, true, true)
		vars.Version = 4
	end

	if vars.Version == 4 then
		vars.Raid = vars.BattleGrounds
		vars.BattleGrounds = nil

		vars.Default = vars.Arena
		vars.Arena = nil
		mini:CleanTable(vars, dbDefaults, true, true)
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
		vars.WhatsNew = vars.WhatsNew or {}
		table.insert(vars.WhatsNew, " - New spell alerts bar that shows enemy cooldowns.")
		vars.Version = 9
	end

	if vars.Version == 9 then
		vars.WhatsNew = vars.WhatsNew or {}
		table.insert(vars.WhatsNew, " - New feature to show enemy cooldowns on nameplates.")
		vars.NotifiedChanges = false
		vars.Version = 10
	end

	if vars.Version == 10 then
		-- they may not have the nameplates table yet if upgrading from say v8
		if vars.Nameplates then
			vars.Nameplates.FriendlyEnabled = vars.Nameplates.Enabled
			vars.Nameplates.EnemyEnabled = vars.Nameplates.Enabled
		end
		vars.Version = 11
	end

	if vars.Version == 11 then
		-- get the new nameplate config
		vars = mini:GetSavedVars(dbDefaults)

		vars.Nameplates.Friendly.CC.Enabled = vars.Nameplates.FriendlyEnabled
		vars.Nameplates.Friendly.Important.Enabled = vars.Nameplates.FriendlyEnabled

		vars.Nameplates.Enemy.CC.Enabled = vars.Nameplates.EnemyEnabled
		vars.Nameplates.Enemy.Important.Enabled = vars.Nameplates.EnemyEnabled

		table.insert(vars.WhatsNew, " - Separated CC and important spell positions on nameplates.")
		vars.NotifiedChanges = false

		-- clean up old values
		mini:CleanTable(db, dbDefaults, true, true)
		vars.Version = 12
	end

	if vars.Version == 12 then
		table.insert(vars.WhatsNew, " - New poor man's kick timer (don't get too excited, it's really basic).")
		table.insert(vars.WhatsNew, " - Various bug fixes and performance improvements.")
		vars.NotifiedChanges = false
		vars.Version = 13
	end

	if vars.Version == 13 then
		table.insert(vars.WhatsNew, " - Added pet portrait CC icon.")
		vars.NotifiedChanges = false
		vars.Version = 14
	end

	if vars.Version == 14 then
		table.insert(vars.WhatsNew, " - Improved kick detection logic (can now detect who kicked you).")
		table.insert(vars.WhatsNew, " - Added party trinkets tracker.")
		table.insert(vars.WhatsNew, " - Added Shadowed Unit Frames and Plexus frames support.")
		table.insert(vars.WhatsNew, " - Improved addon performance.")
		vars.NotifiedChanges = false
		vars.Version = 15
	end

	if vars.Version == 15 then
		table.insert(vars.WhatsNew, " - New ally CDs frame that shows active defensives and offensive cooldowns.")
		vars.NotifiedChanges = false
		vars.Version = 16
	end

	if vars.Version == 16 then
		table.insert(vars.WhatsNew, " - Added option to color alert glows by enemy class color (enabled by default).")
		vars.NotifiedChanges = false
		vars.Version = 17
	end

	-- commence massive refactor
	if vars.Version == 17 then
		-- Move Default and Raid configs into Modules.CcModule
		if vars.Default then
			vars.Modules = vars.Modules or {}
			vars.Modules.CcModule = vars.Modules.CcModule or {}
			vars.Modules.CcModule.Default = mini:CopyTable(vars.Default)
			vars.Modules.CcModule.Enabled = {
				Always = vars.Default.Enabled,
				Arena = vars.Default.Enabled,
				Raids = vars.Raid and vars.Raid.Enabled,
				Dungeons = vars.Raid and vars.Raid.Enabled,
			}
			vars.Modules.CcModule.Default.Grow = vars.Default.SimpleMode.Grow
			vars.Modules.CcModule.Default.Offset = mini:CopyTable(vars.Default.SimpleMode.Offset)
			vars.Default = nil
		end

		if vars.Raid then
			vars.Modules = vars.Modules or {}
			vars.Modules.CcModule = vars.Modules.CcModule or {}
			vars.Modules.CcModule.Raid = mini:CopyTable(vars.Raid)
			vars.Modules.CcModule.Raid.Grow = vars.Raid.SimpleMode.Grow
			vars.Modules.CcModule.Raid.Offset = mini:CopyTable(vars.Raid.SimpleMode.Offset)
			vars.Raid = nil
		end

		-- Move AllyIndicator config into Modules.AllyIndicatorModule
		if vars.AllyIndicator then
			vars.Modules = vars.Modules or {}
			vars.Modules.FriendlyIndicatorModule = vars.Modules.FriendlyIndicatorModule or {}

			-- Merge AllyIndicator properties directly into AllyIndicatorModule
			for key, value in pairs(vars.AllyIndicator) do
				vars.Modules.FriendlyIndicatorModule[key] = mini:CopyValueOrTable(value)
			end

			vars.Modules.FriendlyIndicatorModule.Enabled = {
				Always = vars.AllyIndicator.Enabled,
				Arena = false,
				Raids = false,
				Dungeons = false,
			}
			vars.AllyIndicator = nil
		end

		-- Move Healer config into Modules.HealerCcModule
		if vars.Healer then
			vars.Modules = vars.Modules or {}
			vars.Modules.HealerCcModule = vars.Modules.HealerCcModule or {}

			-- Merge Healer properties directly into HealerCcModule
			for key, value in pairs(vars.Healer) do
				vars.Modules.HealerCcModule[key] = mini:CopyValueOrTable(value)
			end

			vars.Modules.HealerCcModule.Enabled = {
				Always = vars.Healer.Enabled,
				Arena = vars.Healer.Filters.Arena,
				BattleGrounds = vars.Healer.BattleGrounds,
				Dungeons = vars.Healer.Enabled,
			}

			vars.Healer = nil
		end

		-- Move Alerts config into Modules.AlertsModule
		if vars.Alerts then
			vars.Modules = vars.Modules or {}
			vars.Modules.AlertsModule = vars.Modules.AlertsModule or {}

			-- Merge Alerts properties directly into AlertsModule
			for key, value in pairs(vars.Alerts) do
				vars.Modules.AlertsModule[key] = mini:CopyValueOrTable(value)
			end

			vars.Modules.AlertsModule.Enabled = {
				Always = vars.Alerts.Enabled,
			}
			vars.Alerts = nil
		end

		-- Move Portrait config into Modules.PortraitModule
		if vars.Portrait then
			vars.Modules = vars.Modules or {}
			vars.Modules.PortraitModule = vars.Modules.PortraitModule or {}

			-- Merge Portrait properties directly into PortraitModule
			for key, value in pairs(vars.Portrait) do
				vars.Modules.PortraitModule[key] = mini:CopyValueOrTable(value)
			end

			vars.Modules.PortraitModule.Enabled = {
				Always = vars.Portrait.Enabled,
			}
			vars.Portrait = nil
		end

		-- Move Nameplates config into Modules.NameplatesModule
		if vars.Nameplates then
			vars.Modules = vars.Modules or {}
			vars.Modules.NameplatesModule = vars.Modules.NameplatesModule or {}

			-- Merge Nameplates properties directly into NameplatesModule
			for key, value in pairs(vars.Nameplates) do
				vars.Modules.NameplatesModule[key] = mini:CopyValueOrTable(value)
			end

			vars.Modules.NameplatesModule.Enabled = {
				Always = true,
			}
			vars.Nameplates = nil
		end

		-- Move KickTimer config into Modules.KickTimerModule
		if vars.KickTimer then
			vars.Modules = vars.Modules or {}
			vars.Modules.KickTimerModule = vars.Modules.KickTimerModule or {}

			-- Merge KickTimer properties directly into KickTimerModule
			for key, value in pairs(vars.KickTimer) do
				vars.Modules.KickTimerModule[key] = mini:CopyValueOrTable(value)
			end

			vars.Modules.KickTimerModule.Enabled = {
				Always = vars.KickTimer.AllEnabled,
				Caster = vars.KickTimer.CasterEnabled,
				Healer = vars.KickTimer.HealerEnabled,
			}
			vars.KickTimer = nil
		end

		-- Move Trinkets config into Modules.TrinketsModule
		if vars.Trinkets then
			vars.Modules = vars.Modules or {}
			vars.Modules.TrinketsModule = vars.Modules.TrinketsModule or {}

			-- Merge Trinkets properties directly into TrinketsModule
			for key, value in pairs(vars.Trinkets) do
				vars.Modules.TrinketsModule[key] = mini:CopyValueOrTable(value)
			end

			vars.Modules.TrinketsModule.Enabled = { Always = vars.Trinkets.Enabled }
			vars.Trinkets = nil
		end

		mini:CleanTable(vars, dbDefaults, true, true)
		vars.Version = 18
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
			"Shows CC and other important spell alerts for pvp.",
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
			Title = "General",
			Build = function(content)
				config.General:Build(content)
			end,
		},
		{
			Key = keys.CC,
			Title = "CC",
			Build = function(content)
				config.CcConfig:Build(content, db.Modules.CcModule.Default, db.Modules.CcModule.Raid)
			end,
		},
		{
			Key = keys.CDs,
			Title = "CDs",
			Build = function(content)
				config.FriendlyIndicator:Build(content, db.Modules.FriendlyIndicatorModule)
			end,
		},
		{
			Key = keys.Alerts,
			Title = "Alerts",
			Build = function(content)
				config.Alerts:Build(content, db.Modules.AlertsModule)
			end,
		},
		{
			Key = keys.Healer,
			Title = "Healer",
			Build = function(content)
				config.Healer:Build(content, db.Modules.HealerCcModule)
			end,
		},
		{
			Key = keys.Nameplates,
			Title = "Nameplates",
			Build = function(content)
				config.Nameplates:Build(content, db.Modules.NameplatesModule)
			end,
		},
		{
			Key = keys.Portraits,
			Title = "Portraits",
			Build = function(content)
				config.Portraits:Build(content)
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
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		local options = db.Modules.CcModule.Default
		addon:ToggleTest(options)
	end)

	config.TabController = tabController

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
			addon:ToggleTest(db.Modules.CcModule.Default)
			return
		end

		mini:OpenSettings(category, panel)
	end

	local kickTimerPanel = config.KickTimer:Build()
	kickTimerPanel.name = "Kick Timer"

	mini:AddSubCategory(category, kickTimerPanel)

	local trinketsPanel = config.Trinkets:Build()
	trinketsPanel.name = "Trinkets"

	mini:AddSubCategory(category, trinketsPanel)

	local otherAddonsPanel = config.OtherAddons:Build()
	otherAddonsPanel.name = "Other Addons"

	mini:AddSubCategory(category, otherAddonsPanel)
end

---@class Config
---@field Init fun(self: table)
---@field Apply fun(self: table)
---@field DbDefaults Db
---@field TabController TabReturn
---@field General GeneralConfig
---@field Portraits PortraitsConfig
---@field CcConfig CcConfig
---@field Anchors AnchorsConfig
---@field Healer HealerConfig
---@field Alerts AlertsConfig
---@field Nameplates NameplatesConfig
---@field KickTimer KickTimerConfig
---@field Trinkets TrinketsConfig
---@field OtherAddons OtherAddonsConfig
---@field FriendlyIndicator FriendlyIndicatorConfig
