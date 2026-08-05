---@type string, Addon
local _, addon = ...

---@class Db
---@field SpecCache table<string, {SpecId: number?, LastSeen: number?, LastAttempt: number?}>
---@field TalentCache table<string, {SpecId: number, TalentString: string, Time: number}>
---@field PvPTalentCache table<string, {Ids: number[], Time: number}>
local dbDefaults = {
	Version = 60,
	Profiles = {},
	ActiveProfile = "Default",
	AutoSwitch = {},
	WhatsNew = {},
	NotifiedChanges = true,
	GlowType = "Slot Glow",
	FontScale = 1.0,
	ConfigureBlizzardNameplates = true,
	CCNativeOrder = false,
	DisableSwipe = false,
	FadeWithParent = true,
	MillisecondsThreshold = 5,
	LocaleOverride = false,
	Modules = {
		---@class CrowdControlModuleOptions
		CCModule = {
			Enabled = {
				World = true,
				Arena = true,
				BattleGrounds = false,
				Dungeons = true,
				Raid = false,
			},

			---@class CrowdControlInstanceOptions
			Default = {
				ExcludePlayer = false,
				Offset = {
					X = 2,
					Y = 0,
				},
				Grow = "RIGHT",
				IconSpacing = 2,

				Icons = {
					Size = 32,
					SizeIsPercent = false,
					SizePercent = 80,
					Glow = true,
					ReverseCooldown = true,
					ColorByDispelType = true,
					Count = 3,
					ShowMilliseconds = false,
				},

				ShowTooltips = false,
			},

			---@type CrowdControlInstanceOptions
			Raid = {
				ExcludePlayer = false,
				Offset = {
					X = 2,
					Y = 0,
				},
				Grow = "CENTER",
				IconSpacing = 2,

				Icons = {
					Size = 20,
					SizeIsPercent = false,
					SizePercent = 50,
					Glow = true,
					ReverseCooldown = true,
					ColorByDispelType = true,
					Count = 3,
					ShowMilliseconds = false,
				},

				ShowTooltips = false,
			},
		},

		---@class PetCrowdControlModuleOptions
		---@field IncludePetFrame boolean Also anchor a CC container to the player's own pet unit frame (Blizzard PetFrame).
		PetCCModule = {
			Enabled = {
				World = false,
				Arena = false,
				BattleGrounds = false,
				Dungeons = false,
				Raid = false,
			},

			-- Also show a CC icon container next to the player's own pet unit frame (Blizzard PetFrame),
			-- in addition to the party/raid pet frames.
			IncludePetFrame = false,

			Grow = "CENTER",
			Offset = {
				X = 0,
				Y = 0,
			},

			IconSpacing = 2,

			Icons = {
				Size = 20,
				SizeIsPercent = false,
				SizePercent = 50,
				Count = 3,
				Glow = true,
				ReverseCooldown = true,
				ColorByDispelType = true,
			},

			ShowTooltips = false,
		},

		---@class HealerCrowdControlModuleOptions
		HealerCCModule = {
			Enabled = {
				World = true,
				Arena = true,
				BattleGrounds = false,
				Dungeons = true,
				Raid = false,
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

			IconSpacing = 2,

			Icons = {
				Enabled = true,
				Size = 50,
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
			ShowTooltips = false,
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
				World = true,
				Arena = true,
				BattleGrounds = false,
				Dungeons = false,
				Raid = false,
			},

			IncludeDefensives = true,
			-- false = important spells share the main alerts bar (combined); true = separate bars.
			SplitBars = false,
			-- Pixel padding between the alerts bar icons.
			IconSpacing = 2,
			-- Direction the alert bars extend as icons appear: LEFT, RIGHT, or CENTER (symmetric
			-- growth around the anchor; treated as RIGHT on 12.1, where the chained per-unit rows
			-- have secret widths and can't be centered). Filled from dbDefaults for existing dbs.
			Grow = "CENTER",
			Point = "CENTER",
			RelativePoint = "TOP",
			RelativeTo = "UIParent",

			Offset = {
				X = 0,
				Y = -100,
			},

			-- Dedicated, separately-movable bar for important enemy buffs (e.g. offensive cooldowns,
			-- precog), read from Blizzard's nameplate buff lists across every active enemy.
			Important = {
				Enabled = true,
				Point = "CENTER",
				RelativePoint = "TOP",
				RelativeTo = "UIParent",
				Offset = {
					X = 0,
					Y = -220,
				},
			},

			Sound = {
				-- Important-spell sound (opt-in, like the defensive sound). Important auras are now
				-- read reliably from Blizzard's nameplate buff lists.
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
				VoiceID = 0,
				SpeechRate = 0,
				-- Important-spell TTS (opt-in, like the defensive TTS).
				Important = {
					Enabled = false,
				},
				Defensive = {
					Enabled = false,
				},
			},

			Icons = {
				Enabled = true,
				Size = 50,
				Glow = true,
				-- Per-category glow tints (12.1 only; the legacy path colours by class instead).
				ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
				DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },
				ReverseCooldown = true,
				ColorByClass = true,
				MaxIcons = 8,
			},

			ShowTooltips = false,
		},
		---@class NameplateModuleOptions
		NameplatesModule = {
			Enabled = {
				World = true,
				Arena = true,
				BattleGrounds = true,
				Dungeons = true,
				Raid = true,
			},
			ScaleWithNameplate = true,
			-- Anchor icons to UnitFrame.HealthBarsContainer instead of the nameplate frame, so
			-- they follow addons that resize plates by shrinking that container (e.g. BBP).
			AnchorToHealthBar = false,

			---@class NameplateFactionOptions
			Friendly = {
				IgnorePets = true,
				---@class NameplateSpellTypeOptions
				Bar1 = {
					Enabled = false,
					ShowCC = true,
					ShowDefensives = false,
					ShowImportant = false,
					Grow = "LEFT",
					Offset = {
						X = 0,
						Y = 0,
					},

					Icons = {
						Size = 35,
						Glow = true,
						ReverseCooldown = true,
						ColorByCategory = true,
						MaxIcons = 5,
						ShowMilliseconds = false,
						-- Pixel padding between this bar's icons.
						Spacing = 2,
					},

					ShowTooltips = false,
				},
				Bar2 = {
					Enabled = false,
					ShowCC = false,
					ShowDefensives = true,
					ShowImportant = true,
					Grow = "RIGHT",
					Offset = {
						X = 0,
						Y = 0,
					},

					Icons = {
						Size = 35,
						Glow = true,
						ReverseCooldown = true,
						ColorByCategory = true,
						MaxIcons = 5,
						ShowMilliseconds = false,
						Spacing = 2,
					},

					ShowTooltips = false,
				},
			},
			Enemy = {
				IgnorePets = true,
				Bar1 = {
					Enabled = true,
					ShowCC = true,
					ShowDefensives = false,
					ShowImportant = false,
					Grow = "LEFT",
					Offset = {
						X = 0,
						Y = 0,
					},

					Icons = {
						Size = 35,
						Glow = true,
						ReverseCooldown = true,
						ColorByCategory = true,
						MaxIcons = 5,
						ShowMilliseconds = false,
						Spacing = 2,
					},

					ShowTooltips = false,
				},
				Bar2 = {
					Enabled = true,
					ShowCC = false,
					ShowDefensives = true,
					ShowImportant = true,
					Grow = "RIGHT",
					Offset = {
						X = 0,
						Y = 0,
					},

					Icons = {
						Size = 35,
						Glow = true,
						ReverseCooldown = true,
						ColorByCategory = true,
						MaxIcons = 5,
						ShowMilliseconds = false,
						Spacing = 2,
					},

					ShowTooltips = false,
				},
			},
		},
		---@class EnemyKickTrackerModuleOptions
		EnemyKickTrackerModule = {
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

			IconSpacing = 2,

			Icons = {
				Size = 50,
				Glow = false,
				Border = false,
				ReverseCooldown = true,
				-- Glow/border tint. These icons carry no dispel or category colouring to derive
				-- one from, so the colour is the user's choice.
				Color = { R = 1, G = 1, B = 1, A = 1 },
			},
		},
		---@class AllyKickTrackerModuleOptions
		AllyKickTrackerModule = {
			-- Dungeons only out of the box: that is where interrupt rotations are coordinated.
			-- Everywhere else the list is opt-in rather than another thing on a busy screen.
			Enabled = {
				Always = false,
				World = false,
				Arena = false,
				BattleGrounds = false,
				Dungeons = true,
				Raid = false,
			},

			-- Up and left of centre, clear of the unit frames and the middle of the screen.
			Point = "CENTER",
			RelativeTo = "UIParent",
			RelativePoint = "CENTER",
			Offset = {
				X = -620,
				Y = 160,
			},

			Grow = "DOWN",
			BarSpacing = 2,
			-- Unlocked by default: the rows are their own preview, so they are dragged into
			-- place and then locked out of the way of the mouse.
			Locked = false,
			-- Enough to read a pull's worth of interrupts without becoming a wall of them.
			MaxBars = 5,
			-- Your own interrupt pinned above the list, counting down to ready. Only your own
			-- cooldown can be read, so this is the one row that answers "can I kick now".
			ShowOwnCooldown = true,
			HideOutOfCombat = false,

			Bars = {
				Width = 260,
				Height = 35,
				-- Display name rather than a path, so a LibSharedMedia texture survives the
				-- library being reinstalled elsewhere.
				Texture = "Blizzard Raid Bar",
			},
		},
		-- Used by the standalone Party Trinkets module (12.1+); on older clients the friendly
		-- cooldown tracker renders the trinket slot instead.
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
				Size = 40,
				Glow = false,
				-- Off by default: the icons read fine bare, and a border only earns its pixels
				-- when the user asks for one.
				Border = false,
				ReverseCooldown = false,
				ShowText = true,
				-- Glow/border tint. These icons carry no dispel or category colouring to derive
				-- one from, so the colour is the user's choice.
				Color = { R = 1, G = 1, B = 1, A = 1 },
			},

			Font = {
				File = "GameFontHighlightSmall",
			},
		},
		---@class AurasModuleOptions
		AurasModule = {
			-- Helpful auras here are chosen by spell id rather than by Blizzard's category
			-- flags, so anything can be tracked - including spells the game never flags. Stored
			-- as deltas against the curated lists rather than a copy of them, so the saved
			-- variables stay small and a regenerated list still reaches existing profiles.
			Spells = {
				-- [spellId] = true, curated entries the user switched off.
				Disabled = {},
				-- [spellId] = true, ids the user added by hand.
				Custom = {},
				-- [spellId] = true, spells from AuraCategoryIds.DefaultOff the user switched ON.
				Enabled = {},
			},

			Enabled = {
				World = true,
				Arena = true,
				BattleGrounds = true,
				Dungeons = true,
				Raid = false,
			},

			---@class AurasInstanceOptions
			Default = {
				ExcludePlayer = false,
				ShowDefensives = true,
				ShowImportant = true,
				ShowCC = false,
				ShowKicks = true,
				Offset = { X = 0, Y = 0 },
				Grow = "CENTER",
				IconSpacing = 2,
				Icons = {
					Size = 30,
					SizeIsPercent = false,
					SizePercent = 75,
					Glow = true,
					ReverseCooldown = true,
					MaxIcons = 1,
					ColorByDispelType = true,
				},
				ShowTooltips = false,
			},

			---@type AurasInstanceOptions
			Raid = {
				ExcludePlayer = false,
				ShowDefensives = true,
				ShowImportant = true,
				ShowCC = true,
				ShowKicks = true,
				Offset = { X = 0, Y = 0 },
				Grow = "CENTER",
				IconSpacing = 2,
				Icons = {
					Size = 25,
					SizeIsPercent = false,
					SizePercent = 65,
					Glow = true,
					ReverseCooldown = true,
					MaxIcons = 1,
					ColorByDispelType = true,
				},
				ShowTooltips = false,
			},
		},
		---@class FriendlyCooldownTrackerModuleOptions
		---@field DisabledSpells table<number, boolean> SpellIds excluded from the static-ability display; keyed by SpellId, value true. Treated as an opaque user hash - CleanTable must not recurse into it.
		FriendlyCooldownTrackerModule = {
			Enabled = {
				World = true,
				Arena = true,
				BattleGrounds = false,
				Dungeons = true,
				Raid = false,
			},
			DisabledSpells = {},

			---@class FriendlyCooldownTrackerAnchorOptions
			---@field IconSpacing number
			---@field Predictive boolean When true, icons glow and show a countdown while a buff is active before the cooldown timer is committed.
			Default = {
				Grow = "LEFT",
				Offset = { X = -2, Y = 0 },
				ExcludeSelf = false,
				ShowTooltips = true,
				ShowTrinket = true,
				Predictive = true,
				IconSpacing = 2,
				Icons = {
					Size = 40,
					SizeIsPercent = false,
					SizePercent = 100,
					ReverseCooldown = true,
					DesaturateOnCooldown = false,
					MaxIcons = 10,
					Rows = 1,
					Columns = 1,
				},
			},

			---@type FriendlyCooldownTrackerAnchorOptions
			Raid = {
				Grow = "CENTER",
				Offset = { X = -2, Y = 0 },
				ExcludeSelf = false,
				ShowTooltips = true,
				ShowTrinket = true,
				Predictive = true,
				IconSpacing = 2,
				Icons = {
					Size = 20,
					SizeIsPercent = false,
					SizePercent = 50,
					ReverseCooldown = true,
					DesaturateOnCooldown = false,
					MaxIcons = 5,
					Rows = 1,
					Columns = 1,
				},
			},
		},

		---@class EnemyCooldownTrackerModuleOptions
		---@field DisabledSpells table<number, boolean> SpellIds excluded from the display; keyed by SpellId, value true. Treated as an opaque user hash - CleanTable must not recurse into it.
		EnemyCooldownTrackerModule = {
			Enabled = {
				World = false,
				Arena = true,
				BattleGrounds = false,
				Dungeons = false,
				Raid = false,
			},

			DisabledSpells = {},

			DisplayMode  = "Linear",
			ShowTooltips = false,
			IconSpacing  = 2,
			EntrySpacing = 4,
			AlwaysShow   = false,

			Icons = {
				Size                 = 40,
				ReverseCooldown      = true,
				DesaturateOnCooldown = false,
			},

			---@class EcdArenaFramesOptions
			ArenaFrames = {
				Grow   = "RIGHT",
				Offset = { X = 58, Y = 0 },
			},

			---@class EcdLinearOptions
			Linear = {
				Point         = "CENTER",
				RelativeTo    = "UIParent",
				RelativePoint = "CENTER",
				X             = 0,
				Y             = -100,
			},
		},

		---@class PrecogModuleOptions
		PrecogModule = {
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
				Border = true,
				ReverseCooldown = true,
				-- Glow/border tint. These icons carry no dispel or category colouring to derive
				-- one from, so the colour is the user's choice.
				Color = { R = 1, G = 1, B = 1, A = 1 },
			},
		},
	},
}

addon.Config.Defaults = dbDefaults
