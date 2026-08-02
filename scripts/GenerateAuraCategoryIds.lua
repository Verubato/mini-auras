-- Generates the curated player-PvP spell lists for src/Core/AuraCategoryIds.lua from a
-- MiniCCSpellScan saved variable (produced in game by scripts/ScanSpellFlags.lua - see its
-- header for the full pipeline).
--
-- Usage (Lua 5.1, from the repo root):
--   lua scripts/GenerateAuraCategoryIds.lua <path-to-SavedVariables-MiniCC.lua> report
--     - shows match counts, curated names with no matches, and unmatched candidates to review
--   lua scripts/GenerateAuraCategoryIds.lua <path-to-SavedVariables-MiniCC.lua> generate
--     - prints the table body; paste it into src/Core/AuraCategoryIds.lua between the braces
--
-- Matching is by exact spell name WITHIN the flagged sets, so every spell-ID variant of a
-- named ability is captured, and generic names ("Fear", "Silence") are safe - everything in
-- the source data is already CC/Important-flagged by the game.
--
-- The names below must be the name of the AURA THAT LANDS, not the button that casts it or the
-- talent that modifies it. Those often differ, and a wrong name fails silently: the report only
-- lists names matching NOTHING, so a wrong name that happens to collide with unrelated spells
-- looks covered. That is exactly how the Shaman stun went missing for a whole expansion - the
-- list said "Static Charge" (the PvP talent) and dutifully matched six unrelated spells of that
-- name, while the real debuff, "Capacitor Totem" (118905), was never picked up.
local scanPath = arg[1]
local mode = arg[2] or "report"
dofile(scanPath)
assert(MiniCCSpellScan, "MiniCCSpellScan not found")

-- Player PvP crowd control ability names (DR-category families + racials + pet abilities).
local ccNames = {
	-- Stuns
	["Kidney Shot"] = true, ["Cheap Shot"] = true, ["Between the Eyes"] = true,
	["Hammer of Justice"] = true, ["Storm Bolt"] = true, ["Shockwave"] = true,
	["Bash"] = true, ["Mighty Bash"] = true, ["Maim"] = true, ["Rake"] = true,
	["Asphyxiate"] = true, ["Leg Sweep"] = true, ["Static Charge"] = true,
	["Intimidation"] = true, ["Binding Shot"] = true, ["Chaos Nova"] = true,
	["Fel Eruption"] = true, ["Shadowfury"] = true, ["Axe Toss"] = true,
	["War Stomp"] = true, ["Bull Rush"] = true, ["Quaking Palm"] = true,
	["Charge"] = true, ["Intercept"] = true, ["Deep Freeze"] = true,
	["Lightning Lasso"] = true, ["Capacitor Totem"] = true,
	-- Incapacitates
	["Polymorph"] = true, ["Hex"] = true, ["Freezing Trap"] = true, ["Repentance"] = true,
	["Sap"] = true, ["Gouge"] = true, ["Ring of Frost"] = true, ["Shackle Undead"] = true,
	["Hibernate"] = true, ["Incapacitating Roar"] = true, ["Song of Chi-Ji"] = true,
	["Paralysis"] = true, ["Imprison"] = true, ["Wyvern Sting"] = true, ["Blind"] = true,
	["Dragon's Breath"] = true, ["Scatter Shot"] = true, ["Sleep Walk"] = true,
	["Mind Control"] = true, ["Dominate Mind"] = true, ["Seduction"] = true,
	["Holy Word: Chastise"] = true, ["Banish"] = true, ["Polymorph: Sheep"] = true,
	["Polymorph: Chicken"] = true,
	-- Fears / disorients
	["Fear"] = true, ["Psychic Scream"] = true, ["Intimidating Shout"] = true,
	["Howl of Terror"] = true, ["Mortal Coil"] = true, ["Turn Evil"] = true,
	["Blinding Light"] = true, ["Sigil of Misery"] = true, ["Cyclone"] = true,
	-- Roots
	["Entangling Roots"] = true, ["Mass Entanglement"] = true, ["Frost Nova"] = true,
	["Ice Nova"] = true, ["Freeze"] = true, ["Earthgrab"] = true, ["Glacial Spike"] = true,
	["Landslide"] = true, ["Void Tendrils"] = true, ["Frost Bomb"] = true,
	-- Silences / horrors
	["Silence"] = true, ["Silencing Shot"] = true, ["Spell Lock"] = true,
	["Solar Beam"] = true, ["Garrote - Silence"] = true, ["Strangulate"] = true,
	["Sigil of Silence"] = true, ["Arcane Torrent"] = true, ["Optical Blast"] = true,
	["Psychic Horror"] = true,
	-- Misc loss-of-control
	["Time Stop"] = true, ["Chains of Ice"] = true,
}

-- Player important ability names (specials + offensive cooldowns). Matched against the
-- Important-flagged set; emitted as AuraCategoryIds.Important (the "important spell" sound).
local importantNames = {
	-- Specials
	["Precognition"] = true, ["Nullifying Shroud"] = true, ["Grounding Totem"] = true,
	["War Banner"] = true, ["Time Stop"] = true,
	-- Offensive cooldowns
	["Avenging Wrath"] = true, ["Avenging Crusader"] = true, ["Combustion"] = true,
	["Icy Veins"] = true, ["Ice Form"] = true, ["Arcane Surge"] = true,
	["Metamorphosis"] = true, ["Recklessness"] = true, ["Avatar"] = true,
	["Voidform"] = true, ["Dark Ascension"] = true, ["Celestial Alignment"] = true,
	["Incarnation: Chosen of Elune"] = true, ["Incarnation: Avatar of Ashamane"] = true,
	["Incarnation: Guardian of Ursoc"] = true, ["Incarnation: Tree of Life"] = true,
	["Berserk"] = true, ["Ascendance"] = true, ["Feral Spirit"] = true,
	["Fire Elemental"] = true, ["Storm Elemental"] = true, ["Doom Winds"] = true,
	["Adrenaline Rush"] = true, ["Shadow Blades"] = true, ["Shadow Dance"] = true,
	["Deathmark"] = true, ["Vendetta"] = true, ["Trueshot"] = true,
	["Call of the Wild"] = true, ["Coordinated Assault"] = true, ["Bestial Wrath"] = true,
	["Summon Demonic Tyrant"] = true, ["Summon Darkglare"] = true, ["Summon Infernal"] = true,
	["Dragonrage"] = true, ["Dancing Rune Weapon"] = true, ["Pillar of Frost"] = true,
	["Apocalypse"] = true, ["Storm, Earth, and Fire"] = true, ["Serenity"] = true,
	["Zenith"] = true,
	["Invoke Niuzao, the Black Ox"] = true, ["Invoke Chi-Ji, the Red Crane"] = true,
	["Invoke Xuen, the White Tiger"] = true, ["Invoke Yu'lon, the Jade Serpent"] = true,
	["Thunder Blast"] = true, ["Takedown"] = true, ["Peaceweaver"] = true, ["Spell Reflection"] = true,
	["Blessing of Freedom"] = true, ["Divine Protection"] = true, ["Revival"] = true,
	-- Only the Spellwarding-talented id; see idCategory below.
	["Anti-Magic Shell"] = true,
}

-- Player defensive ability names (defensives + healer throughput cooldowns). Matched against
-- the Important-flagged set; emitted as AuraCategoryIds.Defensive (the "defensive spell" sound).
local defensiveNames = {
	-- Defensive cooldowns
	["Ice Block"] = true, ["Ice Cold"] = true, ["Divine Shield"] = true,
	["Aspect of the Turtle"] = true, ["Cloak of Shadows"] = true, ["Evasion"] = true,
	["Die by the Sword"] = true, ["Shield Wall"] = true,
	["Enraged Regeneration"] = true, ["Barkskin"] = true, ["Ironbark"] = true,
	["Survival of the Fittest"] = true, ["Blur"] = true, ["Darkness"] = true,
	["Netherwalk"] = true, ["Fiery Brand"] = true, ["Astral Shift"] = true,
	["Blessing of Protection"] = true, ["Blessing of Spellwarding"] = true,
	["Blessing of Sacrifice"] = true,
	["Ardent Defender"] = true, ["Pain Suppression"] = true,
	["Life Cocoon"] = true, ["Guardian Spirit"] = true, ["Desperate Prayer"] = true, ["Fortifying Brew"] = true,
	["Anti-Magic Shell"] = true, ["Icebound Fortitude"] = true, ["Lichborne"] = true,
	["Vampiric Blood"] = true, ["Unending Resolve"] = true, ["Nether Ward"] = true,
	["Obsidian Scales"] = true, ["Exhilaration"] = true, ["Alter Time"] = true,
	["Mirror Image"] = true, ["Sentinel"] = true, ["Dispersion"] = true,
	["Intervene"] = true, ["Nimble Brew"] = true, ["Roar of Sacrifice"] = true,
	["Touch of Karma"] = true,
	-- Healer throughput cooldowns
	["Restoral"] = true, ["Healing Tide Totem"] = true,
	["Divine Hymn"] = true, ["Tranquility"] = true,
}

-- Abilities that change category with a talent do it by changing SPELL ID, not name, so name
-- matching alone puts every variant in both lists. Pin the individual ids here instead: an id
-- listed below is emitted only for the category named, and the ability's name goes in BOTH name
-- sets above so each variant is a candidate for the right one.
local idCategory = {
	-- Anti-Magic Shell: important when talented into Spellwarding, a plain defensive otherwise.
	[410358] = "Important",
	[48707] = "Defensive",
}

---@param category string Which output list is being built, matched against idCategory.
local function filter(source, names, category)
	local matched, byName = {}, {}
	for id, name in pairs(source) do
		local pinned = idCategory[id]
		if type(name) == "string" and names[name] and (pinned == nil or pinned == category) then
			matched[#matched + 1] = { id = id, name = name }
			byName[name] = (byName[name] or 0) + 1
		end
	end
	table.sort(matched, function(a, b)
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.id < b.id
	end)
	return matched, byName
end

local ccMatched, ccByName = filter(MiniCCSpellScan.CC, ccNames, "CC")
local impMatched, impByName = filter(MiniCCSpellScan.Important, importantNames, "Important")
local defMatched, defByName = filter(MiniCCSpellScan.Important, defensiveNames, "Defensive")

if mode == "report" then
	print(("CC matched: %d ids"):format(#ccMatched))
	print(("Important matched: %d ids"):format(#impMatched))
	print(("Defensive matched: %d ids"):format(#defMatched))

	print("\nCC names with no matches:")
	for name in pairs(ccNames) do
		if not ccByName[name] then
			print("  " .. name)
		end
	end
	print("\nImportant names with no matches:")
	for name in pairs(importantNames) do
		if not impByName[name] then
			print("  " .. name)
		end
	end
	print("\nDefensive names with no matches:")
	for name in pairs(defensiveNames) do
		if not defByName[name] then
			print("  " .. name)
		end
	end

	-- Player-relevant important names present in the scan that we did NOT match, to spot
	-- anything missing from the curated lists. Keep the cutoff at or above ScanSpellFlags'
	-- MAX_ID - a lower cutoff hid the Midnight-era spell IDs (>1.2M, e.g. Zenith) entirely.
	print("\nUnmatched Important names (candidates to add):")
	local seen = {}
	for id, name in pairs(MiniCCSpellScan.Important) do
		if type(name) == "string" and id < 1400000 and not importantNames[name] and not defensiveNames[name] and not seen[name] then
			seen[name] = true
			print(("  [%d] %s"):format(id, name))
		end
	end
elseif mode == "generate" then
	local out = {}
	local function emit(label, comment, list)
		out[#out + 1] = ("\t-- %s (%d ids)"):format(comment, #list)
		out[#out + 1] = ("\t%s = {"):format(label)
		for _, e in ipairs(list) do
			out[#out + 1] = ("\t\t[%d] = true, -- %s"):format(e.id, e.name)
		end
		out[#out + 1] = "\t},"
	end
	emit("CC", "CC", ccMatched)
	emit("Important", "Important: specials + offensive cooldowns", impMatched)
	emit("Defensive", "Defensive: defensive + healer throughput cooldowns", defMatched)
	print(table.concat(out, "\n"))
end
