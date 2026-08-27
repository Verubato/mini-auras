---@type string, Addon
local _, addon = ...

-- The heal-over-time and shield auras worth watching on a party or raid frame, by spell id and
-- grouped by the class that casts them, which is also how the options list reads them back.
--
-- An allowlist, because a talent granting a second copy of a heal-over-time gives that copy its own
-- spell id, and the copy does not always carry the flags its original has.
--
-- The engine honours this candidate filter only for helpful auras on a unit you can assist, so it
-- really filters on party and raid frames and would silently do nothing anywhere else.
local groups = {
	{
		Class = "DRUID",
		Ids = {
			774, -- Rejuvenation
			155777, -- Rejuvenation (Germination)
			33763, -- Lifebloom
			290754, -- Lifebloom (Full Bloom)
			8936, -- Regrowth
			48438, -- Wild Growth
			439530, -- Symbiotic Blooms
		},
	},
	{
		Class = "EVOKER",
		Ids = {
			364343, -- Echo
			366155, -- Reversion
			367364, -- Reversion (Echo copy)
			355941, -- Dream Breath
			373267, -- Lifebind
			360827, -- Blistering Scales
		},
	},
	{
		Class = "MONK",
		Ids = {
			119611, -- Renewing Mist
			124682, -- Enveloping Mist
			411036, -- Sphere of Hope
			116841, -- Tiger's Lust
		},
	},
	{
		Class = "PALADIN",
		Ids = {
			53563, -- Beacon of Light
			156910, -- Beacon of Faith
			1244893, -- Beacon of the Savior
			432496, -- Holy Bulwark
			432607, -- Holy Bulwark
			432502, -- Sacred Weapon
		},
	},
	{
		Class = "PRIEST",
		Ids = {
			139, -- Renew
			41635, -- Prayer of Mending
			194384, -- Atonement
			17, -- Power Word: Shield
			1253593, -- Void Shield
		},
	},
	{
		Class = "SHAMAN",
		Ids = {
			974, -- Earth Shield
			383648, -- Earth Shield
			61295, -- Riptide
		},
	},
}

-- The spells worth lighting up as their refresh window opens. Lifebloom alone, because its window
-- is the only one that is a real skill check.
--
-- It cannot be a per-spell setting. The reveal is registered on a button when the engine builds it,
-- so every spell that carries one needs its own aura group, and a set that moves per player would
-- move the group count with it.
local pandemic = {
	[33763] = true, -- Lifebloom
}

-- What a row calls a spell, where its own name does not read well in a list. A talent granting a
-- second copy of a heal-over-time names it after the original, so the row says "Rejuvenation"
-- twice and neither says which one this is.
--
-- These are written out, so they stay English on a client that is not.
local names = {
	[155777] = "Germination",
	[290754] = "Full Bloom",
}

-- Flat lookup off the same data, so nothing has to walk the groups to answer "does this ship
-- tracked" and the two can never disagree.
local byId = {}

for _, group in ipairs(groups) do
	for _, spellId in ipairs(group.Ids) do
		byId[spellId] = true
	end
end

addon.Core.TrackedBuffs = {
	Groups = groups,
	ById = byId,
	Names = names,
	Pandemic = pandemic,
}

---@class TrackedBuffs
---@field Groups { Class: string, Ids: number[] }[]
---@field ById table<number, boolean>
---@field Names table<number, string>
---@field Pandemic table<number, boolean>
