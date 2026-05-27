---@type string, Addon
local _, addon = ...

---@class KickSpecData
---@field SpellId number?  -- interrupt spell ID; nil = spec has no interrupt
---@field KickCd number?   -- cooldown of the interrupt in seconds; nil = no interrupt
---@field IsCaster boolean
---@field IsHealer boolean

---@class KickData
local M = {}
addon.Core.KickData = M

-- PvP school lockout durations in seconds (manually tested in-game).
---@type table<number, number>
M.SpellLockoutDuration = {
	[1766]   = 3, -- Kick (Rogue)
	[6552]   = 3, -- Pummel (Warrior)
	[47528]  = 3, -- Mind Freeze (Death Knight)
	[183752] = 3, -- Disrupt (Demon Hunter)
	[116705] = 3, -- Spear Hand Strike (Monk)
	[96231]  = 3, -- Rebuke (Paladin)
	[78675]  = 5, -- Solar Beam (Balance Druid)
	[106839] = 3, -- Skull Bash (Druid)
	[147362] = 3, -- Counter Shot (Hunter)
	[187707] = 3, -- Muzzle (Hunter)
	[2139]   = 6, -- Counterspell (Mage)
	[57994]  = 2, -- Wind Shear (Shaman)
	[351338] = 3, -- Quell (Evoker)
	[132409] = 5, -- Spell Lock (Warlock pet)
	[119910] = 5, -- Command Demon: Spell Lock (Warlock player-side cast)
}

-- Class token fallback used when a unit's spec is unknown.
-- Only covers classes where every PvP-relevant spec shares the same interrupt.
-- Classes with spec-dependent interrupts (Druid, Hunter, Priest) are intentionally absent;
-- their specs are fully enumerated in SpecData below.
---@type table<string, number>
M.ClassInterruptSpell = {
	["WARRIOR"]     = 6552,   -- Pummel
	["DEATHKNIGHT"] = 47528,  -- Mind Freeze
	["DEMONHUNTER"] = 183752, -- Disrupt
	["MONK"]        = 116705, -- Spear Hand Strike (Brewmaster/Windwalker; Mistweaver excluded via SpecData)
	["PALADIN"]     = 96231,  -- Rebuke (Prot/Ret; Holy excluded via SpecData)
	["ROGUE"]       = 1766,   -- Kick
	["MAGE"]        = 2139,   -- Counterspell
	["SHAMAN"]      = 57994,  -- Wind Shear
	["EVOKER"]      = 351338, -- Quell (Devastation; Preservation/Augmentation excluded via SpecData)
	["WARLOCK"]     = 132409, -- Spell Lock (pet)
}

-- Per-spec interrupt data. SpellId = nil means the spec has no interrupt.
---@type table<number, KickSpecData>
M.SpecData = {
	-- Rogue
	[259] = { SpellId = 1766,   KickCd = 15, IsCaster = false, IsHealer = false }, -- Assassination
	[260] = { SpellId = 1766,   KickCd = 15, IsCaster = false, IsHealer = false }, -- Outlaw
	[261] = { SpellId = 1766,   KickCd = 15, IsCaster = false, IsHealer = false }, -- Subtlety

	-- Warrior
	[71]  = { SpellId = 6552,   KickCd = 15, IsCaster = false, IsHealer = false }, -- Arms
	[72]  = { SpellId = 6552,   KickCd = 15, IsCaster = false, IsHealer = false }, -- Fury
	[73]  = { SpellId = 6552,   KickCd = 15, IsCaster = false, IsHealer = false }, -- Protection

	-- Death Knight
	[250] = { SpellId = 47528,  KickCd = 15, IsCaster = false, IsHealer = false }, -- Blood
	[251] = { SpellId = 47528,  KickCd = 15, IsCaster = false, IsHealer = false }, -- Frost
	[252] = { SpellId = 47528,  KickCd = 15, IsCaster = false, IsHealer = false }, -- Unholy

	-- Demon Hunter
	[577]  = { SpellId = 183752, KickCd = 15, IsCaster = false, IsHealer = false }, -- Havoc
	[581]  = { SpellId = 183752, KickCd = 15, IsCaster = false, IsHealer = false }, -- Vengeance
	[1480] = { SpellId = 183752, KickCd = 15, IsCaster = false, IsHealer = false }, -- Devourer

	-- Monk
	[268] = { SpellId = 116705, KickCd = 15,  IsCaster = false, IsHealer = false }, -- Brewmaster
	[269] = { SpellId = 116705, KickCd = 15,  IsCaster = false, IsHealer = false }, -- Windwalker
	[270] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true  }, -- Mistweaver

	-- Paladin
	[65]  = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true  }, -- Holy
	[66]  = { SpellId = 96231,  KickCd = 15,  IsCaster = false, IsHealer = false }, -- Protection
	[70]  = { SpellId = 96231,  KickCd = 15,  IsCaster = false, IsHealer = false }, -- Retribution

	-- Druid
	[102] = { SpellId = 78675,  KickCd = 60,  IsCaster = true,  IsHealer = false }, -- Balance
	[103] = { SpellId = 106839, KickCd = 15,  IsCaster = false, IsHealer = false }, -- Feral
	[104] = { SpellId = 106839, KickCd = 15,  IsCaster = false, IsHealer = false }, -- Guardian
	[105] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true  }, -- Restoration

	-- Hunter
	[253] = { SpellId = 147362, KickCd = 24,  IsCaster = true,  IsHealer = false }, -- Beast Mastery
	[254] = { SpellId = 147362, KickCd = 24,  IsCaster = true,  IsHealer = false }, -- Marksmanship
	[255] = { SpellId = 187707, KickCd = 15,  IsCaster = false, IsHealer = false }, -- Survival

	-- Mage
	[62]  = { SpellId = 2139,   KickCd = 20,  IsCaster = true,  IsHealer = false }, -- Arcane
	[63]  = { SpellId = 2139,   KickCd = 20,  IsCaster = true,  IsHealer = false }, -- Fire
	[64]  = { SpellId = 2139,   KickCd = 20,  IsCaster = true,  IsHealer = false }, -- Frost

	-- Warlock
	[265] = { SpellId = 132409, KickCd = 24,  IsCaster = true,  IsHealer = false }, -- Affliction
	[266] = { SpellId = 132409, KickCd = 30,  IsCaster = true,  IsHealer = false }, -- Demonology
	[267] = { SpellId = 132409, KickCd = 24,  IsCaster = true,  IsHealer = false }, -- Destruction

	-- Shaman
	[262] = { SpellId = 57994,  KickCd = 12,  IsCaster = true,  IsHealer = false }, -- Elemental
	[263] = { SpellId = 57994,  KickCd = 12,  IsCaster = false, IsHealer = false }, -- Enhancement
	[264] = { SpellId = 57994,  KickCd = 30,  IsCaster = false, IsHealer = true  }, -- Restoration

	-- Evoker
	[1467] = { SpellId = 351338, KickCd = 20, IsCaster = true,  IsHealer = false }, -- Devastation
	[1468] = { SpellId = nil,    KickCd = nil, IsCaster = false, IsHealer = true  }, -- Preservation
	[1473] = { SpellId = nil,    KickCd = nil, IsCaster = true,  IsHealer = false }, -- Augmentation

	-- Priest
	[256] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true  }, -- Discipline
	[257] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true  }, -- Holy
	[258] = { SpellId = nil,    KickCd = nil,  IsCaster = true,  IsHealer = false }, -- Shadow
}
