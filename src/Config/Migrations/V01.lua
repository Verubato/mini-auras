---@diagnostic disable: unused-function
local _, addon = ...
local mini = addon.Framework
local M = addon.Config.Migrator

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

	mini:CleanTable(vars, v12Defaults, true, true)
	vars.Version = 12

	return true
end

