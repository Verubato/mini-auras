---@diagnostic disable: unused-function
---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
---@class Db
local dbDefaults = {
	Version = 23,
	WhatsNew = {},
	NotifiedChanges = true,
	GlowType = "Proc Glow",
	FontScale = 1.0,
	Modules = {
		---@class CrowdControlModuleOptions
		CCModule = {
			Enabled = {
				Always = true,
				Arena = true,
				Raids = false,
				Dungeons = true,
			},

			---@class CrowdControlInstanceOptions
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

			---@type CrowdControlInstanceOptions
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
		---@class HealerCrowdControlModuleOptions
		HealerCCModule = {
			Enabled = {
				Always = true,
				Arena = true,
				Raids = false,
				Dungeons = true,
			},

			Sound = {
				Enabled = true,
				Channel = "Master",
				File = "Sonar.ogg",
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

			ShowWarningText = true,
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

			Sound = {
				Important = {
					Enabled = false,
					Channel = "Master",
					File = "AirHorn.ogg",
				},
				Defensive = {
					Enabled = false,
					Channel = "Master",
					File = "AlertToastWarm.ogg",
				},
			},

			TTS = {
				Volume = 100,
				Important = {
					Enabled = false,
				},
				Defensive = {
					Enabled = false,
				},
			},

			Icons = {
				Enabled = true,
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
						ColorByCategory = true,
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
						ColorByCategory = true,
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
						ColorByCategory = true,
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
						ColorByCategory = true,
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
						ReverseCooldown = true,
						ColorByCategory = true,
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
						ColorByCategory = true,
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

			ExcludePlayer = false,

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
				MaxIcons = 1,
			},
		},
	},
}

---@class DbMigrator
local M = {}
addon.Config.Migrator = M

function M:UpgradeToVersion1(vars)
	if vars.Version then
		return false
	end

	local v1Defaults = {
		Version = 1,

		SimpleMode = {
			Enabled = true,
			Offset = {
				X = 2,
				Y = 0,
			},
		},

		AdvancedMode = {
			Enabled = false,
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
			Padding = {
				X = 2,
				Y = 0,
			},
		},

		Container = {
			Point = "TOPLEFT",
			RelativePoint = "TOPRIGHT",
			Offset = {
				X = 2,
				Y = 0,
			},
		},

		Anchor1 = "CompactPartyFrameMember1",
		Anchor2 = "CompactPartyFrameMember2",
		Anchor3 = "CompactPartyFrameMember3",
	}

	mini:CopyTable(v1Defaults, vars)
	vars.Version = 1

	return true
end

function M:UpgradeToVersion2(vars)
	-- allow nil vars.Version as the 1st version didn't have one
	if vars.Version ~= 1 then
		return false
	end

	vars.SimpleMode = vars.SimpleMode or {}
	vars.SimpleMode.Enabled = true
	vars.Version = 2

	return true
end

function M:UpgradeToVersion3(vars)
	if vars.Version ~= 2 then
		return false
	end

	-- made some strucure changes
	local v3Defaults = {
		Version = 3,

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
		},

		Container = {
			Point = "TOPLEFT",
			RelativePoint = "TOPRIGHT",
			Offset = {
				X = 2,
				Y = 0,
			},
		},

		Anchor1 = "CompactPartyFrameMember1",
		Anchor2 = "CompactPartyFrameMember2",
		Anchor3 = "CompactPartyFrameMember3",
	}

	mini:CleanTable(vars, v3Defaults, true, true)
	vars.Version = 3

	return true
end

function M:UpgradeToVersion4(vars)
	if vars.Version ~= 3 then
		return false
	end

	print("Simple", vars.SimpleMode, "Advanced", vars.AdvancedMode, "Icons", vars.Icons)

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

	local v4Defaults = {
		Version = 4,

		ArenaOnly = false,
		ExcludePlayer = false,

		Arena = {
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
			},
		},

		BattleGrounds = {
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
			},
		},

		Anchor1 = "CompactPartyFrameMember1",
		Anchor2 = "CompactPartyFrameMember2",
		Anchor3 = "CompactPartyFrameMember3",
	}

	mini:CleanTable(vars, v4Defaults, true, true)
	vars.Version = 4

	return true
end

function M:UpgradeToVersion5(vars)
	if vars.Version ~= 4 then
		return false
	end

	vars.Raid = vars.BattleGrounds
	vars.BattleGrounds = nil

	vars.Default = vars.Arena
	vars.Arena = nil

	local v5Defaults = {
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
			},
		},

		Anchor1 = "CompactPartyFrameMember1",
		Anchor2 = "CompactPartyFrameMember2",
		Anchor3 = "CompactPartyFrameMember3",
	}
	mini:CleanTable(vars, v5Defaults, true, true)
	vars.Version = 5

	return true
end

function M:UpgradeToVersion6(vars)
	if vars.Version ~= 5 then
		return false
	end

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

	return true
end

function M:UpgradeToVersion7(vars)
	if vars.Version ~= 6 then
		return false
	end

	vars.NotifiedChanges = false
	vars.Version = 7

	return true
end

function M:UpgradeToVersion8(vars)
	if vars.Version ~= 7 then
		return false
	end

	vars.NotifiedChanges = false
	vars.Version = 8

	return true
end

function M:UpgradeToVersion9(vars)
	if vars.Version ~= 8 then
		return false
	end

	vars.NotifiedChanges = false
	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, " - New spell alerts bar that shows enemy cooldowns.")
	vars.Version = 9

	return true
end

function M:UpgradeToVersion10(vars)
	if vars.Version ~= 9 then
		return false
	end

	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, " - New feature to show enemy cooldowns on nameplates.")
	vars.NotifiedChanges = false
	vars.Version = 10

	return true
end

function M:UpgradeToVersion11(vars)
	if vars.Version ~= 10 then
		return false
	end

	-- they may not have the nameplates table yet if upgrading from say v8
	if vars.Nameplates then
		vars.Nameplates.FriendlyEnabled = vars.Nameplates.Enabled
		vars.Nameplates.EnemyEnabled = vars.Nameplates.Enabled
	end
	vars.Version = 11

	return true
end

function M:UpgradeToVersion12(vars)
	if vars.Version ~= 11 then
		return false
	end

	local v12Defaults = {
		Version = 12,
		WhatsNew = {},

		NotifiedChanges = true,

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
				Grow = "RIGHT",
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
				ReverseCooldown = true,
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
				Grow = "CENTER",
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
				ReverseCooldown = true,
				ColorByDispelType = true,
			},
		},

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
				ReverseCooldown = true,
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
				ReverseCooldown = true,
			},
		},

		Nameplates = {
			Friendly = {
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

		Portrait = {
			Enabled = true,
			ReverseCooldown = true,
		},

		Anchor1 = "",
		Anchor2 = "",
		Anchor3 = "",
	}

	-- get the new nameplate config
	vars = mini:GetSavedVars(v12Defaults)

	-- db defaults may have changed since then
	if vars.Nameplates and vars.Nameplates.Friendly and vars.Nameplates.Enemy then
		vars.Nameplates.Friendly.CC.Enabled = vars.Nameplates.FriendlyEnabled
		vars.Nameplates.Friendly.Important.Enabled = vars.Nameplates.FriendlyEnabled

		vars.Nameplates.Enemy.CC.Enabled = vars.Nameplates.EnemyEnabled
		vars.Nameplates.Enemy.Important.Enabled = vars.Nameplates.EnemyEnabled
	end

	table.insert(vars.WhatsNew, " - Separated CC and important spell positions on nameplates.")
	vars.NotifiedChanges = false

	-- clean up old values
	mini:CleanTable(vars, v12Defaults, true, true)
	vars.Version = 12

	return true
end

function M:UpgradeToVersion13(vars)
	if vars.Version ~= 12 then
		return false
	end

	table.insert(vars.WhatsNew, " - New poor man's kick timer (don't get too excited, it's really basic).")
	table.insert(vars.WhatsNew, " - Various bug fixes and performance improvements.")
	vars.NotifiedChanges = false
	vars.Version = 13

	return true
end

function M:UpgradeToVersion14(vars)
	if vars.Version ~= 13 then
		return false
	end

	table.insert(vars.WhatsNew, " - Added pet portrait CC icon.")
	vars.NotifiedChanges = false
	vars.Version = 14

	return true
end

function M:UpgradeToVersion15(vars)
	if vars.Version ~= 14 then
		return false
	end

	table.insert(vars.WhatsNew, " - Improved kick detection logic (can now detect who kicked you).")
	table.insert(vars.WhatsNew, " - Added party trinkets tracker.")
	table.insert(vars.WhatsNew, " - Added Shadowed Unit Frames and Plexus frames support.")
	table.insert(vars.WhatsNew, " - Improved addon performance.")
	vars.NotifiedChanges = false
	vars.Version = 15

	return true
end

function M:UpgradeToVersion16(vars)
	if vars.Version ~= 15 then
		return false
	end

	table.insert(vars.WhatsNew, " - New ally CDs frame that shows active defensives and offensive cooldowns.")
	vars.NotifiedChanges = false
	vars.Version = 16

	return true
end

function M:UpgradeToVersion17(vars)
	if vars.Version ~= 16 then
		return false
	end

	table.insert(vars.WhatsNew, " - Added option to color alert glows by enemy class color (enabled by default).")
	vars.NotifiedChanges = false
	vars.Version = 17

	return true
end

function M:UpgradeToVersion18(vars)
	if vars.Version ~= 17 then
		return false
	end

	-- commence massive refactor
	-- Move Default and Raid configs into Modules.CCModule
	if vars.Default then
		vars.Modules = vars.Modules or {}
		vars.Modules.CCModule = vars.Modules.CCModule or {}
		vars.Modules.CCModule.Default = mini:CopyTable(vars.Default)
		vars.Modules.CCModule.Enabled = {
			Always = vars.Default.Enabled,
			Arena = vars.Default.Enabled,
			Raids = vars.Raid and vars.Raid.Enabled,
			Dungeons = vars.Raid and vars.Raid.Enabled,
		}
		vars.Modules.CCModule.Default.Grow = vars.Default.SimpleMode.Grow
		vars.Modules.CCModule.Default.Offset = mini:CopyTable(vars.Default.SimpleMode.Offset)
		vars.Default = nil
	end

	if vars.Raid then
		vars.Modules = vars.Modules or {}
		vars.Modules.CCModule = vars.Modules.CCModule or {}
		vars.Modules.CCModule.Raid = mini:CopyTable(vars.Raid)
		vars.Modules.CCModule.Raid.Grow = vars.Raid.SimpleMode.Grow
		vars.Modules.CCModule.Raid.Offset = mini:CopyTable(vars.Raid.SimpleMode.Offset)
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

	-- Move Healer config into Modules.HealerCCModule
	if vars.Healer then
		vars.Modules = vars.Modules or {}
		vars.Modules.HealerCCModule = vars.Modules.HealerCCModule or {}

		-- Merge Healer properties directly into HealerCCModule
		for key, value in pairs(vars.Healer) do
			vars.Modules.HealerCCModule[key] = mini:CopyValueOrTable(value)
		end

		vars.Modules.HealerCCModule.Enabled = {
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

	local v18Defaults = {
		Version = 25,
		WhatsNew = {},
		NotifiedChanges = true,
		Modules = {
			CcModule = {
				Enabled = {
					Always = true,
					Arena = false,
					Raids = false,
					Dungeons = false,
				},
				Default = {
					ExcludePlayer = false,

					-- TODO: after a few patches once people have moved over, remove simple/advanced mode into just one single mode
					SimpleMode = {
						Enabled = true,
						Offset = {
							X = 2,
							Y = 0,
						},
						Grow = "RIGHT",
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
						ReverseCooldown = true,
						ColorByDispelType = true,
					},
				},
				Raid = {
					ExcludePlayer = false,

					SimpleMode = {
						Enabled = true,
						Offset = {
							X = 2,
							Y = 0,
						},
						Grow = "CENTER",
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
						ReverseCooldown = true,
						ColorByDispelType = true,
					},
				},
			},
			HealerCcModule = {
				Enabled = {
					Always = true,
					Arena = false,
					Raids = false,
					Dungeons = false,
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
			PortraitModule = {
				Enabled = {
					Always = true,
				},

				ReverseCooldown = true,
			},
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
			NameplatesModule = {
				Enabled = {
					Always = true,
					Arena = false,
					Raids = false,
					Dungeons = false,
				},

				Friendly = {
					IgnorePets = true,
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
			FriendlyIndicatorModule = {
				Enabled = {
					Always = true,
					Arena = false,
					Raids = false,
					Dungeons = false,
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

	mini:CleanTable(vars, v18Defaults, true, true)
	vars.Version = 18

	return true
end

function M:UpgradeToVersion19(vars)
	if vars.Version ~= 18 then
		return false
	end

	-- Rename CcModule to CCModule
	if vars.Modules and vars.Modules.CcModule then
		vars.Modules.CCModule = vars.Modules.CcModule
		vars.Modules.CcModule = nil
	end

	-- Rename HealerCcModule to HealerCCModule
	if vars.Modules and vars.Modules.HealerCcModule then
		vars.Modules.HealerCCModule = vars.Modules.HealerCcModule
		vars.Modules.HealerCcModule = nil
	end

	vars.Version = 19
	return true
end

function M:UpgradeToVersion20(vars)
	if vars.Version ~= 19 then
		return false
	end

	-- accident, update db migration to the same value as db defaults
	vars.Version = 20
	return true
end

function M:UpgradeToVersion21(vars)
	if vars.Version ~= 20 then
		return false
	end

	-- removed this glow type as it doesn't support secrets
	if vars.GlowType == "Action Button Glow" then
		vars.GlowType = "Proc Glow"
	end

	vars.Version = 21
	return true
end

function M:UpgradeToVersion22(vars)
	if vars.Version ~= 21 then
		return false
	end

	-- Add ShowWarningText option to HealerCCModule (default on)
	if vars.Modules and vars.Modules.HealerCCModule then
		vars.Modules.HealerCCModule.ShowWarningText = true
	end

	vars.Version = 22
	return true
end

function M:UpgradeToVersion23(vars)
	if vars.Version ~= 22 then
		return false
	end

	vars.Modules.AlertsModule.Sound = {
		Important = {
			Enabled = false,
			Channel = "Master",
			File = "AirHorn.ogg",
		},
		Defensive = {
			Enabled = false,
			Channel = "Master",
			File = "AlertToastWarm.ogg",
		},
	}

	vars.Modules.AlertsModule.TTS = {
		Volume = 100,
		Important = {
			Enabled = false,
		},
		Defensive = {
			Enabled = false,
		},
	}

	-- might as well clean up any garbage while we're here
	-- do this before we add stuff to what's new otherwise it'll get cleared
	mini:CleanTable(vars, dbDefaults, true, true)

	table.insert(vars.WhatsNew, " - Added important and defensive alert sound effects.")
	table.insert(vars.WhatsNew, " - Added text to speech functionality in the alerts module (i.e. GladiatorlosSA).")

	vars.NotifiedChanges = false
	vars.Version = 23
	return true
end

---@return Db
function M:GetAndUpgradeDb()
	local vars = mini:GetSavedVars()

	if vars == nil then
		-- fresh install
		return mini:GetSavedVars(dbDefaults)
	end

	if vars.Version and vars.Version > dbDefaults.Version then
		-- they are running some version ahead of us, let's reset to factory
		return M:SoftReset()
	end

	local isCorrupt = false

	while (vars.Version or 0) < dbDefaults.Version do
		local currentVersion = vars.Version or 0
		local nextVersion = currentVersion + 1
		local upgradeFn = M["UpgradeToVersion" .. nextVersion]

		isCorrupt = upgradeFn == nil

		if isCorrupt then
			break
		end

		local ok, result = pcall(upgradeFn, self, vars)

		if not ok or not result then
			isCorrupt = true
			break
		end
	end

	if isCorrupt then
		return M:SoftReset()
	end

	-- grab any new keys
	vars = mini:GetSavedVars(dbDefaults)

	return vars
end

---@return Db
function M:ResetToFactory()
	return mini:ResetSavedVars(dbDefaults)
end

function M:SoftReset()
	-- grab any new keys
	local vars = mini:GetSavedVars(dbDefaults)

	-- clean up any garbage
	mini:CleanTable(vars, dbDefaults, true, true)

	return vars
end
