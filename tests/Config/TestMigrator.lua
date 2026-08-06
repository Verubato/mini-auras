-- Tests for Config/Migrator.lua running against the REAL MiniFramework table utilities
-- (GetSavedVars/CopyTable/CleanTable), since the migration semantics live in that combination.
-- The Migrator transforms every user's saved variables on upgrade - the black-box invariant is
-- "any input produces a valid current-version db".

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()
local acm = require("AuraContainerMock")
acm.setup()

local addon = {
	Utils = {},
	Core = {},
	Modules = {},
	Config = {},
	L = setmetatable({}, {
		__index = function(_, key)
			return key
		end,
	}),
}

local addonFiles = require("AddonFiles")
addonFiles.load(addonFiles.framework, addon)
-- ProfileManager before Migrator: UpgradeToVersion37 snapshots profiles via its PayloadKeys.
assert(loadfile("src/Core/ProfileManager.lua"))("MiniCC", addon)
addonFiles.load(addonFiles.migrator, addon)

local migrator = addon.Config.Migrator

local function deepEquals(a, b, path)
	path = path or "root"
	if type(a) ~= type(b) then
		return false, path .. " type mismatch"
	end
	if type(a) ~= "table" then
		if a ~= b then
			return false, path .. " " .. tostring(a) .. " ~= " .. tostring(b)
		end
		return true
	end
	for key, value in pairs(a) do
		local ok, why = deepEquals(value, b[key], path .. "." .. tostring(key))
		if not ok then
			return false, why
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false, path .. "." .. tostring(key) .. " only in second"
		end
	end
	return true
end

local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for key, value in pairs(t) do
		out[key] = deepCopy(value)
	end
	return out
end

-- The current schema version, discovered from a fresh install rather than hardcoded.
_G.MiniCCDB = nil
local LATEST_VERSION = migrator:GetAndUpgradeDb().Version
assert(type(LATEST_VERSION) == "number" and LATEST_VERSION >= 55, "sane latest version")

local expectedModules = {
	"CCModule", "PetCCModule", "HealerCCModule", "PortraitModule", "AlertsModule",
	"NameplatesModule", "EnemyKickTrackerModule", "TrinketsModule", "RaidFrameAurasModule",
	"PrecogModule", "FriendlyCooldownTrackerModule", "EnemyCooldownTrackerModule",
}

fw.describe("Migrator - fresh install", function()
	fw.before_each(function()
		_G.MiniCCDB = nil
	end)

	fw.it("produces the full current-version schema", function()
		local db = migrator:GetAndUpgradeDb()
		assert(db.Version == LATEST_VERSION)
		for _, name in ipairs(expectedModules) do
			assert(type(db.Modules[name]) == "table", "missing module defaults: " .. name)
		end
		assert(type(db.Modules.CCModule.Default.Icons.Size) == "number", "representative nested default")
		assert(db.GlowType == "Slot Glow" and type(db.FontScale) == "number", "top-level defaults")
	end)

	fw.it("is idempotent", function()
		local first = deepCopy(migrator:GetAndUpgradeDb())
		local second = migrator:GetAndUpgradeDb()
		local ok, why = deepEquals(first, second)
		assert(ok, "second run changed the db: " .. tostring(why))
	end)
end)

fw.describe("Migrator - arbitrary input safety", function()
	local fixtures = {
		["empty table"] = {},
		["unknown garbage"] = { Foo = "bar", Nested = { Junk = true } },
		["mid-history version with junk"] = { Version = 3, Whatever = 1 },
	}

	for label, fixture in pairs(fixtures) do
		fw.it("recovers to a valid current db from " .. label, function()
			_G.MiniCCDB = deepCopy(fixture)
			local db = migrator:GetAndUpgradeDb()
			assert(db.Version == LATEST_VERSION, label .. ": version healed")
			assert(type(db.Modules) == "table" and db.Modules.CCModule, label .. ": modules present")
			assert(db.Foo == nil and db.Whatever == nil, label .. ": unknown keys cleaned")
		end)
	end

	fw.it("a db from a NEWER version soft-resets but keeps recognized settings", function()
		_G.MiniCCDB = { Version = LATEST_VERSION + 100, FontScale = 1.4, Garbage = "x" }
		local db = migrator:GetAndUpgradeDb()
		assert(db.Version == LATEST_VERSION, "version reset to current")
		assert(db.FontScale == 1.4, "recognized custom value preserved")
		assert(db.Garbage == nil, "unknown key cleaned")
	end)
end)

fw.describe("Migrator - upgrade chain completeness", function()
	fw.it("has an UpgradeToVersionN function for every version 1..latest", function()
		for n = 1, LATEST_VERSION do
			assert(type(migrator["UpgradeToVersion" .. n]) == "function", "missing UpgradeToVersion" .. n)
		end
	end)
end)

fw.describe("Migrator - full chain from a v1-era db", function()
	fw.it("walks an ancient realistic db through every version to a valid current db", function()
		-- A pre-versioning db as UpgradeToVersion1 expects (no Version key), with the fields
		-- that era actually had, some customized.
		_G.MiniCCDB = {
			SimpleMode = { Enabled = true, Offset = { X = 7, Y = 3 } },
			AdvancedMode = { Enabled = false, Point = "TOPLEFT", RelativePoint = "TOPRIGHT", Offset = { X = 2, Y = 0 } },
			Icons = { Size = 64, Padding = { X = 2, Y = 0 } },
			Container = { Point = "TOPLEFT", RelativePoint = "TOPRIGHT", Offset = { X = 2, Y = 0 } },
			Anchor1 = "CompactPartyFrameMember1",
			Anchor2 = "MyCustomFrame2",
			Anchor3 = "CompactPartyFrameMember3",
			ArenaOnly = true,
		}

		local db = migrator:GetAndUpgradeDb()

		assert(db.Version == LATEST_VERSION, "reached the current version")
		for _, name in ipairs(expectedModules) do
			assert(type(db.Modules[name]) == "table", "missing module: " .. name)
		end
		-- Every pre-module-refactor top-level structure must be consumed or cleaned.
		for _, legacyKey in ipairs({
			"SimpleMode", "AdvancedMode", "Container", "Icons",
			"Default", "Raid", "Arena", "BattleGrounds",
			"Alerts", "Healer", "Nameplates", "Portrait", "KickTimer", "Trinkets", "AllyIndicator",
		}) do
			assert(db[legacyKey] == nil, "legacy top-level key survived: " .. legacyKey)
		end
		-- The chain accumulates What's New entries and flags the notification.
		assert(type(db.WhatsNew) == "table" and #db.WhatsNew > 0, "WhatsNew accumulated")
		assert(db.NotifiedChanges == false, "user gets notified after an upgrade")
	end)
end)

fw.describe("Migrator - full chain from a v37-era db preserves settings", function()
	-- v37 is the profiles era: from here the db shape matches current dbDefaults closely
	-- enough that user customizations at current-schema paths must survive to the latest
	-- version (the v23 CleanTable-vs-current-defaults reset only affects older dbs).
	fw.it("carries customized values through every remaining migration", function()
		_G.MiniCCDB = {
			Version = 37,
			WhatsNew = {},
			NotifiedChanges = true,
			GlowType = "Pixel Glow",
			IconSpacing = 5,
			Profiles = {
				Default = { Modules = { HealerCCModule = { Sound = { File = "夏一可.ogg" } } } },
			},
			ActiveProfile = "Default",
			AutoSwitch = {},
			Modules = {
				CCModule = {
					Enabled = { World = false, Arena = true, BattleGrounds = true, Dungeons = false, Raid = false },
					Default = {
						Grow = "LEFT",
						Offset = { X = 7, Y = 3 },
						Icons = { Size = 64, Glow = false, ReverseCooldown = true, ColorByDispelType = true },
					},
					Raid = { Grow = "CENTER", Offset = { X = 0, Y = 0 }, Icons = { Size = 45 } },
				},
				HealerCCModule = {
					Sound = { Enabled = true, Channel = "Master", File = "夏一可.ogg" },
					Icons = { Size = 48 },
				},
				AlertsModule = {
					Icons = { Size = 60, Glow = true, ReverseCooldown = true, ColorByClass = true, MaxIcons = 6 },
				},
				NameplatesModule = {
					ScaleWithNameplate = false,
					Enemy = {
						IgnorePets = true,
						CC = { Enabled = true, Grow = "RIGHT", Offset = { X = 2, Y = 0 }, Icons = { Size = 44, MaxIcons = 4 } },
						Important = { Enabled = false, Grow = "LEFT", Offset = { X = -2, Y = 0 }, Icons = { Size = 50 } },
						Combined = { Enabled = true, Grow = "RIGHT", Offset = { X = 2, Y = 0 }, Icons = { Size = 41 } },
					},
					Friendly = {
						IgnorePets = true,
						CC = { Enabled = false, Icons = { Size = 50 } },
						Important = { Enabled = false, Icons = { Size = 50 } },
						Combined = { Enabled = false, Icons = { Size = 50 } },
					},
				},
				KickTimerModule = {},
				EnemyCooldownTrackerModule = {
					DisplayMode = "Split",
					DisabledSpells = { [12345] = true },
				},
			},
		}

		local db = migrator:GetAndUpgradeDb()
		assert(db.Version == LATEST_VERSION)

		-- Untouched customizations survive the whole chain plus the final CleanTable.
		assert(db.GlowType == "Pixel Glow", "custom glow type kept")
		local cc = db.Modules.CCModule
		assert(cc.Default.Grow == "LEFT" and cc.Default.Offset.X == 7 and cc.Default.Icons.Size == 64, "CC customizations kept")
		assert(cc.Enabled.World == false and cc.Enabled.Arena == true and cc.Enabled.BattleGrounds == true, "CC enabled flags kept")
		assert(db.Modules.AlertsModule.Icons.Size == 60 and db.Modules.AlertsModule.Icons.MaxIcons == 6, "alerts icons kept")
		assert(db.Modules.NameplatesModule.ScaleWithNameplate == false, "nameplate scale opt-out kept")

		-- v40: legacy sound file renamed in the live db AND inside stored profiles.
		assert(db.Modules.HealerCCModule.Sound.File == "XiaYike.ogg", "sound renamed")
		assert(db.Profiles.Default.Modules.HealerCCModule.Sound.File == "XiaYike.ogg", "sound renamed inside profile")

		-- v38: existing installs get nameplate tooltips off (fresh installs default on).
		-- v49: CC -> Bar1 (ShowCC), Combined -> Bar2 (ShowDefensives), settings carried.
		local enemy = db.Modules.NameplatesModule.Enemy
		assert(enemy.CC == nil and enemy.Combined == nil, "old sections consumed")
		assert(enemy.Bar1.Icons.Size == 44 and enemy.Bar1.ShowCC == true and enemy.Bar1.ShowDefensives == false, "CC became Bar1")
		assert(enemy.Bar2.Icons.Size == 41 and enemy.Bar2.ShowCC == false and enemy.Bar2.ShowDefensives == true, "Combined became Bar2")
		assert(enemy.Bar1.ShowTooltips == false, "existing installs keep tooltips off")

		-- v52: ShowImportant lands on the enabled bar that shows defensives (enemy Bar2 here).
		assert(enemy.Bar2.ShowImportant == true, "important surfaced on the defensives bar")

		-- v48: removed Split layout falls back to Linear; opaque spell hash survives CleanTable.
		local ecd = db.Modules.EnemyCooldownTrackerModule
		assert(ecd.DisplayMode == "Linear", "Split layout migrated to Linear")
		assert(ecd.DisabledSpells[12345] == true, "opaque DisabledSpells hash preserved")

		-- v54/v55: per-module icon padding seeded from the old global IconSpacing.
		assert(db.Modules.AlertsModule.IconSpacing == 5, "alerts padding seeded")
		assert(enemy.Bar1.Icons.Spacing == 5 and enemy.Bar2.Icons.Spacing == 5, "nameplate bar padding seeded")
		assert(cc.Default.IconSpacing == 5 and cc.Raid.IconSpacing == 5, "CC padding seeded")
		assert(db.Modules.HealerCCModule.IconSpacing == 5, "healer padding seeded")
		assert(db.Modules.EnemyKickTrackerModule.IconSpacing == 5, "kick timer padding seeded")
	end)
end)

fw.describe("Migrator - individual migrations", function()
	fw.it("v21 rewrites the removed Action Button Glow type", function()
		local vars = { Version = 20, GlowType = "Action Button Glow" }
		assert(migrator:UpgradeToVersion21(vars) == true)
		assert(vars.GlowType == "Proc Glow" and vars.Version == 21)
	end)

	fw.it("v21 leaves other glow types alone", function()
		local vars = { Version = 20, GlowType = "Pixel Glow" }
		assert(migrator:UpgradeToVersion21(vars) == true)
		assert(vars.GlowType == "Pixel Glow")
	end)

	fw.it("migrations refuse to run against the wrong source version", function()
		local vars = { Version = 5, GlowType = "Action Button Glow" }
		assert(migrator:UpgradeToVersion21(vars) == false, "wrong version must be rejected")
		assert(vars.GlowType == "Action Button Glow", "and must not mutate")
	end)

	fw.it("v5 renames Arena->Default and BattleGrounds->Raid", function()
		local vars = {
			Version = 4,
			Arena = { Enabled = true, SimpleMode = { Enabled = true, Offset = { X = 9, Y = 0 } }, AdvancedMode = {}, Icons = { Size = 61 } },
			BattleGrounds = { Enabled = false, SimpleMode = { Enabled = true, Offset = { X = 2, Y = 0 } }, AdvancedMode = {}, Icons = { Size = 33 } },
		}
		assert(migrator:UpgradeToVersion5(vars) == true)
		assert(vars.Default.Icons.Size == 61 and vars.Arena == nil, "Arena became Default")
		assert(vars.Raid.Icons.Size == 33 and vars.BattleGrounds == nil, "BattleGrounds became Raid")
	end)

	fw.it("v6 clears default anchors but keeps custom ones", function()
		local vars = { Version = 5, Anchor1 = "CompactPartyFrameMember1", Anchor2 = "MyFrame", Anchor3 = "CompactPartyFrameMember3" }
		assert(migrator:UpgradeToVersion6(vars) == true)
		assert(vars.Anchor1 == "" and vars.Anchor3 == "", "defaults cleared")
		assert(vars.Anchor2 == "MyFrame", "custom anchor kept")
	end)

	fw.it("v11 splits Nameplates.Enabled into Friendly/Enemy flags", function()
		local vars = { Version = 10, Nameplates = { Enabled = false } }
		assert(migrator:UpgradeToVersion11(vars) == true)
		assert(vars.Nameplates.FriendlyEnabled == false and vars.Nameplates.EnemyEnabled == false)
	end)

	fw.it("v18 moves per-section configs into Modules (name-matching modules keep values)", function()
		local vars = {
			Version = 17,
			Default = { Enabled = true, SimpleMode = { Grow = "LEFT", Offset = { X = 7, Y = 3 } }, Icons = { Size = 64 } },
			Raid = { Enabled = false, SimpleMode = { Grow = "CENTER", Offset = { X = 0, Y = 0 } }, Icons = { Size = 45 } },
			Alerts = { Enabled = true, Icons = { Size = 60, Glow = false, ReverseCooldown = true } },
			KickTimer = { AllEnabled = false, CasterEnabled = true, HealerEnabled = false, Icons = { Size = 51 } },
		}
		assert(migrator:UpgradeToVersion18(vars) == true)
		assert(vars.Default == nil and vars.Raid == nil and vars.Alerts == nil and vars.KickTimer == nil, "old sections consumed")
		-- Modules whose names match the v18 template carry their values across.
		assert(vars.Modules.AlertsModule.Icons.Size == 60 and vars.Modules.AlertsModule.Icons.Glow == false, "alerts values carried")
		assert(vars.Modules.AlertsModule.Enabled.Always == true, "alerts enabled mapped")
		assert(vars.Modules.KickTimerModule.Enabled.Caster == true and vars.Modules.KickTimerModule.Enabled.Healer == false, "kick timer enabled mapped")
		-- Historical quirk, asserted as-is: the v18 template names CC/Healer modules "CcModule"/
		-- "HealerCcModule", so the freshly built "CCModule" is stripped by CleanTable and CC
		-- customizations reset at this step (v19 renames the template-cased tables).
		assert(vars.Modules.CCModule == nil, "CCModule reset by the v18 template casing (historical behavior)")
	end)

	fw.it("v22 adds the healer warning-text flag", function()
		local vars = { Version = 21, Modules = { HealerCCModule = {} } }
		assert(migrator:UpgradeToVersion22(vars) == true)
		assert(vars.Modules.HealerCCModule.ShowWarningText == true)
	end)

	fw.it("v23 seeds the alerts Sound/TTS blocks", function()
		local vars = { Version = 22, WhatsNew = {}, Modules = { AlertsModule = {} } }
		assert(migrator:UpgradeToVersion23(vars) == true)
		assert(vars.Modules.AlertsModule.Sound.Important.File == "AirHorn.ogg")
		assert(vars.Modules.AlertsModule.TTS.Defensive.Enabled == false)
	end)

	fw.it("v25 renames Enabled.Raids->BattleGrounds and Dungeons->PvE", function()
		local vars = { Version = 24, Modules = { CCModule = { Enabled = { Always = true, Raids = false, Dungeons = true } } } }
		assert(migrator:UpgradeToVersion25(vars) == true)
		local enabled = vars.Modules.CCModule.Enabled
		assert(enabled.BattleGrounds == false and enabled.Raids == nil, "Raids renamed")
		assert(enabled.PvE == true and enabled.Dungeons == nil, "Dungeons renamed")
	end)

	fw.it("v27 expands Enabled.Always=true into every context", function()
		local vars = { Version = 26, Modules = { CCModule = { Enabled = { Always = true, Arena = false, BattleGrounds = false, PvE = false } } } }
		assert(migrator:UpgradeToVersion27(vars) == true)
		local enabled = vars.Modules.CCModule.Enabled
		assert(enabled.Always == nil and enabled.World and enabled.Arena and enabled.BattleGrounds and enabled.PvE, "Always overrode all contexts")
	end)

	fw.it("v27 maps Enabled.Always=false to World=false without touching others", function()
		local vars = { Version = 26, Modules = { CCModule = { Enabled = { Always = false, Arena = true } } } }
		assert(migrator:UpgradeToVersion27(vars) == true)
		local enabled = vars.Modules.CCModule.Enabled
		assert(enabled.Always == nil and enabled.World == false and enabled.Arena == true)
	end)

	fw.it("v30 splits the flat FriendlyIndicator options into Default/Raid instances", function()
		local vars = {
			Version = 29,
			Modules = {
				FriendlyIndicatorModule = {
					ExcludePlayer = true,
					ShowDefensives = true,
					ShowImportant = false,
					ShowCC = false,
					Offset = { X = 4, Y = 1 },
					Grow = "LEFT",
					Icons = { Size = 38 },
				},
			},
		}
		assert(migrator:UpgradeToVersion30(vars) == true)
		local fi = vars.Modules.FriendlyIndicatorModule
		assert(fi.Default.ExcludePlayer == true and fi.Default.Grow == "LEFT" and fi.Default.Icons.Size == 38, "values moved to Default")
		assert(fi.Raid.Icons.Size == 38 and fi.Raid.ShowCC == true, "Raid copy with CC forced on")
		assert(fi.Icons == nil and fi.Grow == nil and fi.ExcludePlayer == nil, "flat keys consumed")
	end)

	fw.it("v32 renames IncludeBigDefensives to IncludeDefensives", function()
		local vars = { Version = 31, Modules = { AlertsModule = { IncludeBigDefensives = false } } }
		assert(migrator:UpgradeToVersion32(vars) == true)
		local alerts = vars.Modules.AlertsModule
		assert(alerts.IncludeDefensives == false and alerts.IncludeBigDefensives == nil)
	end)

	fw.it("v33 disables indicator raid CC when the CC module already covers battlegrounds", function()
		local vars = {
			Version = 32,
			Modules = {
				CCModule = { Enabled = { BattleGrounds = true } },
				FriendlyIndicatorModule = { Raid = { ShowCC = true } },
			},
		}
		assert(migrator:UpgradeToVersion33(vars) == true)
		assert(vars.Modules.FriendlyIndicatorModule.Raid.ShowCC == false)
	end)

	fw.it("v35 splits Enabled.PvE into Dungeons + Raid", function()
		local vars = { Version = 34, Modules = { AlertsModule = { Enabled = { PvE = true } } } }
		assert(migrator:UpgradeToVersion35(vars) == true)
		local enabled = vars.Modules.AlertsModule.Enabled
		assert(enabled.Dungeons == true and enabled.Raid == true and enabled.PvE == nil)
	end)

	fw.it("v37 snapshots current settings into the Default profile", function()
		local vars = { Version = 36, GlowType = "Pixel Glow", Modules = { CCModule = { Default = { Grow = "LEFT" } } } }
		assert(migrator:UpgradeToVersion37(vars) == true)
		assert(vars.ActiveProfile == "Default")
		assert(vars.Profiles.Default.GlowType == "Pixel Glow", "payload snapshotted")
		assert(vars.Profiles.Default.Modules.CCModule.Default.Grow == "LEFT", "module settings snapshotted")
		assert(vars.Profiles.Default.Modules ~= vars.Modules, "snapshot is a copy, not a reference")
	end)

	fw.it("v49 maps nameplate CC/Combined sections onto Bar1/Bar2", function()
		local vars = {
			Version = 48,
			Modules = {
				NameplatesModule = {
					Enemy = {
						CC = { Enabled = true, Icons = { Size = 44 } },
						Combined = { Enabled = false, Icons = { Size = 41 } },
					},
					Friendly = {},
				},
			},
		}
		assert(migrator:UpgradeToVersion49(vars) == true)
		local enemy = vars.Modules.NameplatesModule.Enemy
		assert(enemy.Bar1.Icons.Size == 44 and enemy.Bar1.ShowCC == true and enemy.Bar1.ShowDefensives == false)
		assert(enemy.Bar2.Icons.Size == 41 and enemy.Bar2.ShowCC == false and enemy.Bar2.ShowDefensives == true)
		assert(enemy.CC == nil and enemy.Combined == nil)
	end)

	fw.it("v52 surfaces ShowImportant on the enabled bar that shows defensives", function()
		local vars = {
			Version = 51,
			Modules = {
				NameplatesModule = {
					Enemy = {
						Bar1 = { Enabled = true, ShowDefensives = false },
						Bar2 = { Enabled = true, ShowDefensives = true },
					},
					Friendly = {},
				},
			},
		}
		assert(migrator:UpgradeToVersion52(vars) == true)
		local enemy = vars.Modules.NameplatesModule.Enemy
		assert(enemy.Bar2.ShowImportant == true, "defensives bar preferred")
		assert(enemy.Bar1.ShowImportant == nil, "other bars untouched")
	end)

	fw.it("v52 falls back to the first enabled bar when none show defensives", function()
		local vars = {
			Version = 51,
			Modules = {
				NameplatesModule = {
					Enemy = { Bar1 = { Enabled = false }, Bar2 = { Enabled = false } },
					Friendly = { Bar1 = { Enabled = true, ShowDefensives = false } },
				},
			},
		}
		assert(migrator:UpgradeToVersion52(vars) == true)
		assert(vars.Modules.NameplatesModule.Friendly.Bar1.ShowImportant == true)
	end)

	fw.it("v54/v55 seed per-module icon padding from the old global IconSpacing", function()
		local vars = {
			Version = 53,
			IconSpacing = 9,
			Modules = {
				AlertsModule = {},
				NameplatesModule = { Enemy = { Bar1 = { Icons = {} } } },
				CCModule = { Default = {}, Raid = {} },
				HealerCCModule = {},
				KickTimerModule = {},
			},
		}
		assert(migrator:UpgradeToVersion54(vars) == true)
		assert(vars.Modules.AlertsModule.IconSpacing == 9)
		assert(vars.Modules.NameplatesModule.Enemy.Bar1.Icons.Spacing == 9)
		assert(migrator:UpgradeToVersion55(vars) == true)
		assert(vars.Modules.CCModule.Default.IconSpacing == 9 and vars.Modules.CCModule.Raid.IconSpacing == 9)
		assert(vars.Modules.HealerCCModule.IconSpacing == 9 and vars.Modules.KickTimerModule.IconSpacing == 9)
	end)

	fw.it("v56 seeds FriendlyIndicator ShowImportant from ShowDefensives", function()
		local vars = {
			Version = 55,
			Modules = {
				FriendlyIndicatorModule = {
					Default = { ShowDefensives = false },
					Raid = { ShowDefensives = true },
				},
			},
		}
		assert(migrator:UpgradeToVersion56(vars) == true)
		assert(vars.Modules.FriendlyIndicatorModule.Default.ShowImportant == false, "off follows off")
		assert(vars.Modules.FriendlyIndicatorModule.Raid.ShowImportant == true, "on follows on")
	end)

	fw.it("v57 turns off FriendlyIndicator kicks where the CC module already shows them", function()
		local vars = {
			Version = 56,
			Modules = {
				CCModule = { Enabled = { World = false, Arena = true } },
				FriendlyIndicatorModule = {
					Enabled = { World = true, Arena = true },
					Default = { ShowKicks = true },
					Raid = { ShowKicks = true },
				},
			},
			Profiles = {
				Other = {
					Modules = {
						CCModule = { Enabled = { Arena = false } },
						FriendlyIndicatorModule = {
							Enabled = { Arena = true },
							Default = { ShowKicks = true },
						},
					},
				},
			},
		}
		assert(migrator:UpgradeToVersion57(vars) == true)
		local fi = vars.Modules.FriendlyIndicatorModule
		assert(fi.Default.ShowKicks == false and fi.Raid.ShowKicks == false, "overlap in arena disables both profiles")
		assert(vars.Profiles.Other.Modules.FriendlyIndicatorModule.Default.ShowKicks == true, "no overlap, kicks kept")
	end)

	fw.it("v58 moves the precog settings onto the renamed module key", function()
		local kept = { Enabled = { Always = false }, Icons = { Size = 44 } }
		local vars = {
			Version = 57,
			Modules = { PrecogGuesserModule = kept },
			Profiles = {
				Other = { Modules = { PrecogGuesserModule = { Icons = { Size = 20 } } } },
				Untouched = { Modules = {} },
			},
		}

		assert(migrator:UpgradeToVersion58(vars) == true)
		assert(vars.Modules.PrecogModule == kept, "the saved table moves across intact")
		assert(vars.Modules.PrecogGuesserModule == nil, "and the old key is gone")
		assert(vars.Profiles.Other.Modules.PrecogModule.Icons.Size == 20, "profiles move too")
		assert(vars.Profiles.Untouched.Modules.PrecogModule == nil, "a profile without one is left alone")
	end)

	fw.it("v58 keeps an already-renamed key when both are present", function()
		local current = { Icons = { Size = 60 } }
		local vars = {
			Version = 57,
			Modules = { PrecogModule = current, PrecogGuesserModule = { Icons = { Size = 20 } } },
		}

		assert(migrator:UpgradeToVersion58(vars) == true)
		assert(vars.Modules.PrecogModule == current, "the newer key wins")
		assert(vars.Modules.PrecogGuesserModule == nil, "the stale one is cleared either way")
	end)

	fw.it("v59 moves the kick timer settings onto the renamed module key", function()
		local kept = { Enabled = { Caster = true }, Icons = { Size = 44 } }
		local vars = {
			Version = 58,
			Modules = { KickTimerModule = kept },
			Profiles = { Other = { Modules = { KickTimerModule = { Icons = { Size = 20 } } } } },
		}

		assert(migrator:UpgradeToVersion59(vars) == true)
		assert(vars.Modules.EnemyKickTrackerModule == kept, "the saved table moves across intact")
		assert(vars.Modules.KickTimerModule == nil, "and the old key is gone")
		assert(vars.Profiles.Other.Modules.EnemyKickTrackerModule.Icons.Size == 20, "profiles move too")
	end)

	fw.it("v60 moves the friendly indicator settings onto the auras module key", function()
		local kept = { Spells = { Custom = { [123456] = true } }, Default = { ShowKicks = true } }
		local vars = {
			Version = 59,
			Modules = { FriendlyIndicatorModule = kept },
			Profiles = { Other = { Modules = { FriendlyIndicatorModule = { Default = { ShowCC = true } } } } },
		}

		assert(migrator:UpgradeToVersion60(vars) == true)
		assert(vars.Modules.AurasModule == kept, "the saved table moves across intact")
		assert(vars.Modules.AurasModule.Spells.Custom[123456], "hand-added spells survive the move")
		assert(vars.Modules.FriendlyIndicatorModule == nil, "and the old key is gone")
		assert(vars.Profiles.Other.Modules.AurasModule.Default.ShowCC == true, "profiles move too")
	end)

	fw.it("v61 moves the auras settings onto the raid frame auras module key", function()
		local kept = { Spells = { Custom = { [123456] = true } }, Default = { ShowKicks = true } }
		local vars = {
			Version = 60,
			Modules = { AurasModule = kept },
			Profiles = { Other = { Modules = { AurasModule = { Default = { ShowCC = true } } } } },
		}

		assert(migrator:UpgradeToVersion61(vars) == true)
		assert(vars.Modules.RaidFrameAurasModule == kept, "the saved table moves across intact")
		assert(vars.Modules.RaidFrameAurasModule.Spells.Custom[123456], "hand-added spells survive the move")
		assert(vars.Modules.AurasModule == nil, "and the old key is gone")
		assert(vars.Profiles.Other.Modules.RaidFrameAurasModule.Default.ShowCC == true, "profiles move too")
	end)

	fw.it("v57 leaves kicks alone when the CC module is disabled everywhere", function()
		local vars = {
			Version = 56,
			Modules = {
				CCModule = { Enabled = { World = false, Arena = false } },
				FriendlyIndicatorModule = {
					Enabled = { World = true, Arena = true },
					Default = { ShowKicks = true },
					Raid = { ShowKicks = true },
				},
			},
		}
		assert(migrator:UpgradeToVersion57(vars) == true)
		assert(vars.Modules.FriendlyIndicatorModule.Default.ShowKicks == true)
		assert(vars.Modules.FriendlyIndicatorModule.Raid.ShowKicks == true)
	end)
end)

fw.describe("Migrator - defaults helpers", function()
	fw.it("GetModuleDefaults returns isolated deep copies", function()
		local first = migrator:GetModuleDefaults()
		first.CCModule.Default.Icons.Size = 999
		local second = migrator:GetModuleDefaults()
		assert(second.CCModule.Default.Icons.Size ~= 999, "mutating one copy must not leak into the next")
	end)

	fw.it("FillDefaults adds missing keys without overwriting existing values", function()
		_G.MiniCCDB = nil
		local db = migrator:GetAndUpgradeDb()
		db.FontScale = 1.25
		db.Modules.CCModule.Default.Icons.Size = 48
		migrator:FillDefaults()
		assert(db.FontScale == 1.25 and db.Modules.CCModule.Default.Icons.Size == 48, "existing values kept")
		assert(db.Modules.AlertsModule ~= nil, "missing keys restored")
	end)
end)
