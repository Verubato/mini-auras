---@type string, Addon
local _, addon = ...

---@class Db
---@field SpecCache table<string, {SpecId: number?, LastSeen: number?, LastAttempt: number?}>
local dbDefaults = {
	Version = 67,
	Profiles = {},
	ActiveProfile = "Default",
	AutoSwitch = {},
	WhatsNew = {},
	NotifiedChanges = true,
	GlowType = "Slot Glow",
	FontScale = 1.0,
	ConfigureBlizzardNameplates = true,
	DisableSwipe = false,
	-- Crops Blizzard's silver border off every icon. Off gives the stock art back.
	IconZoom = true,
	-- Off: enough people asked for it back off that it does not earn being the default.
	ColorCountdownByTime = false,
	FadeWithParent = true,
	MillisecondsThreshold = 5,
	-- Colour Countdown band tints: OmniCC's classic red under five seconds, yellow to the
	-- minute, white above.
	CountdownColors = {
		Under5s = { R = 1, G = 0, B = 0 },
		Under60s = { R = 1, G = 0.8, B = 0 },
		Over60s = { R = 1, G = 1, B = 1 },
	},
	LocaleOverride = false,
	-- TEMPORARY: true when first-time setup ran without MiniCCDB, so a legacy table appearing on
	-- a later login can still be offered for import. Dies with the settings bridge.
	MissedLegacyImport = false,
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

			Grow = "RIGHT",
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
				File = "Sonar",
			},

			Point = "CENTER",
			RelativePoint = "TOP",
			RelativeTo = "UIParent",
			Offset = {
				X = 0,
				Y = -220,
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
			-- Direction the alert bars extend as icons appear. Only LEFT and RIGHT render: the
			-- chained per-unit rows have secret widths, so there is nothing to centre on. An older
			-- db can still carry CENTER, which every reader resolves to RIGHT.
			Grow = "RIGHT",
			Point = "CENTER",
			RelativePoint = "TOP",
			RelativeTo = "UIParent",

			-- Sits between the starter custom aura row and the healer CC icons. Those two are
			-- 84 and 220 below the top of a 768 tall UIParent (the custom auras anchor from the
			-- centre, so 384 + 300), and this sits between them. At the old -100 the bar was
			-- only 16 below the custom auras and the two rows of icons overlapped.
			-- This anchor is the COMBINED bar's home; no X on purpose, the single bar belongs
			-- in the middle. Split mode uses the Defensives and Important anchors instead.
			Offset = {
				X = 0,
				Y = -150,
			},

			-- Split-mode anchor for the defensives bar, mirroring the important bar either
			-- side of a centre gap. Existing installs seed this from the main anchor instead
			-- (Migrations V63), so an already-running split layout does not move.
			Defensives = {
				Point = "CENTER",
				RelativePoint = "TOP",
				RelativeTo = "UIParent",
				Offset = {
					X = -220,
					Y = -150,
				},
			},

			-- Dedicated, separately-movable bar for important enemy buffs (e.g. offensive
			-- cooldowns), collected across every active enemy nameplate.
			Important = {
				Enabled = true,
				Point = "CENTER",
				RelativePoint = "TOP",
				RelativeTo = "UIParent",
				-- Split mode only: same row as the defensives bar, mirrored right of the centre
				-- gap. At the old -220 an enabled split bar sat on top of the healer CC icons.
				Offset = {
					X = 220,
					Y = -150,
				},
			},

			Sound = {
				-- One output channel for both alert categories, like the TTS announcements.
				Channel = "Master",
				-- Important-spell sound (opt-in, like the defensive sound). Important auras are now
				-- read reliably from Blizzard's nameplate buff lists.
				Important = {
					Enabled = false,
					File = "AirHorn",
				},
				Defensive = {
					Enabled = false,
					File = "AlertToastWarm",
				},
			},

			-- The Enabled flags turn the baked TTS clips on and VoicePack picks which pack plays.
			TTS = {
				VoicePack = "David",
				-- The engine plays the baked clips, so they need an output channel.
				Channel = "Master",
				-- Important-spell TTS (opt-in, like the defensive TTS). MutedSpellIds is what the
				-- TTS Spells tab writes: an opt-out list, so a category announces everything it
				-- has a clip for until something is switched off, including clips added later.
				Important = {
					Enabled = false,
					MutedSpellIds = {},
				},
				Defensive = {
					Enabled = false,
					MutedSpellIds = {},
				},
				-- Enemy cooldowns that land on your own side rather than on the caster, so they
				-- are announced on the party instead of on a nameplate.
				EnemyDebuff = {
					Enabled = false,
					MutedSpellIds = {},
				},
			},

			Icons = {
				Enabled = true,
				Size = 50,
				Glow = true,
				-- Per-category glow tints. Class colouring is not an option: UnitClass is secret.
				ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
				DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },
				-- A ring in the same category colour as the glow, so the glow can be switched off
				-- and the colouring kept. Off by default: the glow already carries it.
				Border = false,
				ReverseCooldown = true,
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

			-- Category tints for every bar that colours by category. CC takes the game's dispel
			-- type colours; these cover the two categories it has no colour for. Module wide
			-- rather than per bar, since a category should read the same on whichever bar it lands.
			ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
			DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },

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
						ShowMilliseconds = true,
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
						ShowMilliseconds = true,
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
						ShowMilliseconds = true,
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
						ShowMilliseconds = true,
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

			Bars = {
				Width = 260,
				Height = 35,
				-- Display name rather than a path, so a LibSharedMedia texture survives the
				-- library being reinstalled elsewhere.
				Texture = "Blizzard Raid Bar",
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
		---@class RaidFrameAurasModuleOptions
		RaidFrameAurasModule = {
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

			-- Category tints, applied wherever the dispel colours are switched on. CC takes the
			-- game's dispel type colours; these cover the buffs it has no colour for. Module wide,
			-- so a defensive reads the same on a party frame as it does on a raid frame.
			ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
			DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },

			---@class RaidFrameAurasInstanceOptions
			Default = {
				ExcludePlayer = false,
				ShowDefensives = true,
				ShowImportant = true,
				ShowCC = false,
				ShowKicks = false,
				Offset = { X = 0, Y = 0 },
				Grow = "CENTER",
				IconSpacing = 2,
				Icons = {
					Size = 20,
					SizeIsPercent = false,
					SizePercent = 75,
					Glow = true,
					ReverseCooldown = true,
					MaxIcons = 3,
					ColorByDispelType = true,
				},
				ShowTooltips = false,
			},

			---@type RaidFrameAurasInstanceOptions
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
					MaxIcons = 3,
					ColorByDispelType = true,
				},
				ShowTooltips = false,
			},
		},
		---@class CustomAurasModuleOptions
		---@field Groups CustomAuraGroup[] User-authored groups. Opaque to CleanTable, which would otherwise strip every entry against the empty template - see Config/Migrator.
		CustomAurasModule = {
			-- No module-wide Enabled table: each group carries its own switch.
			-- Everything here is authored by the user, so there is nothing sensible to ship.
			Groups = {},
			-- Ids handed out to new groups. A counter rather than the array length: deleting a
			-- group must never let the next one reuse a retired id.
			NextId = 1,
			-- Set once the starter groups have been created, so deleting them is permanent and
			-- an install updating from a version without them still gets them.
			SeededDefaults = false,
		},
	},
}

addon.Config.Defaults = dbDefaults
