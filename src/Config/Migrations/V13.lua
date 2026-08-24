---@diagnostic disable: unused-function
local _, addon = ...
local mini = addon.Framework
local M = addon.Config.Migrator

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

		for key, value in pairs(vars.Healer) do
			vars.Modules.HealerCCModule[key] = mini:CopyValueOrTable(value)
		end

		vars.Modules.HealerCCModule.Enabled = {
			Always = vars.Healer.Enabled,
			Arena = vars.Healer.Filters.Arena,
			Raids = vars.Healer.BattleGrounds,
			Dungeons = vars.Healer.Enabled,
		}

		vars.Healer = nil
	end

	-- Move Alerts config into Modules.AlertsModule
	if vars.Alerts then
		vars.Modules = vars.Modules or {}
		vars.Modules.AlertsModule = vars.Modules.AlertsModule or {}

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

				IncludeDefensives = true,
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

