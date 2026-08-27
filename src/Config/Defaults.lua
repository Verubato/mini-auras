---@type string, Addon
local _, addon = ...

---@class Db
local dbDefaults = {
	Version = 76,
	Profiles = {},
	ActiveProfile = "Default",
	AutoSwitch = {},
	WhatsNew = {},
	---@type table<string, {SpecId: number?, LastSeen: number?, LastAttempt: number?}>
	SpecCache = {},
	-- Markers a migration leaves for RunDeferredMigrations to settle at login, keyed by the
	-- version that wrote one.
	Pending = {},
	NotifiedChanges = true,
	GlowType = "Slot Glow",
	FontScale = 1.0,
	-- Font face for every module's text, by LibSharedMedia name. False leaves each piece of text in
	-- whatever face the game hands it, which is not one face.
	Font = false,
	ConfigureBlizzardNameplates = true,
	DisableSwipe = false,
	DisableNumbers = false,
	-- Crops Blizzard's silver border off every icon. Off gives the stock art back.
	IconZoom = true,
	-- Off by default because enough people asked for it to be off.
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
	-- Not a profile payload key. Whether the test captions are wanted is about the screen they
	-- would crowd, not about the group the profile is for.
	ShowTestLabels = true,
	-- Which of Blizzard's own party and raid frame aura rows Frame Auras has switched off, so a
	-- reload between the switch and the write still hands the row back. False until a side is
	-- switched on, and false again once it has been handed back. Written by the module.
	--
	-- Not a profile payload key. A cvar belongs to the client, so a profile that never enabled a
	-- side must not be able to answer for what the client had.
	FrameAuraCVars = { Buffs = false, Debuffs = false },
	-- Temporary. True when first-time setup ran without MiniCCDB, so a legacy table appearing on
	-- a later login can still be offered for import.
	MissedLegacyImport = false,
	Modules = {
		---@class CrowdControlModuleOptions
		CrowdControl = {
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
					-- The one tint every CC icon takes once the dispel palette is switched off.
					Color = { R = 0.64, G = 0.21, B = 0.93, A = 1 },
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
					Color = { R = 0.64, G = 0.21, B = 0.93, A = 1 },
					Count = 3,
					ShowMilliseconds = false,
				},

				ShowTooltips = false,
			},
		},

		---@class PetCrowdControlModuleOptions
		---@field IncludePetFrame boolean Also anchor a CC container to the player's own pet unit frame (Blizzard PetFrame).
		PetCrowdControl = {
			Enabled = {
				World = false,
				Arena = false,
				BattleGrounds = false,
				Dungeons = false,
				Raid = false,
			},

			-- Adds the player's own pet unit frame to the party and raid pet frames.
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
				Color = { R = 0.64, G = 0.21, B = 0.93, A = 1 },
			},

			ShowTooltips = false,
		},

		---@class HealerCrowdControlModuleOptions
		HealerCrowdControl = {
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
				MaxIcons = 5,
			},

			Font = {
				File = "Fonts\\FRIZQT__.TTF",
				Size = 32,
				Flags = "OUTLINE",
			},

			ShowWarningText = true,
			WarningTextColor = { R = 1, G = 0.1, B = 0.1 },
			ShowTooltips = false,
		},
		---@class PortraitModuleOptions
		---@field CustomSpells table<number, boolean> Ticked buffs. Opaque to CleanTable, which would strip every id against the empty template. See Config/Migrator.
		Portrait = {
			Enabled = {
				Always = true,
			},

			ReverseCooldown = true,
			-- Which of the unflagged buffs the player wants on their own portrait, under every
			-- flagged category. Buffs only: 12.1 drops a spell id map for harmful auras on a unit
			-- you can assist, and the layer would then match every debuff on you.
			CustomSpells = {},
		},
		---@class AlertsModuleOptions
		Alerts = {
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
			IconSpacing = 4,
			-- Direction the alert bars extend as icons appear. Only LEFT and RIGHT render: the
			-- chained per-unit rows have secret widths, so there is nothing to centre on. An older
			-- db can still carry CENTER, which every reader resolves to RIGHT.
			Grow = "RIGHT",
			Point = "CENTER",
			RelativePoint = "TOP",
			RelativeTo = "UIParent",

			-- Sits between the starter personal aura row and the healer CC icons, which are 84 and
			-- 220 below the top of a 768 tall UIParent. The personal auras anchor from the centre, so
			-- their 84 is 384 + 300 up from the bottom.
			-- X stays 0 because the single combined bar belongs in the middle. Split mode uses the
			-- Defensives and Important anchors instead.
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
				-- Split mode only: same row as the defensives bar, mirrored right of the centre gap.
				Offset = {
					X = 220,
					Y = -150,
				},
			},

			Sound = {
				-- One output channel for both alert categories, like the TTS announcements.
				Channel = "Master",
				-- Important-spell sound, opt-in like the defensive sound.
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
				-- Important-spell TTS, opt-in like the defensive TTS. MutedSpellIds is the opt-out
				-- list the TTS Spells tab writes, so a category announces everything it has a clip
				-- for, including clips added later.
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
				-- Colours every icon by the owner's class instead of by category. The unit's own
				-- class is secret in here, so an arena opponent's colour comes from their spec.
				-- Outside an arena the class is readable.
				ClassColors = true,
				-- Per-category glow tints, used when the above is off.
				ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
				DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },
				-- A ring in the same category colour as the glow, so the glow can be switched off
				-- and the colouring kept. Off by default because the glow already carries it.
				Border = false,
				ReverseCooldown = true,
				MaxIcons = 8,
			},

			ShowTooltips = false,
		},
		---@class NameplateModuleOptions
		Nameplates = {
			Enabled = {
				World = true,
				Arena = true,
				BattleGrounds = true,
				Dungeons = true,
				Raid = true,
			},
			ScaleWithNameplate = true,
			-- Anchor icons to UnitFrame.HealthBarsContainer rather than the nameplate frame, so
			-- they follow an addon that resizes plates by shrinking that container.
			AnchorToHealthBar = false,

			-- Category tints for every bar that colours by category. Module wide rather than per
			-- bar, since a category should read the same on whichever bar it lands.
			ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
			DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },
			-- Taken by CC and disarm on the bars whose UseDispelColors is off. The ones still on
			-- the dispel palette ignore it.
			CrowdControlColor = { R = 0.64, G = 0.21, B = 0.93, A = 1 },

			---@class NameplateFactionOptions
			Friendly = {
				IgnorePets = true,
				---@class NameplateSpellTypeOptions
				Bar1 = {
					Enabled = false,
					ShowCrowdControl = true,
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
						-- How this bar tints its icons, one of NameplatesDisplay.ColorMode. NONE
						-- leaves them untinted, DISPEL puts CC and disarm on the game's debuff
						-- type palette, CUSTOM puts them on the module's CrowdControlColor.
						ColorMode = "DISPEL",
						MaxIcons = 5,
						ShowMilliseconds = true,
						-- Pixel padding between this bar's icons.
						Spacing = 2,
					},

					ShowTooltips = false,
				},
				Bar2 = {
					Enabled = false,
					ShowCrowdControl = false,
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
						ColorMode = "DISPEL",
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
					ShowCrowdControl = true,
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
						ColorMode = "DISPEL",
						MaxIcons = 5,
						ShowMilliseconds = true,
						Spacing = 2,
					},

					ShowTooltips = false,
				},
				Bar2 = {
					Enabled = true,
					ShowCrowdControl = false,
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
						ColorMode = "DISPEL",
						MaxIcons = 5,
						ShowMilliseconds = true,
						Spacing = 2,
					},

					ShowTooltips = false,
				},
			},
		},
		---@class EnemyKickTrackerModuleOptions
		EnemyKickTracker = {
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
		AllyKickTracker = {
			-- Dungeons only out of the box, since that is where interrupt rotations are coordinated.
			Enabled = {
				Always = false,
				World = false,
				Arena = false,
				BattleGrounds = false,
				Dungeons = true,
				Raid = false,
			},

			-- Up and left of centre, clear of the unit frames and the middle of the screen.
			-- Anchored by the top edge, the pin a DOWN-growing list extends away from.
			Point = "TOP",
			RelativeTo = "UIParent",
			RelativePoint = "CENTER",
			Offset = {
				X = -620,
				Y = 160,
			},

			Grow = "DOWN",
			BarSpacing = 2,
			-- Unlocked by default because the rows are their own preview.
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
		Trinkets = {
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
				-- Off by default because the icons read fine bare.
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
		---@class ImportantAurasModuleOptions
		ImportantAuras = {
			-- Helpful auras here are chosen by spell id rather than by Blizzard's category flags, so
			-- anything can be tracked, including spells the game never flags. Stored as deltas
			-- against the curated lists, so the saved variables stay small and a regenerated list
			-- still reaches existing profiles.
			Spells = {
				-- [spellId] = true, curated entries the user switched off.
				Disabled = {},
				-- [spellId] = true, ids the user added by hand.
				Custom = {},
				-- [spellId] = true, spells from AuraCategoryIds.DefaultOff the user switched on.
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
			-- game's dispel type colours, so these cover the buffs it has no colour for. Module
			-- wide, so a defensive reads the same on a party frame as it does on a raid frame.
			ImportantColor = { R = 1, G = 0.2, B = 0.2, A = 1 },
			DefensiveColor = { R = 0.2, G = 1, B = 0.2, A = 1 },

			---@class ImportantAurasInstanceOptions
			Default = {
				ExcludePlayer = false,
				ShowDefensives = true,
				ShowImportant = true,
				ShowCrowdControl = false,
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

			---@type ImportantAurasInstanceOptions
			Raid = {
				ExcludePlayer = false,
				ShowDefensives = true,
				ShowImportant = true,
				ShowCrowdControl = true,
				ShowKicks = true,
				Offset = { X = 0, Y = 0 },
				Grow = "CENTER",
				IconSpacing = 2,
				Icons = {
					Size = 20,
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
		-- Stands in for Blizzard's own aura rows on the party, raid, target and focus frames, and
		-- marks a group member who is missing the buff the player's class brings. Each half carries
		-- its own switch, since replacing the raid frame buffs rarely means wanting the target
		-- frame taken over too.
		--
		-- Every switch here is off to start with, because the module takes frames the game already
		-- draws on.
		---@class FrameAurasModuleOptions
		---@field Spells { Disabled: table<number, boolean>, Custom: table<number, boolean> } Opaque to CleanTable, which would otherwise strip every entry against the empty template. See Config/Migrator.
		FrameAuras = {
			-- Deltas against the curated buff list rather than a copy of it, so the saved variables
			-- stay small and a later version's curated spells still reach an existing profile.
			Spells = {
				-- [spellId] = true, curated entries the user switched off.
				Disabled = {},
				-- [spellId] = true, ids the user added by hand.
				Custom = {},
			},

			---@class FrameAurasBuffOptions
			Buffs = {
				Enabled = false,
				-- A share of the frame's height rather than pixels, because a raid profile and a
				-- party profile size their frames very differently.
				Size = 35,
				MaxIcons = 6,
				PerRow = 3,
				-- Both on, because the tracked spell list is a list of things you cast. Without them
				-- the row fills with everyone's raid buffs.
				Filtered = true,
				Mine = true,
				ShortOnly = false,
				-- The categories Important Auras already draws its own row of, kept out of this one so
				-- the two do not both show the same icon.
				ShowImportant = false,
				ShowDefensives = false,
				-- The countdown text on this row alone. The global Disable Numbers switch still
				-- takes it off everywhere.
				EnableNumbers = false,
				-- The refresh-window reveal: one switch for the lot, since which spells carry it is
				-- fixed in the tracked data.
				PandemicGlow = true,
				PandemicColor = { R = 0.1, G = 0.9, B = 0.3 },
			},

			---@class FrameAurasDebuffOptions
			Debuffs = {
				Enabled = false,
				Size = 35,
				MaxIcons = 2,
				PerRow = 3,
				-- On, because a debuff you can cleanse is the one worth acting on first.
				Dispellable = true,
				-- On, because the debuffs that sit on a member all fight crowd out the one worth
				-- reacting to.
				ShortOnly = true,
				-- Same again: crowd control has its own row on the Important Auras page.
				ShowCrowdControl = false,
				-- Only the crowd control at the head of the row takes it. The debuffs behind it
				-- stand in for Blizzard's own, which draws a plain icon.
				ColorByDispelType = true,
				EnableNumbers = false,
				-- No "Mine" switch on this side. Everything landing on a group member came from
				-- somebody else, so filtering to your own would only ever empty the row.
			},

			---@class FrameAurasClassBuffOptions
			ClassBuff = {
				Enabled = false,
				-- A group buff nobody cast in the open world costs nothing, so the mark waits for a
				-- place with a pull in it.
				InstancesOnly = true,
				-- Only the size. Which corner the mark sits in is the frame's answer rather than the
				-- player's, like the corners the buff and debuff rows take.
				Size = 35,
			},

			---@class FrameAurasTargetOptions
			TargetFocus = {
				Enabled = false,
				-- Pixels rather than a share of the frame, which is a fixed size here.
				Size = 22,
				MaxIcons = 6,
				PerRow = 6,
				-- On, like the group buff row: a friendly target's buffs are worth narrowing to the
				-- tracked list. It only bites there either way, since a spell-id map is identity
				-- gated and the engine skips it for a helpful aura on a unit you cannot assist.
				Filtered = true,
				ShortBuffsOnly = true,
				-- Each only bites where it means anything: your own buffs on a unit you can help,
				-- your own debuffs on one you cannot. An enemy still shows the buffs worth purging.
				MyBuffs = true,
				MyDebuffs = true,
				-- Costs nothing to leave on, since the filter behind it answers "a dispel type you
				-- can remove" and a class with no purge never lights an icon up.
				PurgeGlow = true,
				PurgeColor = { R = 0.35, G = 0.7, B = 1 },
			},
		},
		---@class PersonalAurasModuleOptions
		---@field Groups PersonalAuraGroup[] User-authored groups. Opaque to CleanTable, which would otherwise strip every entry against the empty template. See Config/Migrator.
		PersonalAuras = {
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
