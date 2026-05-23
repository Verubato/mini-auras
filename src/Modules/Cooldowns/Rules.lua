--@type string, Addon
local _, addon = ...

addon.Modules.Cooldowns = addon.Modules.Cooldowns or {}

-- Rules keyed first by spec ID (more precise), then by class token (fallback).
-- Each rule carries flags for which aura type(s) it can match:
--   BigDefensive = true      matches BIG_DEFENSIVE auras from GetDefensiveState()
--   ExternalDefensive = true matches EXTERNAL_DEFENSIVE auras from GetDefensiveState()
--   Important = true         matches IMPORTANT auras from GetImportantState()
-- A rule may carry multiple flags when a spell is tagged as both (e.g. Paladin Divine Protection).
--
-- Paladin:     Holy=65,    Prot=66,      Ret=70
-- Warrior:     Arms=71,    Fury=72,      Prot=73
-- Mage:        Arcane=62,  Fire=63,      Frost=64
-- Hunter:      BM=253,     MM=254,       Survival=255
-- Priest:      Disc=256,   Holy=257,     Shadow=258
-- Rogue:       Assassination=259, Outlaw=260, Subtlety=261
-- Death Knight: Blood=250, Frost=251,    Unholy=252
-- Shaman:      Elem=262,   Enh=263,      Resto=264
-- Warlock:     Affliction=265, Demonology=266, Destruction=267
-- Monk:        Brew=268,   WW=269,       MW=270
-- Demon Hunter: Havoc=577, Vengeance=581, Devourer=1480
-- Druid:       Balance=102,Feral=103,    Guardian=104, Resto=105
-- Evoker:      Devas=1467, Preserv=1468, Aug=1473

-- SpellId maps a rule to the canonical spell ID used for talent CDR lookups.

---@class CooldownRules
local rules = {
	BySpec = {
		[65] = { -- Holy Paladin
			{
				BuffDuration = 12,
				Cooldown = 120,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 31884,
				MinDuration = true,
				ExcludeIfTalent = 216331,
			}, -- Avenging Wrath (hidden if Avenging Crusader talented)
			{
				BuffDuration = 10,
				Cooldown = 60,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 216331,
				MinDuration = true,
				RequiresTalent = 216331,
			}, -- Avenging Crusader
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 60,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				SpellId = 498,
			}, -- Divine Protection
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				SpellId = 1022,
				ExcludeIfTalent = 5692,
			}, -- Blessing of Protection (excluded when Spellwarding talented; both share the same 300s CD)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				SpellId = 204018,
				CastSpellId = 1022,
				RequiresTalent = 5692,
			}, -- Blessing of Spellwarding (matches both BoS and BoP casts when talented; CastSpellId=1022 so local player casting BoP is still attributed to BoS)
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				RequiresEvidence = "Shield",
				SelfCastable = false,
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[66] = { -- Protection Paladin
			{
				BuffDuration = 25,
				Cooldown = 120,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				MinDuration = true,
				SpellId = 31884,
				ExcludeIfTalent = 389539,
			}, -- Avenging Wrath (hidden if Sentinel talented)
			{
				BuffDuration = 20,
				Cooldown = 120,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				MinDuration = true,
				SpellId = 389539,
				RequiresTalent = 389539,
				ExcludeIfTalent = 31884,
			}, -- Sentinel (hidden if Avenging Wrath talented)
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 90,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				SpellId = 31850,
			}, -- Ardent Defender
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				Important = false,
				ExternalDefensive = false,
				SpellId = 86659,
				MaxCharges = 2,
			}, -- Guardian of Ancient Kings
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				SpellId = 1022,
				ExcludeIfTalent = 5692,
			}, -- Blessing of Protection (excluded when Spellwarding talented; both share the same 300s CD)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				SpellId = 204018,
				CastSpellId = 1022,
				RequiresTalent = 5692,
			}, -- Blessing of Spellwarding (matches both BoS and BoP casts when talented; CastSpellId=1022 so local player casting BoP is still attributed to BoS)
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				RequiresEvidence = "Shield",
				SelfCastable = false,
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[70] = { -- Retribution Paladin
			{
				BuffDuration = 24,
				Cooldown = 60,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				SpellId = 31884,
				ExcludeIfTalent = 458359,
			}, -- Avenging Wrath (hidden if Radiant Glory talented)
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 90,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				RequiresEvidence = "Shield",
				SpellId = 403876,
			}, -- Divine Protection (90s base for Ret)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				SpellId = 1022,
				ExcludeIfTalent = 5573,
			}, -- Blessing of Protection (excluded when Spellwarding talented; both share the same 300s CD)
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				SpellId = 204018,
				CastSpellId = 1022,
				RequiresTalent = 5573,
			}, -- Blessing of Spellwarding (matches both BoS and BoP casts when talented; CastSpellId=1022 so local player casting BoP is still attributed to BoS)
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				RequiresEvidence = "Shield",
				SelfCastable = false,
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[62] = { -- Arcane Mage
			{
				BuffDuration = 15,
				Cooldown = 90,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				MinDuration = true,
				SpellId = 365350,
			}, -- Arcane Surge
			{
				BuffDuration = 10,
				Cooldown = 240,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 45438,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				ExcludeIfTalent = 414659,
			}, -- Ice Block
		},
		[63] = { -- Fire Mage
			{
				BuffDuration = 10,
				Cooldown = 120,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				SpellId = 190319,
				MinDuration = true,
			}, -- Combustion
			{
				BuffDuration = 10,
				Cooldown = 240,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 45438,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				ExcludeIfTalent = 414659,
			}, -- Ice Block
		},
		[64] = { -- Frost Mage
			{
				BuffDuration = 10,
				Cooldown = 240,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 45438,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				ExcludeIfTalent = 414659,
				MaxCharges = 2,
			}, -- Ice Block
			{
				BuffDuration = 6,
				Cooldown = 240,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 414659,
				CastSpellId = 414658,
				RequiresEvidence = "Debuff",
				RequiresTalent = 414659,
				MaxCharges = 2,
			}, -- Ice Cold (replaces Ice Block)
		},
		[71] = { -- Arms Warrior
			{
				BuffDuration = 8,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 118038,
			}, -- Die by the Sword
			{
				BuffDuration = 20,
				Cooldown = 90,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				SpellId = 107574,
				MinDuration = true,
				RequiresTalent = 107574,
			}, -- Avatar
			{
				BuffDuration = 5,
				Cooldown = 25,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 23920,
				RequiresTalent = 23920,
			}, -- Spell Reflect
		},
		[72] = { -- Fury Warrior
			{
				BuffDuration = 8,
				AlternativeDurations = { 11 }, -- Invigorating Fury (+3s)
				Cooldown = 108,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 184364,
				RequiresTalent = 184364,
			}, -- Enraged Regeneration
			{
				BuffDuration = 20,
				Cooldown = 90,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				SpellId = 107574,
				MinDuration = true,
				RequiresTalent = 107574,
			}, -- Avatar
			{
				BuffDuration = 5,
				Cooldown = 25,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 23920,
				RequiresTalent = 23920,
			}, -- Spell Reflect
		},
		[73] = { -- Protection Warrior
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 871,
				MaxCharges = 2,
			}, -- Shield Wall
			{
				BuffDuration = 20,
				Cooldown = 90,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				SpellId = 107574,
				MinDuration = true,
				RequiresTalent = 107574,
			}, -- Avatar
			{
				BuffDuration = 5,
				Cooldown = 20,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 23920,
				RequiresTalent = 23920,
			}, -- Spell Reflect
		},
		[251] = {
			{
				BuffDuration = 12,
				Cooldown = 45,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				MinDuration = true,
				SpellId = 51271,
			},
		}, -- Frost Death Knight: Pillar of Frost
		[250] = { -- Blood Death Knight
			{
				BuffDuration = 10,
				AlternativeDurations = { 12, 14 }, -- Goreringers Anguish rank 1 (+2s) / rank 2 (+4s)
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 55233,
			}, -- Vampiric Blood
		},
		[256] = {
			{
				BuffDuration = 8,
				Cooldown = 180,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				SpellId = 33206,
				MaxCharges = 2,
			},
			{
				BuffDuration = 1,
				Cooldown = 30,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				ExcludeFromPrediction = true,
				SpellId = 408557,
				CastSpellId = 586,
				RequiresTalent = 5570,
				PvPOnly = true,
			}, -- Phase Shift (PvP talent)
		}, -- Discipline Priest: Pain Suppression
		[257] = { -- Holy Priest
			{
				BuffDuration = 10,
				Cooldown = 180,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				SpellId = 47788,
				ExcludeIfTalent = 440738,
			}, -- Guardian Spirit
			{
				BuffDuration = 12,
				Cooldown = 180,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				SpellId = 47788,
				RequiresTalent = 440738,
			}, -- Guardian Spirit (Foreseen Circumstances)
			{
				BuffDuration = 4.5,
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				CanCancelEarly = true,
				MinCancelDuration = 1.5, -- Phase Shift (PvP talent) applies a 1s IMPORTANT buff on Fade; exclude it
				SpellId = 64843,
			}, -- Divine Hymn
			{
				BuffDuration = 1,
				Cooldown = 30,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				ExcludeFromPrediction = true,
				SpellId = 408557,
				CastSpellId = 586,
				RequiresTalent = 5569,
				PvPOnly = true,
			}, -- Phase Shift (PvP talent)
		},
		[258] = { -- Shadow Priest
			{
				BuffDuration = 6,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				CrowdControl = true,
				CanCancelEarly = true,
				SpellId = 47585,
			}, -- Dispersion
			{
				BuffDuration = 8,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				CrowdControl = true,
				CanCancelEarly = true,
				SpellId = 47585,
				RequiresTalent = 453729,
			}, -- Dispersion + Heightened Alteration (+2s)
			{
				BuffDuration = 20,
				Cooldown = 120,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				-- Archon Sustainted Potency can increase the duration
				MinDuration = true,
				SpellId = 228260,
			}, -- Voidform
			{
				BuffDuration = 1,
				Cooldown = 30,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				ExcludeFromPrediction = true,
				SpellId = 408557,
				CastSpellId = 586,
				RequiresTalent = 5568,
				PvPOnly = true,
			}, -- Phase Shift (PvP talent)
		},
		[102] = {
			{
				BuffDuration = 20,
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				MinDuration = true,
				SpellId = 102560,
				MaxCharges = 2,
			},
		}, -- Balance Druid: Incarnation: Chosen of Elune
		[103] = {
			{
				BuffDuration = 15,
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				MinDuration = true,
				SpellId = 106951,
				RequiresTalent = 106951,
				ExcludeIfTalent = 102543,
			}, -- Feral Druid: Berserk (hidden if Incarnation talented)
			{
				BuffDuration = 20,
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 102543,
				RequiresTalent = 102543,
			}, -- Feral Druid: Incarnation: Avatar of Ashamane (shown when 102543 talented; Berserk self-excludes via ExcludeIfTalent=102543)
		},
		[104] = {
			{
				BuffDuration = 30,
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 102558,
			}, -- Guardian Druid: Incarnation: Guardian of Ursoc
			{
				BuffDuration = 8,
				AlternativeDurations = { 12 }, -- Improved Barkskin (+4s)
				Cooldown = 34,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 22812,
			}, -- Guardian Druid: Barkskin (34s cooldown vs the 60s class-wide rule for other specs)
		},
		[105] = {
			{
				BuffDuration = 12,
				Cooldown = 90,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				SpellId = 102342,
			},
		}, -- Restoration Druid: Ironbark
		[268] = { -- Brewmaster Monk
			{
				BuffDuration = 25,
				Cooldown = 120,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 132578,
			}, -- Invoke Niuzao, the Black Ox
			{
				BuffDuration = 15,
				Cooldown = 360,
				BigDefensive = true,
				Important = false,
				ExternalDefensive = false,
				SpellId = 115203,
			}, -- Fortifying Brew
		},
		[270] = {
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Shield",
				SpellId = 116849,
			}, -- Life Cocoon
			{
				BuffDuration = 2,
				Cooldown = 180,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				PvPOnly = true,
				SpellId = 115310,
				RequiresTalent = 5395,
				ExcludeIfTalent = 388615,
			}, -- Revival (requires Peaceweaver PvP talent)
			{
				BuffDuration = 2,
				Cooldown = 180,
				BigDefensive = false,
				ExternalDefensive = false,
				Important = true,
				PvPOnly = true,
				SpellId = 388615,
				RequiresTalent = 5395,
				ExcludeIfTalent = 115310,
			}, -- Restoral (requires Peaceweaver PvP talent)
		}, -- Mistweaver Monk
		[269] = { -- Windwalker Monk
			{
				BuffDuration = 15,
				Cooldown = 90,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				BaseCharges = 2,
				SpellId = 1249625,
			}, -- Zenith
			{
				BuffDuration = 10,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = false,
				CanCancelEarly = true,
				RequiresEvidence = "Shield",
				SpellId = 125174,
				CastSpellId = 122470,
			}, -- Touch of Karma
		},
		[577] = { -- Havoc Demon Hunter
			{
				BuffDuration = 10,
				Cooldown = 60,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 198589,
				MaxCharges = 2,
			}, -- Blur
		},
		[1480] = { -- Devourer Demon Hunter
			{
				BuffDuration = 10,
				Cooldown = 60,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = false,
				SpellId = 198589,
				MaxCharges = 2,
			}, -- Blur
		},
		[581] = { -- Vengeance Demon Hunter
			{
				BuffDuration = 12,
				Cooldown = 60,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = false,
				MinDuration = true,
				SpellId = 204021,
			}, -- Fiery Brand
			{
				BuffDuration = 15,
				AlternativeDurations = { 20 }, -- Vengeful Beast (+5s)
				Cooldown = 120,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 187827,
			}, -- Metamorphosis
		},
		[254] = {
			{
				BuffDuration = 15,
				AlternativeDurations = { 17 }, -- +2s talent
				Cooldown = 120,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 288613,
			}, -- Marksmanship Hunter: Trueshot
		},
		[255] = { -- Survival Hunter
			{
				BuffDuration = 8,
				AlternativeDurations = { 10 }, -- +2s talent
				Cooldown = 90,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 1250646,
			}, -- Takedown
		},
		[261] = {
			{
				BuffDuration = 16,
				AlternativeDurations = { 18, 20 }, -- set bonus +2s / +4s
				Cooldown = 90,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 121471,
				ExcludeFromPrediction = true, -- Shadow Dance (also IMPORTANT) cannot be distinguished without duration
				CanCancelEarly = true,
				MinCancelDuration = 11,
			}, -- Subtlety Rogue: Shadow Blades
		},
		[1467] = {
			{
				BuffDuration = 18,
				Cooldown = 120,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				MinDuration = true,
				SpellId = 375087,
			},
		}, -- Devastation Evoker: Dragonrage
		[1468] = {
			{
				BuffDuration = 8,
				Cooldown = 60,
				ExternalDefensive = true,
				BigDefensive = false,
				Important = false,
				SpellId = 357170,
				MaxCharges = 2,
			},
		}, -- Preservation Evoker: Time Dilation
		[1473] = {
			{
				BuffDuration = 13.4,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				MinDuration = true,
				SpellId = 363916,
				MaxCharges = 2,
			},
			{
				BuffDuration = 5,
				Cooldown = 41,
				BigDefensive = false,
				Important = true,
				ExternalDefensive = false,
				CrowdControl = true,
				CanCancelEarly = true,
				CastableOnOthers = true,
				RequiresEvidence = "UnitFlags",
				SpellId = 378441,
				RequiresTalent = { 5463, 5464, 5619 },
				PvPOnly = true,
			}, -- Time Stop (PvP talent)
		}, -- Augmentation Evoker: Obsidian Scales
		[264] = { -- Restoration Shaman
			{
				BuffDuration = 15,
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 114052,
				RequiresTalent = 114052,
			}, -- Ascendance
			{
				Cooldown = 120,
				SpellId  = 409293,
				RequiresTalent = 5576,
				PvPOnly = true,
				NoAura  = true,
				ExcludeFromEnemyTracking = true,
			}, -- Burrow
		},
		[262] = { -- Elemental Shaman
			{
				BuffDuration = 15,
				AlternativeDurations = { 18 }, -- Preeminence (+3s)
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 114050,
				RequiresTalent = 114050,
			}, -- Ascendance
			{
				Cooldown = 120,
				SpellId  = 409293,
				RequiresTalent = 5574,
				PvPOnly = true,
				NoAura  = true,
				ExcludeFromEnemyTracking = true,
			}, -- Burrow
		},
		[263] = { -- Enhancement Shaman
			{
				BuffDuration = 8,
				AlternativeDurations = { 10 }, -- Thorim's Invocation (+2s)
				Cooldown = 60,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 384352,
				RequiresTalent = 384352,
				ExcludeIfTalent = { 114051, 378270 },
			}, -- Doomwinds (hidden if Ascendance or Deeply Rooted Elements talented)
			{
				BuffDuration = 15,
				Cooldown = 180,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				SpellId = 114051,
				RequiresTalent = 114051,
			}, -- Ascendance
			{
				Cooldown = 120,
				SpellId  = 409293,
				RequiresTalent = 5575,
				PvPOnly = true,
				NoAura  = true,
				ExcludeFromEnemyTracking = true,
			}, -- Burrow
		},
	},
	ByClass = {
		PALADIN = {
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 25,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				CrowdControl = false, -- BoF is not a CC; rejects Time Stop (CrowdControl=true) false matches
				CanCancelEarly = true,
				MinCancelDuration = 1.5, -- Phase Shift (PvP talent) applies a 1s IMPORTANT buff on Fade; exclude it
				CastableOnOthers = true,
				SpellId = 1044,
			}, -- Blessing of Freedom
		},
		MAGE = {
			{
				BuffDuration = 10,
				Cooldown = 50,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 342246,
				CastSpellId = { 342245, 342247 },
			}, -- Alter Time
		},
		HUNTER = {
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				CanCancelEarly = true,
				SpellId = 186265,
				RequiresEvidence = "UnitFlags",
				ExcludeFromPrediction = true,
			}, -- Aspect of the Turtle
			{
				BuffDuration = 6,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				MinDuration = true,
				SpellId = 264735,
				MaxCharges = 2,
				RequiresEvidence = "PetAura",
			}, -- Survival of the Fittest (pet aura confirms over Aspect of the Turtle)
			{
				BuffDuration = 8,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				MinDuration = true,
				SpellId = 264735,
				MaxCharges = 2,
				RequiresEvidence = "PetAura",
			}, -- Survival of the Fittest + talent (+2s) (pet aura confirms over Aspect of the Turtle)
			{
				BuffDuration = 6,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				MinDuration = true,
				SpellId = 264735,
				MaxCharges = 2,
				RequiresEvidence = { Exclude = "UnitFlags" },
			}, -- Survival of the Fittest (no UnitFlags = not Aspect of the Turtle)
			{
				BuffDuration = 8,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				MinDuration = true,
				SpellId = 264735,
				MaxCharges = 2,
				RequiresEvidence = { Exclude = "UnitFlags" },
			}, -- Survival of the Fittest + talent (+2s) (no UnitFlags = not Aspect of the Turtle)
			{
				BuffDuration = 3,
				Cooldown = 60,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 109304,
				RequiresTalent = 430709,
				ExcludeFromPrediction = true,
			}, -- Exhilaration (Dark Ranger: applies 3s SotF)
			{
				BuffDuration = 10,
				Cooldown = 120,
				BigDefensive = false,
				ExternalDefensive = true,
				Important = false,
				CastableOnOthers = true,
				SpellId = 53480,
				RequiresTalent = 53480,
			}, -- Roar of Sacrifice
		},
		DRUID = {
			{
				BuffDuration = 8,
				AlternativeDurations = { 12 }, -- Improved Barkskin (+4s)
				Cooldown = 60,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 22812,
			}, -- Barkskin
		},
		ROGUE = {
			{
				BuffDuration = 10,
				Cooldown = 120,
				Important = true,
				ExternalDefensive = false,
				BigDefensive = false,
				SpellId = 5277,
				ExcludeFromPrediction = true, -- Shadow Dance (also IMPORTANT) cannot be distinguished without duration
			}, -- Evasion
			{
				BuffDuration = 5,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = false,
				SpellId = 31224,
			}, -- Cloak of Shadows
		},
		DEATHKNIGHT = {
			{
				BuffDuration = 5,
				Cooldown = 60,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				CanCancelEarly = true,
				SpellId = 48707,
				RequiresEvidence = "Shield",
			}, -- Anti-Magic Shell (BigDefensive, without Spellwarding)
			{
				BuffDuration = 7,
				Cooldown = 60,
				BigDefensive = true,
				Important = true,
				ExternalDefensive = false,
				CanCancelEarly = true,
				SpellId = 48707,
				RequiresEvidence = "Shield",
			}, -- Anti-Magic Shell + Anti-Magic Barrier (+40%) (BigDefensive, without Spellwarding)
			{
				BuffDuration = 8,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 48792,
			}, -- Icebound Fortitude
			{
				BuffDuration = 5,
				Cooldown = 60,
				BigDefensive = false,
				Important = true,
				ExternalDefensive = false,
				CanCancelEarly = true,
				SpellId = 48707,
				CastSpellId = 410358,
				CastableOnOthers = true,
				RequiresEvidence = "Shield",
			}, -- Anti-Magic Shell (Spellwarding self-cast, or cast on ally)
			{
				BuffDuration = 7,
				Cooldown = 60,
				BigDefensive = false,
				Important = true,
				ExternalDefensive = false,
				CanCancelEarly = true,
				CastableOnOthers = true,
				SpellId = 48707,
				CastSpellId = 410358,
				RequiresEvidence = "Shield",
			}, -- Anti-Magic Shell + AMB +40% (Spellwarding self-cast, or cast on ally)
		},
		DEMONHUNTER = {},
		WARRIOR = {
			{
				BuffDuration = 10,
				Cooldown = 60,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				CanCancelEarly = true,
				SpellId = 1227751,
				CastSpellId = 384100,
				RequiresTalent = 5702,
				PvPOnly = true,
			}, -- Beserker Roar (PvP talent; AoE IMPORTANT buff for nearby party members)
		},
		MONK = {
			{
				BuffDuration = 15,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = false,
				SpellId = 115203,
			},
		}, -- Fortifying Brew
		SHAMAN = {
			{
				BuffDuration = 12,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 108271,
			}, -- Astral Shift
			{
				BuffDuration = 3.5,
				Cooldown = 30,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				CanCancelEarly = true,
				MinCancelDuration = 0.5,
				SpellId = 204336,
				RequiresTalent = { 3620, 3622, 715 },
				PvPOnly = true,
			}, -- Grounding Totem (PvP talent, consumed in 0.5-3s)
		},
		WARLOCK = {
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 104773,
			}, -- Unending Resolve
			{
				BuffDuration = 3,
				Cooldown = 45,
				Important = true,
				BigDefensive = false,
				ExternalDefensive = false,
				CanCancelEarly = true,
				SpellId = 212295,
				RequiresTalent = { 18, 3508, 3624 },
				PvPOnly = true,
			}, -- Nether Ward (PvP talent)
		},
		PRIEST = {
			{
				BuffDuration = 10,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				SpellId = 19236,
			}, -- Desperate Prayer
		},
		EVOKER = {
			{
				BuffDuration = 12,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				Important = true,
				MinDuration = true,
				SpellId = 363916,
				MaxCharges = 2,
			}, -- Obsidian Scales
			{
				BuffDuration = 5,
				Cooldown = 45,
				BigDefensive = false,
				Important = true,
				ExternalDefensive = false,
				CrowdControl = true,
				CanCancelEarly = true,
				CastableOnOthers = true,
				RequiresEvidence = "UnitFlags",
				SpellId = 378441,
				RequiresTalent = { 5463, 5464, 5619 },
				PvPOnly = true,
			}, -- Time Stop (PvP talent)
			{
				Cooldown = 180,
				SpellId  = 370960,
				RequiresTalent = 5718,
				PvPOnly = true,
				NoAura  = true,
			}, -- Emerald Communion (PvP talent, detected via UNIT_SPELLCAST_CHANNEL_START+UNIT_FLAGS)
		},
	},
}

-- Spell IDs treated as offensive cooldowns for the ShowOffensiveCooldowns option.
local offensiveSpellIds = {
	[375087] = true, -- Dragonrage
	[107574] = true, -- Avatar
	[121471] = true, -- Shadow Blades
	[31884] = true, -- Avenging Wrath
	[216331] = true, -- Avenging Crusader
	[190319] = true, -- Combustion
	[288613] = true, -- Trueshot
	[228260] = true, -- Voidform
	[102560] = true, -- Incarnation: Chosen of Elune (Balance)
	[102543] = true, -- Incarnation: Avatar of Ashamane (Feral)
	[106951] = true, -- Berserk (Feral, same choice node as Incarnation)
	[102558] = true, -- Incarnation: Guardian of Ursoc (Guardian)
	[1250646] = true, -- Takedown
	[384352] = true, -- Doomwinds
	[114051] = true, -- Ascendance (Enhancement)
	[114050] = true, -- Ascendance (Elemental)
}

rules.OffensiveSpellIds = offensiveSpellIds

-- Lazily built spellId -> rule lookup for GetSpellType.
local spellTypeCache = nil

local function BuildSpellTypeCache()
	spellTypeCache = {}
	for _, ruleList in pairs(rules.BySpec) do
		for _, rule in ipairs(ruleList) do
			if rule.SpellId then
				spellTypeCache[rule.SpellId] = rule
			end
		end
	end
	for _, ruleList in pairs(rules.ByClass) do
		for _, rule in ipairs(ruleList) do
			if rule.SpellId and not spellTypeCache[rule.SpellId] then
				spellTypeCache[rule.SpellId] = rule
			end
		end
	end
end

---Returns the type of a spell: "Offensive", "Defensive", or "Important".
---"Defensive" means the rule has BigDefensive or ExternalDefensive set.
---"Offensive" means the spell is in the offensive set.
---"Important" is the fallback for spells that are neither.
---@param spellId number
---@return "Offensive"|"Defensive"|"Important"
function rules.GetSpellType(spellId)
	if offensiveSpellIds[spellId] then
		return "Offensive"
	end
	if not spellTypeCache then
		BuildSpellTypeCache()
	end
	local rule = spellTypeCache[spellId]
	if rule and (rule.BigDefensive or rule.ExternalDefensive) then
		return "Defensive"
	end
	return "Important"
end

-- Static spec ID -> class token mapping for every spec declared above.  A hardcoded table is used
-- (rather than GetSpecializationInfoByID) because that API can return nil for newer or
-- environment-dependent specs.  Lets callers recover an enemy's class from their spec when
-- UnitClass is unavailable - notably during arena prep, before the unit tokens exist.
local specToClass = {
	[250]  = "DEATHKNIGHT", [251]  = "DEATHKNIGHT", [252]  = "DEATHKNIGHT",
	[577]  = "DEMONHUNTER", [581]  = "DEMONHUNTER", [1480] = "DEMONHUNTER",
	[102]  = "DRUID",       [103]  = "DRUID",        [104]  = "DRUID",       [105] = "DRUID",
	[1467] = "EVOKER",      [1468] = "EVOKER",       [1473] = "EVOKER",
	[253]  = "HUNTER",      [254]  = "HUNTER",       [255]  = "HUNTER",
	[62]   = "MAGE",        [63]   = "MAGE",         [64]   = "MAGE",
	[268]  = "MONK",        [269]  = "MONK",         [270]  = "MONK",
	[65]   = "PALADIN",     [66]   = "PALADIN",      [70]   = "PALADIN",
	[256]  = "PRIEST",      [257]  = "PRIEST",       [258]  = "PRIEST",
	[259]  = "ROGUE",       [260]  = "ROGUE",        [261]  = "ROGUE",
	[262]  = "SHAMAN",      [263]  = "SHAMAN",       [264]  = "SHAMAN",
	[265]  = "WARLOCK",     [266]  = "WARLOCK",      [267]  = "WARLOCK",
	[71]   = "WARRIOR",     [72]   = "WARRIOR",      [73]   = "WARRIOR",
}

---Returns the class token for a spec ID, or nil if the spec is unknown.
---@param specId number?
---@return string? classToken
function rules.GetClassForSpec(specId)
	return specId and specToClass[specId] or nil
end

-- Lazily built specId/classToken -> ordered, deduplicated spell ID list for GetTrackableSpellIds.
local trackableSpellIdCache = {}

---Returns true when a rule's ability is removed/replaced by a near-universal default talent, so it
---should not appear in the enemy always-show list (e.g. Avenging Wrath when Radiant Glory - a spec
---default - is assumed).  Enemy talents are unknowable, so the assumed-default build is the best
---guess; the ability still tracks live (via the active-cooldown path) if the enemy actually casts it.
local function ExcludedByDefaultTalent(rule, specId, classToken)
	local excl = rule.ExcludeIfTalent
	if not excl then return false end
	local talents = addon.Modules.Cooldowns.Talents
	if not (talents and talents.IsDefaultTalent) then return false end
	if type(excl) == "table" then
		for _, id in ipairs(excl) do
			if talents:IsDefaultTalent(classToken, specId, id) then return true end
		end
		return false
	end
	return talents:IsDefaultTalent(classToken, specId, excl)
end

---Returns a deduplicated, ordered list of trackable spell IDs for the given spec and class.
---Used by the EnemyCooldowns "always show" display to render every cooldown an enemy of that
---spec might use.  Spec rules come first (more specific), class rules are appended; duplicate
---SpellIds (talent/duration variants of the same ability) collapse to one entry.  Rules flagged
---ExcludeFromEnemyTracking, or whose ExcludeIfTalent is a near-universal default (so the ability is
---almost certainly replaced - e.g. Avenging Wrath under Radiant Glory), are skipped.  The returned
---table is cached and must not be mutated.
---@param specId number?
---@param classToken string?
---@return number[]
function rules.GetTrackableSpellIds(specId, classToken)
	local cacheKey = (specId or "?") .. ":" .. (classToken or "?")
	local cached = trackableSpellIdCache[cacheKey]
	if cached then
		return cached
	end

	local result = {}
	local seen = {}
	local function addList(ruleList)
		if not ruleList then return end
		for _, rule in ipairs(ruleList) do
			local id = rule.SpellId
			if id and not seen[id] and not rule.ExcludeFromEnemyTracking
			   and not ExcludedByDefaultTalent(rule, specId, classToken) then
				seen[id] = true
				result[#result + 1] = id
			end
		end
	end
	addList(specId and rules.BySpec[specId])
	addList(classToken and rules.ByClass[classToken])

	trackableSpellIdCache[cacheKey] = result
	return result
end

---Test helper: clears the trackable-spell cache so it rebuilds against current (mock) talent
---data.  Production code never needs this - default talents are static at runtime.
function rules._TestResetTrackableCache()
	for k in pairs(trackableSpellIdCache) do trackableSpellIdCache[k] = nil end
end

-- Lazily built set of spell IDs whose rule(s) carry ExcludeFromEnemyTracking.
local enemyExcludedSpellIds = nil

local function BuildEnemyExcludedSet()
	enemyExcludedSpellIds = {}
	local function scan(ruleList)
		for _, rule in ipairs(ruleList) do
			if rule.SpellId and rule.ExcludeFromEnemyTracking then
				enemyExcludedSpellIds[rule.SpellId] = true
			end
		end
	end
	for _, ruleList in pairs(rules.BySpec) do scan(ruleList) end
	for _, ruleList in pairs(rules.ByClass) do scan(ruleList) end
end

---Returns true if the given spell ID is flagged ExcludeFromEnemyTracking on any of its rules.
---The aura-match path already drops these via RulePassesTalentGates, and the always-show list
---skips them in GetTrackableSpellIds; this lets the signature-detection commit path (which builds
---synthetic rules, e.g. Burrow) honour the same flag.
---@param spellId number?
---@return boolean
function rules.IsExcludedFromEnemyTracking(spellId)
	if not spellId then return false end
	if not enemyExcludedSpellIds then BuildEnemyExcludedSet() end
	return enemyExcludedSpellIds[spellId] == true
end

addon.Modules.Cooldowns.Rules = rules
