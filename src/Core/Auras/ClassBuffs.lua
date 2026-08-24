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
}

addon.Core.ClassBuffs = buffs

---@class ClassBuff
---@field Icon number The spell the caster knows it by, which is where the art comes from.
---@field Auras table<number, boolean> Every aura id it can land as, since some vary by target.
