---@type string, Addon
local _, addon = ...

---@class KickData
local M = {}
addon.Core.KickData = M

-- PvP school lockout durations in seconds (manually tested in-game). Silence is the one entry
-- that diminishes, so a repeat inside the DR window runs shorter than the icon shows.
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
	[15487]  = 4, -- Silence (Shadow Priest)
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
	[259] = { SpellId = 1766,   KickCd = 15, IsCaster = false, IsHealer = false, Class = "ROGUE" }, -- Assassination
	[260] = { SpellId = 1766,   KickCd = 15, IsCaster = false, IsHealer = false, Class = "ROGUE" }, -- Outlaw
	[261] = { SpellId = 1766,   KickCd = 15, IsCaster = false, IsHealer = false, Class = "ROGUE" }, -- Subtlety

	-- Warrior
	[71]  = { SpellId = 6552,   KickCd = 15, IsCaster = false, IsHealer = false, Class = "WARRIOR" }, -- Arms
	[72]  = { SpellId = 6552,   KickCd = 15, IsCaster = false, IsHealer = false, Class = "WARRIOR" }, -- Fury
	[73]  = { SpellId = 6552,   KickCd = 15, IsCaster = false, IsHealer = false, Class = "WARRIOR" }, -- Protection

	-- Death Knight
	[250] = { SpellId = 47528,  KickCd = 15, IsCaster = false, IsHealer = false, Class = "DEATHKNIGHT" }, -- Blood
	[251] = { SpellId = 47528,  KickCd = 15, IsCaster = false, IsHealer = false, Class = "DEATHKNIGHT" }, -- Frost
	[252] = { SpellId = 47528,  KickCd = 15, IsCaster = false, IsHealer = false, Class = "DEATHKNIGHT" }, -- Unholy

	-- Demon Hunter
	[577]  = { SpellId = 183752, KickCd = 15, IsCaster = false, IsHealer = false, Class = "DEMONHUNTER" }, -- Havoc
	[581]  = { SpellId = 183752, KickCd = 15, IsCaster = false, IsHealer = false, Class = "DEMONHUNTER" }, -- Vengeance
	[1480] = { SpellId = 183752, KickCd = 15, IsCaster = false, IsHealer = false, Class = "DEMONHUNTER" }, -- Devourer

	-- Monk
	[268] = { SpellId = 116705, KickCd = 15,  IsCaster = false, IsHealer = false, Class = "MONK" }, -- Brewmaster
	[269] = { SpellId = 116705, KickCd = 15,  IsCaster = false, IsHealer = false, Class = "MONK" }, -- Windwalker
	[270] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true , Class = "MONK" }, -- Mistweaver

	-- Paladin
	[65]  = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true , Class = "PALADIN" }, -- Holy
	[66]  = { SpellId = 96231,  KickCd = 15,  IsCaster = false, IsHealer = false, Class = "PALADIN" }, -- Protection
	[70]  = { SpellId = 96231,  KickCd = 15,  IsCaster = false, IsHealer = false, Class = "PALADIN" }, -- Retribution

	-- Druid
	[102] = { SpellId = 78675,  KickCd = 60,  IsCaster = true,  IsHealer = false, Class = "DRUID" }, -- Balance
	[103] = { SpellId = 106839, KickCd = 15,  IsCaster = false, IsHealer = false, Class = "DRUID" }, -- Feral
	[104] = { SpellId = 106839, KickCd = 15,  IsCaster = false, IsHealer = false, Class = "DRUID" }, -- Guardian
	[105] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true , Class = "DRUID" }, -- Restoration

	-- Hunter
	[253] = { SpellId = 147362, KickCd = 24,  IsCaster = true,  IsHealer = false, Class = "HUNTER" }, -- Beast Mastery
	[254] = { SpellId = 147362, KickCd = 24,  IsCaster = true,  IsHealer = false, Class = "HUNTER" }, -- Marksmanship
	[255] = { SpellId = 187707, KickCd = 15,  IsCaster = false, IsHealer = false, Class = "HUNTER" }, -- Survival

	-- Mage
	[62]  = { SpellId = 2139,   KickCd = 20,  IsCaster = true,  IsHealer = false, Class = "MAGE" }, -- Arcane
	[63]  = { SpellId = 2139,   KickCd = 20,  IsCaster = true,  IsHealer = false, Class = "MAGE" }, -- Fire
	[64]  = { SpellId = 2139,   KickCd = 20,  IsCaster = true,  IsHealer = false, Class = "MAGE" }, -- Frost

	-- Warlock
	[265] = { SpellId = 132409, KickCd = 24,  IsCaster = true,  IsHealer = false, Class = "WARLOCK" }, -- Affliction
	[266] = { SpellId = 132409, KickCd = 30,  IsCaster = true,  IsHealer = false, Class = "WARLOCK" }, -- Demonology
	[267] = { SpellId = 132409, KickCd = 24,  IsCaster = true,  IsHealer = false, Class = "WARLOCK" }, -- Destruction

	-- Shaman
	[262] = { SpellId = 57994,  KickCd = 12,  IsCaster = true,  IsHealer = false, Class = "SHAMAN" }, -- Elemental
	[263] = { SpellId = 57994,  KickCd = 12,  IsCaster = false, IsHealer = false, Class = "SHAMAN" }, -- Enhancement
	[264] = { SpellId = 57994,  KickCd = 30,  IsCaster = false, IsHealer = true , Class = "SHAMAN" }, -- Restoration

	-- Evoker
	[1467] = { SpellId = 351338, KickCd = 20, IsCaster = true,  IsHealer = false, Class = "EVOKER" }, -- Devastation
	[1468] = { SpellId = nil,    KickCd = nil, IsCaster = false, IsHealer = true , Class = "EVOKER" }, -- Preservation
	[1473] = { SpellId = nil,    KickCd = nil, IsCaster = true,  IsHealer = false, Class = "EVOKER" }, -- Augmentation

	-- Priest
	[256] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true , Class = "PRIEST" }, -- Discipline
	[257] = { SpellId = nil,    KickCd = nil,  IsCaster = false, IsHealer = true , Class = "PRIEST" }, -- Holy
	[258] = { SpellId = 15487,  KickCd = 45,   IsCaster = true,  IsHealer = false, Class = "PRIEST" }, -- Shadow (Silence)
}

---@class KickSpecData
---@field SpellId number?  -- interrupt spell ID; nil = spec has no interrupt
---@field KickCd number?   -- cooldown of the interrupt in seconds; nil = no interrupt
---@field IsCaster boolean
---@field IsHealer boolean
---@field Class string    -- class token of the spec
