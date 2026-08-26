---@type string, Addon
local _, addon = ...

-- The group-wide buff each class brings, keyed by the class that casts it. Only the classes that
-- have one are listed.
local buffs = {
	DRUID = {
		-- Mark of the Wild
		Icon = 1126,
		Auras = { [1126] = true },
	},
	EVOKER = {
		-- Blessing of the Bronze
		Icon = 381748,
		Auras = {
			[381748] = true,
			[381732] = true,
			[381758] = true,
			[381741] = true,
			[381746] = true,
			[381749] = true,
			[381750] = true,
			[381751] = true,
			[381752] = true,
			[381753] = true,
			[381754] = true,
			[381756] = true,
			[381757] = true,
		},
	},
	MAGE = {
		-- Arcane Intellect
		Icon = 1459,
		Auras = { [1459] = true },
	},
	PRIEST = {
		-- Power Word: Fortitude
		Icon = 21562,
		Auras = { [21562] = true },
	},
	SHAMAN = {
		-- Skyfury
		Icon = 462854,
		Auras = { [462854] = true },
	},
	WARRIOR = {
		-- Battle Shout
		Icon = 6673,
		Auras = { [6673] = true },
	},
}

-- The aura ids the client still answers about while auras are secret. Anything off this list comes
-- back nil whether the buff is there or not.
local readableIds = {
	[1126] = true, -- Mark of the Wild
	[1459] = true, -- Arcane Intellect
	[6673] = true, -- Battle Shout
	[21562] = true, -- Power Word: Fortitude
	[369459] = true, -- Source of Magic
	-- Blessing of the Bronze, which lands as one id per class.
	[381732] = true,
	[381741] = true,
	[381746] = true,
	[381748] = true,
	[381749] = true,
	[381750] = true,
	[381751] = true,
	[381752] = true,
	[381753] = true,
	[381754] = true,
	[381756] = true,
	[381757] = true,
	[381758] = true,
	[462854] = true, -- Skyfury
	[474754] = true, -- Symbiotic Relationship
}

addon.Core.ClassBuffs = buffs
addon.Core.ReadableAuraIds = readableIds

---@class ClassBuff
---@field Icon number The spell the caster knows it by, which is where the art comes from.
---@field Auras table<number, boolean> Every aura id it can land as, since some vary by target.
