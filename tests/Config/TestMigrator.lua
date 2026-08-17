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
assert(loadfile("src/Core/Profiles/ProfileManager.lua"))("MiniAuras", addon)
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
_G.MiniAurasDB = nil
local LATEST_VERSION = migrator:GetAndUpgradeDb().Version
assert(type(LATEST_VERSION) == "number" and LATEST_VERSION >= 55, "sane latest version")

local expectedModules = {
	"CCModule", "PetCCModule", "HealerCCModule", "PortraitModule", "AlertsModule",
	"NameplatesModule", "EnemyKickTrackerModule", "TrinketsModule", "RaidFrameAurasModule",
}

-- Modules the addon no longer ships. Their settings are not in dbDefaults any more, so the final
-- CleanTable must drop them outright rather than leaving orphaned tables behind.
local removedModules = {
	"FriendlyCooldownTrackerModule", "EnemyCooldownTrackerModule", "PrecogModule",
}

fw.describe("Migrator - fresh install", function()
	fw.before_each(function()
		_G.MiniAurasDB = nil
	end)

	fw.it("produces the full current-version schema", function()
		local db = migrator:GetAndUpgradeDb()
		assert(db.Version == LATEST_VERSION)
		for _, name in ipairs(expectedModules) do
			assert(type(db.Modules[name]) == "table", "missing module defaults: " .. name)
		end
		for _, name in ipairs(removedModules) do
			assert(db.Modules[name] == nil, "removed module still seeded: " .. name)
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

fw.describe("Migrator - retired settings in stored profiles", function()
	-- CleanTable never recurses into Profiles, so a snapshot keeps whatever the addon had when it
	-- was saved. Switching to it writes the whole payload back over the live db, which is how a
	-- retired setting would otherwise round-trip forever.
	fw.it("prunes settings the addon no longer ships from every snapshot", function()
		_G.MiniAurasDB = {
			Version = LATEST_VERSION,
			Profiles = {
				Old = {
					GlowType = "Slot Glow",
					CCNativeOrder = true,
					Modules = {
						CCModule = { Default = { Grow = "LEFT" } },
						AlertsModule = {
							Icons = { Size = 60, ColorByClass = true },
							TTS = { VoicePack = "David", Volume = 100, SpeechRate = 3 },
						},
						FriendlyCooldownTrackerModule = { DisabledSpells = { [12345] = true } },
						EnemyCooldownTrackerModule = { DisplayMode = "Linear" },
					},
				},
				Empty = { Modules = {} },
				NoModules = {},
			},
		}

		local db = migrator:GetAndUpgradeDb()
		local old = db.Profiles.Old

		assert(old.Modules.CCModule.Default.Grow == "LEFT", "a shipped module's settings are untouched")
		assert(old.GlowType == "Slot Glow", "a shipped top-level payload key is untouched")
		assert(old.Modules.AlertsModule.Icons.Size == 60, "a shipped nested key is untouched")
		assert(old.Modules.AlertsModule.TTS.VoicePack == "David", "a shipped nested key is untouched")

		for _, name in ipairs(removedModules) do
			assert(old.Modules[name] == nil, "retired module survived in a snapshot: " .. name)
		end
		-- Retired keys nested inside a module that still ships, which a module-level sweep alone
		-- could never reach.
		assert(old.CCNativeOrder == nil, "retired top-level key survived")
		assert(old.Modules.AlertsModule.Icons.ColorByClass == nil, "retired icon key survived")
		assert(old.Modules.AlertsModule.TTS.Volume == nil, "retired TTS key survived")
		assert(old.Modules.AlertsModule.TTS.SpeechRate == nil, "retired TTS key survived")

		assert(db.Profiles.Empty ~= nil and db.Profiles.NoModules ~= nil, "odd-shaped profiles survive")
	end)

	fw.it("leaves user-authored tables whole", function()
		-- An empty table in the defaults means the user authors the contents, so every key in it is
		-- unknown to the schema and a blind prune would wipe the lot.
		_G.MiniAurasDB = {
			Version = LATEST_VERSION,
			Profiles = {
				Mine = {
					Modules = {
						CustomAurasModule = { Groups = { { Id = "g1", Name = "Mine", SpellIds = { 123 } } } },
						RaidFrameAurasModule = { Spells = { Disabled = { [456] = true }, Custom = { [789] = true } } },
					},
				},
			},
		}

		local mine = migrator:GetAndUpgradeDb().Profiles.Mine.Modules

		assert(mine.CustomAurasModule.Groups[1].Name == "Mine", "authored aura group kept")
		assert(mine.CustomAurasModule.Groups[1].SpellIds[1] == 123, "authored group contents kept")
		assert(mine.RaidFrameAurasModule.Spells.Disabled[456] == true, "spell-id hash kept")
		assert(mine.RaidFrameAurasModule.Spells.Custom[789] == true, "spell-id hash kept")
	end)

	fw.it("keeps the TTS per-spell switches across a login", function()
		-- Both states matter: true is a spell switched off, false is one of the default-off
		-- spells switched on, and dropping either reverts the tab to its defaults every session.
		_G.MiniAurasDB = nil

		local db = migrator:GetAndUpgradeDb()
		db.Modules.AlertsModule.TTS.Important.MutedSpellIds[12472] = true
		db.Modules.AlertsModule.TTS.Defensive.MutedSpellIds[235313] = false

		local tts = migrator:GetAndUpgradeDb().Modules.AlertsModule.TTS

		assert(tts.Important.MutedSpellIds[12472] == true, "a muted spell stays muted")
		assert(tts.Defensive.MutedSpellIds[235313] == false, "and a default-off spell stays switched on")
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
			_G.MiniAurasDB = deepCopy(fixture)
			local db = migrator:GetAndUpgradeDb()
			assert(db.Version == LATEST_VERSION, label .. ": version healed")
			assert(type(db.Modules) == "table" and db.Modules.CCModule, label .. ": modules present")
			assert(db.Foo == nil and db.Whatever == nil, label .. ": unknown keys cleaned")
		end)
	end

	fw.it("a db from a NEWER version soft-resets but keeps recognized settings", function()
		_G.MiniAurasDB = { Version = LATEST_VERSION + 100, FontScale = 1.4, Garbage = "x" }
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
		_G.MiniAurasDB = {
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
		for _, name in ipairs(removedModules) do
			assert(db.Modules[name] == nil, "removed module survived the chain: " .. name)
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
		_G.MiniAurasDB = {
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

		-- The cooldown trackers are gone, so their whole customized table is cleaned away rather
		-- than migrated. The v48 Split -> Linear step still runs against it; nothing survives it.
		assert(db.Modules.EnemyCooldownTrackerModule == nil, "removed tracker settings cleaned away")

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

	fw.it("v62 pre-seeds the starter custom aura groups from the precog settings", function()
		local vars = {
			Version = 61,
			Modules = {
				PrecogModule = {
					Enabled = { Always = true },
					Sound = { Enabled = true, Channel = "SFX", File = "ElectricalSpark" },
					Point = "TOP",
					RelativeTo = "UIParent",
					RelativePoint = "TOP",
					Offset = { X = 12, Y = -80 },
					Icons = { Size = 44, Glow = false, Border = true, ReverseCooldown = false, Color = { R = 0.2, G = 0.4, B = 0.6, A = 1 } },
				},
			},
		}

		assert(migrator:UpgradeToVersion62(vars) == true)
		local customAuras = vars.Modules.CustomAurasModule
		assert(customAuras.SeededDefaults == true and customAuras.NextId == 4, "seeding stood down")

		local precogGroup, shroud, pi = customAuras.Groups[1], customAuras.Groups[2], customAuras.Groups[3]
		assert(precogGroup.Spells[1] == 377362 and shroud.Spells[1] == 378464 and pi.Spells[1] == 10060)
		-- Position and icon settings land on both precog-era groups.
		for _, group in ipairs({ precogGroup, shroud }) do
			assert(group.Position.Point == "TOP" and group.Position.X == 12 and group.Position.Y == -80, "position carried")
			assert(group.Icons.Size == 44 and group.Icons.Glow == false and group.Icons.Border == true, "icon settings carried")
			assert(group.Icons.ReverseCooldown == false and group.Icons.Color.B == 0.6, "cooldown and color carried")
			assert(group.Enabled == true, "enabled carried")
		end
		-- The module only ever sounded for precog.
		assert(precogGroup.Sound.Applied == "ElectricalSpark" and precogGroup.Sound.Channel == "SFX", "sound carried")
		assert(shroud.Sound == nil, "shroud stays silent")
		-- PI has no precog history, so it keeps the designed spot.
		assert(pi.Position.X == 0 and pi.Position.Y == 300 and pi.Sound.Applied == "BubblePop")
	end)

	fw.it("v62 seeds disabled groups from a disabled precog and skips already-seeded profiles", function()
		local vars = {
			Version = 61,
			Modules = {
				PrecogModule = { Enabled = { Always = false }, Sound = { Enabled = false } },
			},
			Profiles = {
				Seeded = { Modules = { CustomAurasModule = { SeededDefaults = true, NextId = 7, Groups = {} } } },
				Fresh = { Modules = {} },
			},
		}

		assert(migrator:UpgradeToVersion62(vars) == true)
		local groups = vars.Modules.CustomAurasModule.Groups
		assert(groups[1].Enabled == false and groups[2].Enabled == false, "precog off carries as disabled groups")
		assert(groups[3].Enabled == nil, "PI is untouched by the precog switch")
		assert(groups[1].Sound == nil, "disabled sound does not carry")
		-- The precog colour was left at its default white, so the designed tints land instead.
		assert(groups[1].Icons.Color.G == 1 and groups[3].Icons.Color.G == 0.82, "white precog, gold PI")
		assert(groups[2].Icons.Color.R == 0.64 and groups[2].Icons.Color.B == 0.93, "purple shroud")

		local seeded = vars.Profiles.Seeded.Modules.CustomAurasModule
		assert(seeded.NextId == 7 and seeded.Groups[1] == nil, "seeded profile left alone")
		-- A profile that predates the precog module still seeds, at the precog defaults.
		local fresh = vars.Profiles.Fresh.Modules.CustomAurasModule
		assert(fresh.SeededDefaults == true and fresh.Groups[1].Position.Y == 70, "ancient profile gets precog defaults")
	end)

	fw.it("v63 seeds the split defensives anchor from the main alerts anchor", function()
		local vars = {
			Version = 62,
			Modules = {
				AlertsModule = {
					Point = "LEFT",
					RelativePoint = "BOTTOMLEFT",
					RelativeTo = "UIParent",
					Offset = { X = 33, Y = -77 },
				},
			},
			Profiles = {
				Seeded = { Modules = { AlertsModule = { Defensives = { Offset = { X = 1, Y = 2 } } } } },
				Fresh = { Modules = { AlertsModule = { Offset = { X = 5, Y = -9 } } } },
			},
		}

		assert(migrator:UpgradeToVersion63(vars) == true)
		local defensives = vars.Modules.AlertsModule.Defensives
		assert(defensives.Point == "LEFT" and defensives.RelativePoint == "BOTTOMLEFT", "anchor point carried")
		assert(defensives.Offset.X == 33 and defensives.Offset.Y == -77,
			"an already-positioned split layout does not move")
		assert(vars.Profiles.Seeded.Modules.AlertsModule.Defensives.Offset.X == 1, "an existing anchor is kept")
		assert(vars.Profiles.Fresh.Modules.AlertsModule.Defensives.Offset.X == 5, "profiles seed too")
		assert(vars.Version == 63)
	end)

	fw.it("v65 turns on the enemy debuff announcement for anyone already hearing importants", function()
		local vars = {
			Version = 64,
			Modules = { AlertsModule = { TTS = { Important = { Enabled = true } } } },
			Profiles = {
				Quiet = { Modules = { AlertsModule = { TTS = { Important = { Enabled = false } } } } },
				Loud = { Modules = { AlertsModule = { TTS = { Important = { Enabled = true } } } } },
			},
		}

		assert(migrator:UpgradeToVersion65(vars) == true)
		assert(vars.Modules.AlertsModule.TTS.EnemyDebuff.Enabled == true, "the new half follows the old")
		assert(vars.Profiles.Loud.Modules.AlertsModule.TTS.EnemyDebuff.Enabled == true, "profiles too")
		assert(vars.Profiles.Quiet.Modules.AlertsModule.TTS.EnemyDebuff == nil,
			"a profile that wanted no announcements is left silent")
		assert(vars.Version == 65)
	end)

	fw.it("v66 turns the countdown colouring off everywhere, profiles included", function()
		local vars = {
			Version = 65,
			ColorCountdownByTime = true,
			Profiles = {
				On = { ColorCountdownByTime = true },
				Off = { ColorCountdownByTime = false },
			},
		}

		assert(migrator:UpgradeToVersion66(vars) == true)
		assert(vars.ColorCountdownByTime == false, "off for the live settings")
		assert(vars.Profiles.On.ColorCountdownByTime == false, "and for a profile that had it on")
		assert(vars.Profiles.Off.ColorCountdownByTime == false, "one that was already off stays off")
		assert(vars.Version == 66)
	end)

	fw.it("v67 shortens the starter precog group's name, leaving renamed ones alone", function()
		local vars = {
			Version = 66,
			Modules = {
				CustomAurasModule = {
					Groups = {
						{ Id = "g1", Name = "Precognition", Spells = { 377362 } },
						{ Id = "g2", Name = "Shroud", Spells = { 378464 } },
					},
				},
			},
			Profiles = {
				Starter = { Modules = { CustomAurasModule = { Groups = { { Id = "g1", Name = "Precognition" } } } } },
				Renamed = { Modules = { CustomAurasModule = { Groups = { { Id = "g1", Name = "My Precog" } } } } },
			},
		}

		assert(migrator:UpgradeToVersion67(vars) == true)
		assert(vars.Modules.CustomAurasModule.Groups[1].Name == "Precog", "the default name is shortened")
		assert(vars.Modules.CustomAurasModule.Groups[2].Name == "Shroud", "the other starters are untouched")
		assert(vars.Profiles.Starter.Modules.CustomAurasModule.Groups[1].Name == "Precog", "profiles too")
		assert(vars.Profiles.Renamed.Modules.CustomAurasModule.Groups[1].Name == "My Precog",
			"a name the user typed is left alone")
		assert(vars.Version == 67)
	end)

	fw.it("v68 re-pins the ally kick list to the edge it grows away from", function()
		local vars = {
			Version = 67,
			Modules = {
				AllyKickTrackerModule = {
					Point = "CENTER",
					RelativePoint = "CENTER",
					Offset = { X = -620, Y = 160 },
					Grow = "DOWN",
					Bars = { Width = 260, Height = 40 },
				},
			},
			Profiles = {
				Up = {
					Modules = {
						AllyKickTrackerModule = {
							Point = "BOTTOMLEFT",
							Offset = { X = 10, Y = 20 },
							Grow = "UP",
							Bars = { Width = 200, Height = 30 },
						},
					},
				},
				Pinned = {
					Modules = {
						AllyKickTrackerModule = {
							Point = "TOP",
							Offset = { X = 1, Y = 2 },
							Grow = "DOWN",
						},
					},
				},
			},
		}

		assert(migrator:UpgradeToVersion68(vars) == true)

		local tracker = vars.Modules.AllyKickTrackerModule
		assert(tracker.Point == "TOP", "a DOWN list pins by the top")
		assert(tracker.Offset.X == -620 and tracker.Offset.Y == 180,
			"the centre moves up to the one-row top edge, got " .. tracker.Offset.Y)

		local up = vars.Profiles.Up.Modules.AllyKickTrackerModule
		assert(up.Point == "BOTTOM", "an UP list pins by the bottom")
		assert(up.Offset.X == 110 and up.Offset.Y == 20,
			"a corner offset moves to mid-width and the bottom edge stays")

		local pinned = vars.Profiles.Pinned.Modules.AllyKickTrackerModule
		assert(pinned.Offset.X == 1 and pinned.Offset.Y == 2, "an already-pinned anchor is left alone")
		assert(vars.Version == 68)
	end)

	fw.it("v69 folds the nameplate colour booleans into one mode, profiles included", function()
		local function Bar(icons)
			return { Icons = icons }
		end

		local vars = {
			Version = 68,
			Modules = {
				NameplatesModule = {
					Enemy = {
						Bar1 = Bar({ ColorByCategory = true }),
						Bar2 = Bar({ ColorByCategory = false }),
					},
					Friendly = {
						Bar1 = Bar({ ColorByCategory = true, UseDispelColors = false }),
						Bar2 = Bar({}),
					},
				},
			},
			Profiles = {
				Plain = {
					Modules = {
						NameplatesModule = {
							Enemy = { Bar1 = Bar({ ColorByCategory = false }) },
						},
					},
				},
			},
		}

		assert(migrator:UpgradeToVersion69(vars) == true)

		local enemy = vars.Modules.NameplatesModule.Enemy
		local friendly = vars.Modules.NameplatesModule.Friendly
		assert(enemy.Bar1.Icons.ColorMode == "DISPEL", "colouring on with no override stays on the palette")
		assert(enemy.Bar2.Icons.ColorMode == "NONE", "colouring off becomes the None mode")
		assert(friendly.Bar1.Icons.ColorMode == "CUSTOM", "the dispel override becomes the Custom mode")
		assert(friendly.Bar2.Icons.ColorMode == "DISPEL", "a bar with neither key takes the shipped mode")
		assert(enemy.Bar1.Icons.ColorByCategory == nil and friendly.Bar1.Icons.UseDispelColors == nil,
			"the booleans they replaced are dropped")

		local profile = vars.Profiles.Plain.Modules.NameplatesModule.Enemy.Bar1
		assert(profile.Icons.ColorMode == "NONE", "a snapshot is folded the same way")
		assert(vars.Version == 69)
	end)

	fw.it("v70 switches class colours on only where the category tints were untouched", function()
		-- Class colouring throws the category scheme away, so someone who picked their own
		-- important and defensive colours keeps what they chose. Only the off case is written:
		-- leaving it nil is what lets the defaults fill it in as on.
		local function Icons(important, defensive)
			return { Icons = { ImportantColor = important, DefensiveColor = defensive } }
		end

		local shippedImportant = { R = 1, G = 0.2, B = 0.2, A = 1 }
		local shippedDefensive = { R = 0.2, G = 1, B = 0.2, A = 1 }

		local vars = {
			Version = 69,
			Modules = { AlertsModule = Icons(shippedImportant, shippedDefensive) },
			Profiles = {
				Custom = {
					Modules = { AlertsModule = Icons({ R = 0.9, G = 0.1, B = 0.8, A = 1 }, shippedDefensive) },
				},
				Bare = { Modules = { AlertsModule = { Icons = {} } } },
				OneCustom = {
					Modules = { AlertsModule = Icons(shippedImportant, { R = 0, G = 0, B = 1, A = 1 }) },
				},
			},
		}

		assert(migrator:UpgradeToVersion70(vars) == true)

		assert(vars.Modules.AlertsModule.Icons.ClassColors == nil,
			"the shipped colours are left for the defaults to switch on")
		assert(vars.Profiles.Custom.Modules.AlertsModule.Icons.ClassColors == false,
			"a custom important colour keeps its own scheme")
		assert(vars.Profiles.OneCustom.Modules.AlertsModule.Icons.ClassColors == false,
			"one custom colour out of the two is enough")
		assert(vars.Profiles.Bare.Modules.AlertsModule.Icons.ClassColors == nil,
			"a profile that never had the colours is running the shipped ones")
		assert(vars.Version == 70)
	end)

	fw.it("v70 leaves a choice that was already made alone", function()
		local vars = {
			Version = 69,
			Modules = {
				AlertsModule = {
					Icons = {
						ClassColors = false,
						ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
						DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },
					},
				},
			},
		}

		assert(migrator:UpgradeToVersion70(vars) == true)
		assert(vars.Modules.AlertsModule.Icons.ClassColors == false, "an existing answer wins")
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

fw.describe("Migrator - opaque user data", function()
	-- Custom aura groups are authored entirely by the user, so the schema ships an empty array to
	-- compare them against - which is exactly the shape CleanTable strips everything out of.
	fw.it("keeps custom aura groups through the final CleanTable", function()
		_G.MiniAurasDB = nil

		local db = migrator:GetAndUpgradeDb()

		db.Modules.CustomAurasModule.Groups[1] = {
			Id = "g1",
			Name = "Ice Block",
			Spells = { 45438 },
			Icons = { Size = 55 },
		}
		db.Modules.CustomAurasModule.NextId = 2

		-- A soft reset runs the same save/clean/restore the upgrade path finishes with.
		local cleaned = migrator:SoftReset()
		local groups = cleaned.Modules.CustomAurasModule.Groups

		assert(groups[1], "the group survives")
		assert(groups[1].Name == "Ice Block", "with its name")
		assert(groups[1].Spells[1] == 45438, "and its spell list")
		assert(groups[1].Icons.Size == 55, "and its geometry")
	end)
end)

fw.describe("Migrator - adopting the MiniCC saved variable", function()
	fw.before_each(function()
		_G.MiniAurasDB = nil
		_G.MiniCCDB = nil
	end)

	fw.it("carries the old settings over on the first run under the new name", function()
		_G.MiniCCDB = { Version = LATEST_VERSION, FontScale = 1.35 }

		local db = migrator:GetAndUpgradeDb()

		assert(db.FontScale == 1.35, "the old value came across")
		assert(db.Version == LATEST_VERSION, "and lands on the current schema")
	end)

	fw.it("copies rather than adopts, so a rollback still finds the old table", function()
		_G.MiniCCDB = { Version = LATEST_VERSION, FontScale = 1.35 }

		local db = migrator:GetAndUpgradeDb()
		db.FontScale = 1.6

		assert(_G.MiniCCDB.FontScale == 1.35, "the old table is untouched")
		assert(_G.MiniAurasDB ~= _G.MiniCCDB, "and is a separate table")
	end)

	fw.it("leaves an existing MiniAurasDB alone", function()
		_G.MiniAurasDB = { Version = LATEST_VERSION, FontScale = 1.1 }
		_G.MiniCCDB = { Version = LATEST_VERSION, FontScale = 1.35 }

		local db = migrator:GetAndUpgradeDb()

		assert(db.FontScale == 1.1, "the new table wins once it exists")
	end)

	fw.it("still produces a fresh install when there is nothing to adopt", function()
		local db = migrator:GetAndUpgradeDb()

		assert(db.Version == LATEST_VERSION)
		assert(type(db.Modules.CCModule) == "table")
	end)

	fw.it("remembers when first-time setup ran without the old table", function()
		local db = migrator:GetAndUpgradeDb()

		-- Adoption is one-shot, so this flag is the only way a MiniCCDB that surfaces on a
		-- later login (bridge disabled or out of date on the first one) can still be offered.
		assert(db.MissedLegacyImport == true, "the miss is recorded")
	end)

	fw.it("records no miss when the old table was there to adopt", function()
		_G.MiniCCDB = { Version = LATEST_VERSION, FontScale = 1.35 }

		local db = migrator:GetAndUpgradeDb()

		assert(db.MissedLegacyImport == false, "adoption happened, nothing was missed")
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
		_G.MiniAurasDB = nil
		local db = migrator:GetAndUpgradeDb()
		db.FontScale = 1.25
		db.Modules.CCModule.Default.Icons.Size = 48
		migrator:FillDefaults()
		assert(db.FontScale == 1.25 and db.Modules.CCModule.Default.Icons.Size == 48, "existing values kept")
		assert(db.Modules.AlertsModule ~= nil, "missing keys restored")
	end)
end)
