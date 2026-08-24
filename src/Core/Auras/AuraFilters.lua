---@type string, Addon
local _, addon = ...
local auraCategoryIds = addon.Core.AuraCategoryIds

-- 12.1 AuraContainer filter strings, spell-ID candidate filters, and group keys, in one place, so a
-- token a live build turns out not to support is fixed once rather than in four modules.

-- Spell-ID maps per category, keyed to match M.Filter so a caller holding a filter name can look
-- up both. The generated Defensive list is not split into big/external, because the filter strings
-- still partition those two groups, so an aura is never drawn twice.
--
-- Every group carries a filter string and a map, because neither is enough on its own. The filter
-- string is mandatory and is the only filter that applies on every unit, but for a unit that is out
-- of range the flag tokens stop being evaluated correctly and the group fills with unrelated buffs.
-- The includeSpellIDs candidate filter is the known workaround, since the engine matches the aura's
-- spell ID directly.
--
-- Spell-ID maps are identity-gated. AuraContainerUtil's CanApplyIdentityCandidateFilters rejects a
-- harmful aura when UnitCanAssist("player", unit) and a helpful one when it does not, so the maps
-- apply only to helpful auras on assistable units and harmful auras on non-assistable ones. A spell
-- whose C_Secrets.GetSpellAuraSecrecy is NeverSecret is exempt and filterable on any unit, and that
-- check is made first and wins outright.
--
-- Everywhere else, debuffs on friendlies and buffs on enemies, the map is skipped with no error and
-- every aura passes. The token stays alongside it because on those paths the token is the only
-- filter left. A map can only ever tighten a group, never loosen it.
--
-- The ID lists come from Core/AuraCategoryIds, the same generated in-game scan of the
-- CROWD_CONTROL / IMPORTANT / defensive spell flags that feeds the aura-sound registrations,
-- filtered offline to player PvP abilities. Where the gate does apply the maps, category members
-- with no player PvP ability behind them stop showing.
--
-- A curated subset also hides flagged CC no list has heard of, so a new spec's stun goes missing
-- until someone re-runs the scan. Nameplates and portraits take that over the workaround through
-- GroupSpec's dropSpellIds, because a plate only exists for a unit the client is drawing and a
-- portrait shows your own unit or one you picked. A far-away focus is the gap that leaves. Raid
-- frames, the healer CC display and the alert sounds keep the maps, since a group member or a BG
-- healer is out of range constantly. Disarm keeps its map everywhere. See M.Filter.Disarm.
local spellIds = {
	CrowdControl = auraCategoryIds.CC,
	BigDefensive = auraCategoryIds.Defensive,
	ExternalDefensive = auraCategoryIds.Defensive,
	Important = auraCategoryIds.Important,
	-- Hand-curated, because the game flags disarms as nothing at all. No scan can find them and no
	-- filter token can select them, so this map is the disarm group's only real filter.
	-- That makes the category enemy-only. See M.Filter.Disarm.
	Disarm = {
		[207777] = true, -- Dismantle (Rogue)
		[236077] = true, -- Disarm (Warrior)
		[233759] = true, -- Grapple Weapon (Monk)
		[407028] = true, -- Sticky Tar Bomb (Hunter)
		[209749] = true, -- Faerie Swarm (Druid)
	},
}

-- Memoised canonical spellings. The addon only ever produces a handful of distinct strings.
local canonicalCache = {}
-- The standard categories in render order, with disarm beside the CC icons it belongs with.
local CATEGORY_ORDER = { "CrowdControl", "Disarm", "BigDefensive", "ExternalDefensive", "Important" }
-- Refilled per CategorySet call. BuildCategoryGroups only ever reads it.
local categorySetScratch = {}
local NEGATION_BYTE = string.byte("!")

---@class AuraFilters
local M = {}

addon.Core.AuraFilters = M

-- Filter tokens combine with AND, never OR, so each category needs its own aura group. Several
-- groups on one container render as a single continuous row.
--
-- Overlap between the categories is closed with `!` negation, so each aura matches exactly one of
-- these filters, in the priority order CC > disarm > big > external > important. Disarm's own
-- overlap with bare HARMFUL is closed by its spell-ID map instead of the string.
M.Filter = {
	CrowdControl = "HARMFUL|CROWD_CONTROL",
	-- Disarms carry no category flag, so the spell-ID map is the only filter that narrows this
	-- group and the string is just "any non-CC debuff".
	-- On an assistable unit the identity gate skips the map and the group would show every debuff
	-- the unit has, so callers have to budget it to zero there, keyed off units:CanAssist.
	-- The negation keeps a disarm out of this group if the game ever starts flagging them as CC.
	Disarm = "HARMFUL|!CROWD_CONTROL",
	BigDefensive = "HELPFUL|BIG_DEFENSIVE",
	ExternalDefensive = "HELPFUL|EXTERNAL_DEFENSIVE|!BIG_DEFENSIVE",
	-- Excludes both defensive categories so a defensive that is also flagged important is only
	-- ever drawn once, on whichever display shows defensives.
	Important = "HELPFUL|IMPORTANT|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE",
}

-- A display filtering on isFromPlayerOrPlayerPet or the PLAYER filter-string token must also gate
-- on UnitIsVisible. The engine cannot attribute the aura's caster for a group member outside the
-- player's visible world, UnitCanAssist stays true there, and the unevaluable check is skipped the
-- same silent way. See PersonalAuras CanFilterUnit.
--
-- Other candidate filters are not identity-gated: dispel types and the booleans (isStealable,
-- isBossAura, nameplateShowPersonal, maxDuration, ...), which is why a display that must work on a
-- non-assistable unit reaches for one.

-- Ready-made candidateFilters tables, keyed to match M.Filter, so a group spec can point straight
-- at one rather than allocating a wrapper per display. The nameplate and alert pools build these by
-- the dozen. They are read-only, because the engine keeps the reference it is handed. A display
-- needing extra candidate filters builds its own table.
M.CandidateFilters = {
	CrowdControl = { includeSpellIDs = spellIds.CrowdControl },
	BigDefensive = { includeSpellIDs = spellIds.BigDefensive },
	ExternalDefensive = { includeSpellIDs = spellIds.ExternalDefensive },
	Important = { includeSpellIDs = spellIds.Important },
	Disarm = { includeSpellIDs = spellIds.Disarm },
}

-- Group keys. Always reference these rather than writing the string inline, because SetMaxIcons is
-- the per-category on/off switch and a typo there would silently disable a whole category.
M.GroupKey = {
	CrowdControl = "cc",
	Disarm = "disarm",
	BigDefensive = "bigdef",
	ExternalDefensive = "extdef",
	Important = "important",
}

---One canonical spelling per filter, for handing to the engine. The engine batches per-unit parse
---work by the literal text of each filter string, so every distinct spelling of the same filter
---pays its own full scan of the unit's auras.
---Tokens sort by their bare name with a negation placed after the token it negates, and duplicates
---drop out. AuraContainerDisplay applies this to every string it hands over.
---@param filterString string
---@return string
function M:Canonical(filterString)
	if type(filterString) ~= "string" then
		return filterString
	end

	local cached = canonicalCache[filterString]

	if cached then
		return cached
	end

	local tokens, seen = {}, {}

	for token in filterString:gmatch("[^|%s]+") do
		if not seen[token] then
			seen[token] = true
			tokens[#tokens + 1] = token
		end
	end

	table.sort(tokens, function(a, b)
		local aBare = a:gsub("^!", "")
		local bBare = b:gsub("^!", "")

		if aBare ~= bBare then
			return aBare < bBare
		end

		-- The bare token leads its own negation. Both conditions are needed so that comparing a
		-- token with itself is false, since table.sort misorders unrelated tokens on a non-strict
		-- comparator.
		return a:byte(1) ~= NEGATION_BYTE and b:byte(1) == NEGATION_BYTE
	end)

	local canonical = table.concat(tokens, "|")
	canonicalCache[filterString] = canonical

	return canonical
end

---One standard-category group spec in the shape AuraContainerDisplay's New takes. Returns a fresh
---table. New keeps the list it is given for the display's lifetime, so specs must never be shared
---between displays.
---@param categoryKey string "CrowdControl"|"Disarm"|"BigDefensive"|"ExternalDefensive"|"Important".
---@param maxIcons number? Icon budget for the group (New defaults a nil budget to 3).
---@param extra table? Further AuraDisplayGroupSpec fields (SortDirection, GlowColor, ...) copied
---onto the spec. Entries may also override the category defaults.
---@param dropSpellIds boolean? Leave the category's spell-ID map off, so the group shows
---everything the filter string selects rather than the curated subset. Only for displays whose
---units cannot be out of range. Ignored for disarm, whose map is the only filter narrowing that
---group.
---@return AuraDisplayGroupSpec
function M:GroupSpec(categoryKey, maxIcons, extra, dropSpellIds)
	local key = M.GroupKey[categoryKey]

	if not key then
		-- A typo here would build a display with a dead group that the per-category budget
		-- setters then silently miss.
		error("GroupSpec: unknown aura category '" .. tostring(categoryKey) .. "'")
	end

	local spec = {
		Key = key,
		FilterString = M.Filter[categoryKey],
		CandidateFilters = M.CandidateFilters[categoryKey],
		MaxIcons = maxIcons,
	}

	-- Disarm is exempt, because with no category flag behind it the map is all that narrows it.
	if dropSpellIds and categoryKey ~= "Disarm" then
		spec.CandidateFilters = nil
	end

	if extra then
		for field, value in pairs(extra) do
			spec[field] = value
		end
	end

	return spec
end

---Builds the standard category group spec list for a display, in priority order, with disarm
---directly after the CC icons it belongs with.
---Returns a fresh table. `New` keeps the list for the display's lifetime, so it must not be shared
---between displays.
---@param maxIcons number Initial per-group icon budget (SetMaxIcons re-budgets per category).
---@param dropSpellIds boolean? Passed to every GroupSpec. See there.
---@param colors table<string, number[]>? Category tints keyed by M.GroupKey value. A display built
---inside an arena can never be restyled, so the tint it is born with is the one it keeps for the
---match.
---@param categories table<string, boolean>? Which categories to build, from CategorySet. Omitted
---builds all five, which costs a batch of buttons per category the display may never show.
---@return AuraDisplayGroupSpec[]
function M:BuildCategoryGroups(maxIcons, dropSpellIds, colors, categories)
	local groups = {}

	for _, categoryKey in ipairs(CATEGORY_ORDER) do
		if not categories or categories[categoryKey] then
			groups[#groups + 1] = self:GroupSpec(categoryKey, maxIcons, nil, dropSpellIds)
		end
	end

	if colors then
		for _, spec in ipairs(groups) do
			spec.GlowColor = colors[spec.Key]
		end
	end

	return groups
end

---Which categories a display built from these toggles can ever show, in the shape
---BuildCategoryGroups takes. The engine allocates a batch of buttons per group and a group cannot
---be added later, so a category left out here is one the display can never show without being
---rebuilt. The toggles therefore belong in the owner's look signature.
---@param showCC boolean?
---@param showDefensives boolean?
---@param showImportant boolean?
---@param showDisarm boolean?
---@return table<string, boolean> Shared and rewritten per call, and BuildCategoryGroups only reads
---it.
function M:CategorySet(showCC, showDefensives, showImportant, showDisarm)
	categorySetScratch.CrowdControl = showCC == true
	categorySetScratch.Disarm = showDisarm == true
	categorySetScratch.BigDefensive = showDefensives == true
	categorySetScratch.ExternalDefensive = showDefensives == true
	categorySetScratch.Important = showImportant == true

	return categorySetScratch
end

---A stamp of the same toggles, for a look signature. A display built without a category has to be
---rebuilt when that category comes on, not re-budgeted.
---@return number
function M:CategoryGeneration(showCC, showDefensives, showImportant, showDisarm)
	-- Compared the same way CategorySet reads them, so a toggle that is truthy without being true
	-- cannot stamp a category the display was not built with.
	return (showCC == true and 1 or 0)
		+ (showDefensives == true and 2 or 0)
		+ (showImportant == true and 4 or 0)
		+ (showDisarm == true and 8 or 0)
end

---Budgets one category, if this display was built with it. A display carries only the categories
---its owner's toggles could show, so a group being absent is ordinary rather than a mistake.
---@param display AuraContainerDisplay
---@param groupKey string
---@param maxIcons number
local function SetCategoryBudget(display, groupKey, maxIcons)
	if display:HasGroup(groupKey) then
		display:SetMaxIcons(groupKey, maxIcons)
	end
end

---Applies the per-category toggles to a standard-category display. A budget of 0 hides the group.
---@param display AuraContainerDisplay
---@param maxIcons number Budget for each enabled category.
---@param showCC boolean?
---@param showDefensives boolean? Covers both the big and external defensive groups.
---@param showImportant boolean?
---@param showDisarm boolean? Must be false while the tracked unit is assistable. The disarm
---group's only real filter is its spell-ID map, which the identity gate skips there.
function M:ApplyCategoryBudgets(display, maxIcons, showCC, showDefensives, showImportant, showDisarm)
	SetCategoryBudget(display, M.GroupKey.CrowdControl, showCC and maxIcons or 0)
	SetCategoryBudget(display, M.GroupKey.Disarm, showDisarm and maxIcons or 0)
	SetCategoryBudget(display, M.GroupKey.BigDefensive, showDefensives and maxIcons or 0)
	SetCategoryBudget(display, M.GroupKey.ExternalDefensive, showDefensives and maxIcons or 0)
	SetCategoryBudget(display, M.GroupKey.Important, showImportant and maxIcons or 0)
end
