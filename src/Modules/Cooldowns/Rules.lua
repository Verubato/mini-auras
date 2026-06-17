--@type string, Addon
local _, addon = ...

addon.Modules.Cooldowns = addon.Modules.Cooldowns or {}

-- Rules keyed first by spec ID (more precise), then by class token (fallback).
-- Each rule carries flags for which aura type(s) it can match:
--   BigDefensive = true      matches BIG_DEFENSIVE auras from GetDefensiveState()
--   ExternalDefensive = true matches EXTERNAL_DEFENSIVE auras from GetDefensiveState()
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
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 60,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 498,
			}, -- Divine Protection
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
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
				RequiresEvidence = "Shield",
				SelfCastable = false,
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[66] = { -- Protection Paladin
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 8,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 31850,
			}, -- Ardent Defender
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 86659,
				MaxCharges = 2,
			}, -- Guardian of Ancient Kings
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
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
				RequiresEvidence = "Shield",
				SelfCastable = false,
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[70] = { -- Retribution Paladin
			{
				BuffDuration = 8,
				Cooldown = 300,
				BigDefensive = true,
				ExternalDefensive = false,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
			{
				BuffDuration = 10,
				Cooldown = 300,
				ExternalDefensive = true,
				BigDefensive = false,
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
				RequiresEvidence = "Shield",
				SelfCastable = false,
				SpellId = 6940,
			}, -- Blessing of Sacrifice
		},
		[62] = { -- Arcane Mage
			{
				BuffDuration = 10,
				Cooldown = 240,
				BigDefensive = true,
				ExternalDefensive = false,
				CanCancelEarly = true,
				SpellId = 45438,
				RequiresEvidence = { "Debuff", "UnitFlags" },
				ExcludeIfTalent = 414659,
			}, -- Ice Block
		},
		[63] = { -- Fire Mage
			{
				BuffDuration = 10,
				Cooldown = 240,
				BigDefensive = true,
				ExternalDefensive = false,
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
				SpellId = 118038,
			}, -- Die by the Sword
		},
		[72] = { -- Fury Warrior
			{
				BuffDuration = 8,
				AlternativeDurations = { 11 }, -- Invigorating Fury (+3s)
				Cooldown = 108,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 184364,
				RequiresTalent = 184364,
			}, -- Enraged Regeneration
		},
		[73] = { -- Protection Warrior
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 871,
				MaxCharges = 2,
			}, -- Shield Wall
		},
		[250] = { -- Blood Death Knight
			{
				BuffDuration = 10,
				AlternativeDurations = { 12, 14 }, -- Goreringers Anguish rank 1 (+2s) / rank 2 (+4s)
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 55233,
			}, -- Vampiric Blood
		},
		[256] = { -- Discipline Priest: Pain Suppression
			{
				BuffDuration = 8,
				Cooldown = 180,
				ExternalDefensive = true,
				BigDefensive = false,
				SpellId = 33206,
				MaxCharges = 2,
			},
		},
		[257] = { -- Holy Priest
			{
				BuffDuration = 10,
				Cooldown = 180,
				ExternalDefensive = true,
				BigDefensive = false,
				CanCancelEarly = true,
				SpellId = 47788,
				ExcludeIfTalent = 440738,
			}, -- Guardian Spirit
			{
				BuffDuration = 12,
				Cooldown = 180,
				ExternalDefensive = true,
				BigDefensive = false,
				CanCancelEarly = true,
				SpellId = 47788,
				RequiresTalent = 440738,
			}, -- Guardian Spirit (Foreseen Circumstances)
		},
		[258] = { -- Shadow Priest
			{
				BuffDuration = 6,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				CrowdControl = true,
				CanCancelEarly = true,
				SpellId = 47585,
			}, -- Dispersion
			{
				BuffDuration = 8,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				CrowdControl = true,
				CanCancelEarly = true,
				SpellId = 47585,
				RequiresTalent = 453729,
			}, -- Dispersion + Heightened Alteration (+2s)
		},
		[104] = {
			{
				BuffDuration = 8,
				AlternativeDurations = { 12, 14 }, -- Improved Barkskin (+4s); 14s = Improved Barkskin + Ursoc's Endurance (+2s)
				Cooldown = 34,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 22812,
			}, -- Guardian Druid: Barkskin (34s cooldown vs the 60s class-wide rule for other specs)
		},
		[105] = {
			{
				BuffDuration = 12,
				Cooldown = 90,
				ExternalDefensive = true,
				BigDefensive = false,
				SpellId = 102342,
			},
		}, -- Restoration Druid: Ironbark
		[268] = { -- Brewmaster Monk
			{
				BuffDuration = 15,
				Cooldown = 360,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 115203,
			}, -- Fortifying Brew
		},
		[270] = { -- Mistweaver Monk
			{
				BuffDuration = 12,
				Cooldown = 120,
				ExternalDefensive = true,
				BigDefensive = false,
				CanCancelEarly = true,
				RequiresEvidence = "Shield",
				SpellId = 116849,
			}, -- Life Cocoon
		},
		[269] = { -- Windwalker Monk
			{
				BuffDuration = 10,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
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
				MinDuration = true,
				SpellId = 204021,
			}, -- Fiery Brand
		},
		[1468] = {
			{
				BuffDuration = 8,
				Cooldown = 60,
				ExternalDefensive = true,
				BigDefensive = false,
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
				MinDuration = true,
				SpellId = 363916,
				MaxCharges = 2,
			},
		}, -- Augmentation Evoker: Obsidian Scales
		[264] = { -- Restoration Shaman
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
				ExternalDefensive = false,
				RequiresEvidence = "UnitFlags",
				CanCancelEarly = true,
				SpellId = 642,
			}, -- Divine Shield
		},
		MAGE = {
			{
				BuffDuration = 10,
				Cooldown = 50,
				BigDefensive = true,
				ExternalDefensive = false,
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
				SpellId = 109304,
				RequiresTalent = 430709,
				ExcludeFromPrediction = true,
			}, -- Exhilaration (Dark Ranger: applies 3s SotF)
			{
				BuffDuration = 10,
				Cooldown = 120,
				BigDefensive = false,
				ExternalDefensive = true,
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
				SpellId = 22812,
			}, -- Barkskin
		},
		ROGUE = {
			{
				BuffDuration = 5,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 31224,
			}, -- Cloak of Shadows
		},
		DEATHKNIGHT = {
			{
				BuffDuration = 5,
				Cooldown = 60,
				BigDefensive = true,
				ExternalDefensive = false,
				CanCancelEarly = true,
				SpellId = 48707,
				RequiresEvidence = "Shield",
			}, -- Anti-Magic Shell (BigDefensive, without Spellwarding)
			{
				BuffDuration = 7,
				Cooldown = 60,
				BigDefensive = true,
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
				SpellId = 48792,
			}, -- Icebound Fortitude
		},
		DEMONHUNTER = {},
		WARRIOR = {},
		MONK = {
			{
				BuffDuration = 15,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 115203,
			}, -- Fortifying Brew
		},
		SHAMAN = {
			{
				BuffDuration = 12,
				Cooldown = 120,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 108271,
			}, -- Astral Shift
		},
		WARLOCK = {
			{
				BuffDuration = 8,
				Cooldown = 180,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 104773,
			}, -- Unending Resolve
		},
		PRIEST = {
			{
				BuffDuration = 10,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				SpellId = 19236,
			}, -- Desperate Prayer
		},
		EVOKER = {
			{
				BuffDuration = 12,
				Cooldown = 90,
				BigDefensive = true,
				ExternalDefensive = false,
				MinDuration = true,
				SpellId = 363916,
				MaxCharges = 2,
			}, -- Obsidian Scales
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

---Returns the type of a spell.  Every tracked cooldown is now a defensive
---(BigDefensive or ExternalDefensive), so this always returns "Defensive".
---Retained so callers that branch on spell type keep working without change.
---@param spellId number
---@return "Defensive"
function rules.GetSpellType(spellId)
	return "Defensive"
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
