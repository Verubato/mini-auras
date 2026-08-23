---@type string, Addon
local _, addon = ...

-- The heal-over-time and shield auras worth watching on a party or raid frame, by spell id and
-- grouped by the class that casts them, which is also how the options list reads them back.
--
-- An allowlist rather than a set of category filters. The game's own categories both miss auras
-- that matter and sweep in ones that do not: a talent granting a second copy of a heal-over-time
-- gives it its own spell id, and that copy does not always carry the flags its original has.
--
-- The list goes to the engine as a candidate filter, which it only honours for helpful auras on a
-- unit you can assist. Party and raid frames are exactly that, so it is a real filter here and
-- would silently do nothing anywhere else.
--
-- Ids for specs nobody plays cost nothing: one that never matches never draws.
local groups = {
	{
		Class = "DRUID",
		Ids = {
			774, -- Rejuvenation
			155777, -- Rejuvenation (Germination)
			33763, -- Lifebloom
			8936, -- Regrowth
			48438, -- Wild Growth
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
			448430, -- Renewing Mist
			227345, -- Enveloping Mist
		},
	},
	{
		Class = "PALADIN",
		Ids = {
			53563, -- Beacon of Light
			156910, -- Beacon of Faith
			1244893, -- Beacon of the Savior
		},
	},
	{
		Class = "PRIEST",
		Ids = {
			139, -- Renew
			41635, -- Prayer of Mending
			194384, -- Atonement
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

-- The spells worth lighting up as their refresh window opens. Lifebloom alone, because its
-- window is the one that is a real skill check: the rest are cheap to reapply, and a glow on all
-- of them is a corner full of glow rather than a cue.
--
-- Not a per-spell setting: the reveal is registered on a button when the engine builds it, so
-- every spell that carries one needs its own aura group, and a set that moves per player would
-- mean a group count that moves with it.
local pandemic = {
	[33763] = true, -- Lifebloom
}

-- What a row calls a spell, where its own name does not read well in a list. A talent that
-- grants a second copy of a heal-over-time names it after the original, so the whole row says
-- "Rejuvenation" twice over and none of it says which one this is.
--
-- Written out rather than taken from the client, so these read the same whatever the client's
-- language is - which also means they stay English on a client that is not.
local names = {
	[155777] = "Germination",
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
