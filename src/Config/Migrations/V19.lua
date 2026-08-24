---@diagnostic disable: unused-function
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local M = addon.Config.Migrator

function M:UpgradeToVersion19(vars)
	if vars.Version ~= 18 then
		return false
	end

	if vars.Modules and vars.Modules.CcModule then
		vars.Modules.CCModule = vars.Modules.CcModule
		vars.Modules.CcModule = nil
	end

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

	-- Nothing to migrate, the bump only lines the db up with the defaults.
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

	local v23Defaults = {
		Version = 23,
		WhatsNew = {},
		NotifiedChanges = true,
		GlowType = "Proc Glow",
		FontScale = 1.0,
		Modules = {
			CCModule = {
				Enabled = {
					Always = true,
					Arena = true,
					Raids = false,
					Dungeons = true,
				},

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

				Sound = {
					Important = {
						Enabled = true,
						Channel = "Master",
						File = "Notification18.ogg",
					},
					Defensive = {
						Enabled = true,
						Channel = "Master",
						File = "Notification38.ogg",
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
					Size = 72,
					Glow = true,
					ReverseCooldown = true,
					ColorByClass = true,
				},
			},
			NameplatesModule = {
				Enabled = {
					Always = true,
					Arena = true,
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

	-- Cleaned against version 23's own defaults rather than the live ones, so a later schema
	-- change cannot reach back and strip what a db this old still carries.
	mini:CleanTable(vars, v23Defaults, true, true)

	table.insert(vars.WhatsNew, " - Added important and defensive alert sound effects.")
	table.insert(vars.WhatsNew, " - Added text to speech functionality in the alerts module (i.e. GladiatorlosSA).")

	vars.NotifiedChanges = false
	vars.Version = 23
	return true
end

function M:UpgradeToVersion24(vars)
	if vars.Version ~= 23 then
		return false
	end

	vars.Modules.PrecogGuesserModule = {
		Enabled = {
			Always = true,
		},

		Point = "CENTER",
		RelativeTo = "UIParent",
		RelativePoint = "CENTER",
		Offset = {
			X = 0,
			Y = 70,
		},

		Icons = {
			Size = 70,
			Glow = true,
			ReverseCooldown = true,
		},
	}

	vars.Modules.PetCCModule = {
		Enabled = {
			Always = false,
			Arena = false,
			Raids = false,
			Dungeons = false,
		},

		Grow = "CENTER",
		Offset = {
			X = 0,
			Y = 0,
		},

		Icons = {
			Size = 30,
			Count = 3,
			Glow = true,
			ReverseCooldown = true,
			ColorByDispelType = true,
		},
	}

	table.insert(vars.WhatsNew, L[" - Added CC icons on pet party/raid frames (disabled by default)."])
	table.insert(vars.WhatsNew, L[" - Added precognition guesser module that shows when you get precog."])
	table.insert(vars.WhatsNew, L[" - Added profile import/export feature."])

	vars.NotifiedChanges = false
	vars.Version = 24
	return true
end

function M:UpgradeToVersion25(vars)
	if vars.Version ~= 24 then
		return false
	end

	-- Rename Raids->BattleGrounds and Dungeons->PvE in all module Enabled tables
	if vars.Modules then
		local modules = {
			"CCModule",
			"PetCCModule",
			"HealerCCModule",
			"AlertsModule",
			"NameplatesModule",
			"FriendlyIndicatorModule",
		}
		for _, moduleName in ipairs(modules) do
			local m = vars.Modules[moduleName]
			if m and m.Enabled then
				if m.Enabled.Raids ~= nil then
					m.Enabled.BattleGrounds = m.Enabled.Raids
					m.Enabled.Raids = nil
				end
				if m.Enabled.Dungeons ~= nil then
					m.Enabled.PvE = m.Enabled.Dungeons
					m.Enabled.Dungeons = nil
				end
			end
		end
	end

	vars.Version = 25
	return true
end

function M:UpgradeToVersion26(vars)
	if vars.Version ~= 25 then
		return false
	end

	-- CC module now uses SetIgnoreParentScale(true), so saved icon sizes need to be
	-- scaled up by UIParent:GetScale(). That value isn't reliable at load time (returns 1),
	-- so set a flag and apply it later via RunDeferredMigrations on PLAYER_LOGIN.
	vars.Pending = vars.Pending or {}
	vars.Pending.ScaleMigration26 = true

	vars.Version = 26
	return true
end

function M:UpgradeToVersion27(vars)
	if vars.Version ~= 26 then
		return false
	end

	-- Rename Always->World in location-based modules.
	-- If Always was true, it acted as an override for all contexts, so enable all of them.
	if vars.Modules then
		local modules = {
			"CCModule",
			"PetCCModule",
			"HealerCCModule",
			"AlertsModule",
			"NameplatesModule",
			"FriendlyIndicatorModule",
		}
		for _, moduleName in ipairs(modules) do
			local m = vars.Modules[moduleName]
			if m and m.Enabled and m.Enabled.Always ~= nil then
				if m.Enabled.Always == true then
					m.Enabled.World = true
					m.Enabled.Arena = true
					m.Enabled.BattleGrounds = true
					m.Enabled.PvE = true
				else
					m.Enabled.World = false
				end
				m.Enabled.Always = nil
			end
		end
	end

	vars.Version = 27
	return true
end

function M:UpgradeToVersion28(vars)
	if vars.Version ~= 27 then
		return false
	end

	-- Add MaxIcons to AlertsModule.Icons
	if vars.Modules and vars.Modules.AlertsModule and vars.Modules.AlertsModule.Icons then
		vars.Modules.AlertsModule.Icons.MaxIcons = 8
	end

	vars.Version = 28
	return true
end

function M:UpgradeToVersion29(vars)
	if vars.Version ~= 28 then
		return false
	end

	-- Add ShowCC and ColorByDispelType to FriendlyIndicatorModule
	if vars.Modules and vars.Modules.FriendlyIndicatorModule then
		local fi = vars.Modules.FriendlyIndicatorModule
		fi.ShowCC = false
		if fi.Icons then
			fi.Icons.ColorByDispelType = true
		end
	end

	vars.Version = 29
	return true
end

function M:UpgradeToVersion30(vars)
	if vars.Version ~= 29 then
		return false
	end

	if vars.Modules and vars.Modules.FriendlyIndicatorModule then
		local fi = vars.Modules.FriendlyIndicatorModule

		local instanceSettings = {
			ExcludePlayer = fi.ExcludePlayer,
			ShowDefensives = fi.ShowDefensives,
			ShowImportant = fi.ShowImportant,
			ShowCC = fi.ShowCC,
			Offset = fi.Offset and mini:CopyTable(fi.Offset) or { X = 0, Y = 0 },
			Grow = fi.Grow,
			Icons = fi.Icons and mini:CopyTable(fi.Icons) or nil,
		}

		-- Write into the existing table shells so upvalue references captured by
		-- Config UI closures during Build() remain valid after a profile import.
		local function MergeInPlace(target, src)
			for key, value in pairs(src) do
				if type(value) == "table" then
					target[key] = target[key] or {}
					for subKey, subValue in pairs(value) do
						target[key][subKey] = subValue
					end
				else
					target[key] = value
				end
			end
		end

		fi.Default = fi.Default or {}
		MergeInPlace(fi.Default, instanceSettings)

		fi.Raid = fi.Raid or {}
		MergeInPlace(fi.Raid, instanceSettings)
		fi.Raid.ShowCC = true

		-- nil old flat values that are no longer used
		fi.ExcludePlayer = nil
		fi.ShowDefensives = nil
		fi.ShowImportant = nil
		fi.ShowCC = nil
		fi.Offset = nil
		fi.Grow = nil
		fi.Icons = nil
	end

	vars.Version = 30
	return true
end

function M:UpgradeToVersion31(vars)
	if vars.Version ~= 30 then
		return false
	end

	-- Add ScaleWithNameplate to NameplatesModule. Existing installs default to false to keep the
	-- behaviour they have.
	if vars.Modules and vars.Modules.NameplatesModule then
		vars.Modules.NameplatesModule.ScaleWithNameplate = false
	end

	vars.Version = 31
	return true
end

function M:UpgradeToVersion32(vars)
	if vars.Version ~= 31 then
		return false
	end

	-- Rename IncludeBigDefensives to IncludeDefensives in AlertsModule
	if vars.Modules and vars.Modules.AlertsModule then
		local am = vars.Modules.AlertsModule
		if am.IncludeBigDefensives ~= nil then
			am.IncludeDefensives = am.IncludeBigDefensives
			am.IncludeBigDefensives = nil
		end
	end

	vars.Version = 32
	return true
end

function M:UpgradeToVersion33(vars)
	if vars.Version ~= 32 then
		return false
	end

	-- The version 27 migration switched every context on, so a CC module enabled in battlegrounds
	-- would draw the same icons as the friendly indicator. The indicator's row is switched off.
	local mods = vars.Modules
	if mods and mods.CCModule and mods.FriendlyIndicatorModule then
		local ccEnabledBGs = mods.CCModule.Enabled and mods.CCModule.Enabled.BattleGrounds
		local fiRaidShowCC = mods.FriendlyIndicatorModule.Raid and mods.FriendlyIndicatorModule.Raid.ShowCC
		if ccEnabledBGs and fiRaidShowCC then
			mods.FriendlyIndicatorModule.Raid.ShowCC = false
		end
	end

	vars.Version = 33
	return true
end

function M:UpgradeToVersion34(vars)
	if vars.Version ~= 33 then
		return false
	end

	table.insert(vars.WhatsNew, L[" - Added friendly cooldown guessing module. You can now somewhat track your team mates cooldowns!"])

	vars.NotifiedChanges = false
	vars.Version = 34
	return true
end

function M:UpgradeToVersion35(vars)
	if vars.Version ~= 34 then
		return false
	end

	-- Split PvE into Dungeons + Raid for all modules
	local moduleNames = {
		"CCModule", "PetCCModule", "HealerCCModule",
		"AlertsModule", "NameplatesModule", "FriendlyIndicatorModule",
		"FriendlyCooldownTrackerModule",
	}
	if vars.Modules then
		for _, moduleName in ipairs(moduleNames) do
			local m = vars.Modules[moduleName]
			if m and m.Enabled and m.Enabled.PvE ~= nil then
				m.Enabled.Dungeons = m.Enabled.PvE
				m.Enabled.Raid = m.Enabled.PvE
				m.Enabled.PvE = nil
			end
		end
	end

	vars.Version = 35
	return true
end

function M:UpgradeToVersion36(vars)
	if vars.Version ~= 35 then
		return false
	end

	local fcdModule = vars.Modules and vars.Modules.FriendlyCooldownTrackerModule
	if fcdModule then
		local spacing = vars.IconSpacing or 2
		if fcdModule.Default then
			fcdModule.Default.IconSpacing = spacing
		end
		if fcdModule.Raid then
			fcdModule.Raid.IconSpacing = spacing
		end
	end

	vars.Version = 36
	return true
end

function M:UpgradeToVersion37(vars)
	if vars.Version ~= 36 then return false end

	vars.Profiles = vars.Profiles or {}
	vars.ActiveProfile = vars.ActiveProfile or "Default"
	vars.AutoSwitch = vars.AutoSwitch or {}

	-- Snapshot the current settings into the "Default" profile slot so existing
	-- users don't lose their configuration after upgrading.
	if not vars.Profiles["Default"] then
		local payloadKeys = addon.Core.ProfileManager.PayloadKeys
		local snapshot = {}
		for _, k in ipairs(payloadKeys) do
			if vars[k] ~= nil then
				snapshot[k] = mini:CopyValueOrTable(vars[k])
			end
		end
		vars.Profiles["Default"] = snapshot
	end

	vars.Version = 37
	return true
end

function M:UpgradeToVersion38(vars)
	if vars.Version ~= 37 then return false end

	-- Add ShowTooltips to each NameplateSpellTypeOptions section, off for existing installs.
	if vars.Modules and vars.Modules.NameplatesModule then
		local nm = vars.Modules.NameplatesModule
		for _, faction in ipairs({ nm.Friendly, nm.Enemy }) do
			if faction then
				for _, section in ipairs({ faction.CC, faction.Important, faction.Combined }) do
					if section and section.ShowTooltips == nil then
						section.ShowTooltips = false
					end
				end
			end
		end
	end

	vars.Version = 38
	return true
end

function M:UpgradeToVersion39(vars)
	if vars.Version ~= 38 then return false end

	table.insert(vars.WhatsNew, L["HEADS UP: Blizzard is making changes in patch 12.0.5 (April 21st) that will severely reduce the accuracy of friendly CD tracking, kill cooldown glow on press, and completely remove PvP enemy kick tracking. So please be aware that tracking will lose accuracy soon."])

	vars.NotifiedChanges = false
	vars.Version = 39
	return true
end

function M:UpgradeToVersion40(vars)
	if vars.Version ~= 39 then return false end

	-- Rename "夏一可.ogg" -> "XiaYike.ogg" in the three known Sound.File locations.
	local function RenameSound(modules)
		if not modules then return end

		local healer = modules.HealerCCModule
		if healer and healer.Sound and healer.Sound.File == "夏一可.ogg" then
			healer.Sound.File = "XiaYike.ogg"
		end

		local alerts = modules.AlertsModule
		if alerts and alerts.Sound then
			if alerts.Sound.Important and alerts.Sound.Important.File == "夏一可.ogg" then
				alerts.Sound.Important.File = "XiaYike.ogg"
			end
			if alerts.Sound.Defensive and alerts.Sound.Defensive.File == "夏一可.ogg" then
				alerts.Sound.Defensive.File = "XiaYike.ogg"
			end
		end
	end

	RenameSound(vars.Modules)

	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			RenameSound(profile.Modules)
		end
	end

	vars.Version = 40
	return true
end

