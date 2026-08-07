---@type string, Addon
local _, addon = ...
local auraCategoryIds = addon.Core.AuraCategoryIds

-- 12.1 AuraContainer filter strings, spell-ID candidate filters, and group keys, in one place.
--
-- Filter tokens combine with AND, never OR, so each category needs its own aura group; several
-- groups on one container render as a single continuous row. Overlap between the categories is
-- resolved with `!` negation rather than post-hoc dedup (an aura can be flagged both BIG and
-- EXTERNAL defensive, and importants are frequently defensives too): each aura matches exactly
-- one of the four filters below, in the priority order CC > big > external > important.
--
-- These strings are shared by every module that shows the standard categories, which matters
-- because AddAuraGroup validates the filter string loudly - if a token or a negation turns out
-- not to be supported on a live build, it is fixed here once rather than in four modules.
--
-- WHY EVERY GROUP CARRIES BOTH A FILTER STRING AND A SPELL-ID MAP
-- Neither is sufficient on its own.
--
-- The filter string is mandatory (AddAuraGroup takes one) and is the only filter that applies on
-- every unit, so it stays as the base. On its own it has a live Blizzard bug: for units that are
-- out of range the flag tokens stop being evaluated correctly and the group fills with unrelated
-- buffs. The includeSpellIDs candidate filter is the known workaround - the engine matches the
-- aura's spell ID directly, so the garbage never reaches the group.
--
-- The catch is that spell-ID maps are IDENTITY-GATED. AuraContainerUtil's
-- CanApplyIdentityCandidateFilters (verified against the 12.1 source) rejects a harmful aura when
-- UnitCanAssist("player", unit) and a helpful one when it does not - so the maps apply only to
-- helpful auras on assistable units and harmful auras on non-assistable ones. The one exemption
-- is checked first and wins outright: a spell whose C_Secrets.GetSpellAuraSecrecy is NeverSecret
-- is filterable on any unit (that is how Blizzard drops Exhaustion/Sated from friendly frames).
-- Everywhere else - debuffs on friendlies (party/raid CC) and buffs on enemies - they are
-- SILENTLY SKIPPED: no error, the filter just does nothing and every aura passes. That is why the
-- tokens are kept rather than replaced with a bare HELPFUL/HARMFUL. On the gated paths the token
-- is the only filter left, and dropping it would show every aura on the unit permanently instead
-- of only while it is out of range. Adding the map alongside the token can only ever tighten a
-- group, never loosen it, so this is safe on the gated paths and fixes the bug on the rest.
--
-- The ID lists come from Core/AuraCategoryIds - the same generated in-game scan of the
-- CROWD_CONTROL / IMPORTANT / defensive spell flags that feeds the aura-sound registrations,
-- filtered offline to player PvP abilities. That last part is the one behaviour change: on the
-- paths where the gate DOES apply the maps, category members with no player PvP ability behind
-- them (mob and boss CC, PvE-only important buffs) stop showing.
--
-- Other candidate filters are NOT identity-gated: dispel types and the booleans (isStealable,
-- isBossAura, nameplateShowPersonal, maxDuration, ...). Precognition uses the maxDuration one for
-- exactly this reason. One of them still has a gate of its own: isFromPlayerOrPlayerPet needs the
-- engine to attribute the aura's caster, which it cannot do for a group member outside the
-- player's visible world (another instance or phase) - UnitCanAssist stays true there, and the
-- unevaluable check is skipped the same silent way. The PLAYER filter-string token shares that
-- failure. Displays using either must also gate on UnitIsVisible (see CustomAuras CanFilterUnit).

-- Spell-ID maps per category, keyed to match M.Filter so a caller holding a filter name can look
-- up both. The generated Defensive list is not split into big/external - it does not have to be,
-- because the filter strings still partition those two groups, so an aura is never drawn twice.
local spellIds = {
	CrowdControl = auraCategoryIds.CC,
	BigDefensive = auraCategoryIds.Defensive,
	ExternalDefensive = auraCategoryIds.Defensive,
	Important = auraCategoryIds.Important,
	ImportantOnly = auraCategoryIds.Important,
}

-- Memoised canonical spellings; the addon only ever produces a handful of distinct strings.
local canonicalCache = {}
-- "!", the negation prefix in filter strings.
local NEGATION_BYTE = string.byte("!")

---@class AuraFilters
local M = {}

addon.Core.AuraFilters = M

M.Filter = {
	CrowdControl = "HARMFUL|CROWD_CONTROL",
	BigDefensive = "HELPFUL|BIG_DEFENSIVE",
	ExternalDefensive = "HELPFUL|EXTERNAL_DEFENSIVE|!BIG_DEFENSIVE",
	-- Excludes both defensive categories so a defensive that is also flagged important is only
	-- ever drawn once (on whichever display shows defensives).
	Important = "HELPFUL|IMPORTANT|!BIG_DEFENSIVE|!EXTERNAL_DEFENSIVE",
	-- Unpartitioned importants. TEMPORARY: the only consumer is the Precog module's 12.1 branch,
	-- which is unreachable (Precog's Init early-returns there); delete this and the matching
	-- spellIds/CandidateFilters entries together with the 12.0 path.
	ImportantOnly = "HELPFUL|IMPORTANT",
}

-- Ready-made candidateFilters tables, keyed to match M.Filter, so a group spec can point straight
-- at one instead of allocating a wrapper per display (the nameplate and alert pools build these
-- by the dozen). Shared and read-only: the engine keeps the reference it is handed and nothing
-- here mutates it. Displays needing extra candidate filters (precognition's maxDuration) build
-- their own table instead.
M.CandidateFilters = {
	CrowdControl = { includeSpellIDs = spellIds.CrowdControl },
	BigDefensive = { includeSpellIDs = spellIds.BigDefensive },
	ExternalDefensive = { includeSpellIDs = spellIds.ExternalDefensive },
	Important = { includeSpellIDs = spellIds.Important },
	-- TEMPORARY: see M.Filter.ImportantOnly.
	ImportantOnly = { includeSpellIDs = spellIds.ImportantOnly },
}

-- Group keys. Always reference these rather than writing the string inline: SetMaxIcons is the
-- per-category on/off switch, and a typo there would silently disable a whole category.
M.GroupKey = {
	CrowdControl = "cc",
	BigDefensive = "bigdef",
	ExternalDefensive = "extdef",
	Important = "important",
}

---One canonical spelling per filter, for handing to the engine. The engine batches per-unit
---parse work by the literal text of each filter string and treats reordered spellings as
---different filters, so every distinct spelling of the same filter pays its own full scan of
---the unit's auras. Sorting the tokens collapses equivalent spellings onto one shared pass.
---Tokens sort by their bare name with a negation placed after the token it negates, and
---duplicates drop out. AuraContainerDisplay applies this to every string it hands over, so
---callers never need to.
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

		-- The bare token leads its own negation. Both conditions, so comparing a token with
		-- itself is false - table.sort misorders unrelated tokens on a non-strict comparator.
		return a:byte(1) ~= NEGATION_BYTE and b:byte(1) == NEGATION_BYTE
	end)

	local canonical = table.concat(tokens, "|")
	canonicalCache[filterString] = canonical

	return canonical
end

---One standard-category group spec in the shape AuraContainerDisplay's New takes. Returns a
---fresh table: New keeps the list it is given for the display's lifetime, so specs must never
---be shared between displays.
---@param categoryKey string "CrowdControl"|"BigDefensive"|"ExternalDefensive"|"Important".
---@param maxIcons number? Icon budget for the group (New defaults a nil budget to 3).
---@param extra table? Further AuraDisplayGroupSpec fields (SortDirection, GlowColor, ...) copied
---onto the spec; entries may also override the category defaults.
---@return AuraDisplayGroupSpec
function M:GroupSpec(categoryKey, maxIcons, extra)
	local key = M.GroupKey[categoryKey]

	if not key then
		-- A typo here would build a display with a dead group that the per-category budget
		-- setters then silently miss; fail at the source instead.
		error("GroupSpec: unknown aura category '" .. tostring(categoryKey) .. "'")
	end

	local spec = {
		Key = key,
		FilterString = M.Filter[categoryKey],
		CandidateFilters = M.CandidateFilters[categoryKey],
		MaxIcons = maxIcons,
	}

	if extra then
		for field, value in pairs(extra) do
			spec[field] = value
		end
	end

	return spec
end

---Builds the standard four-category group spec list for a display, in priority order.
---Returns a fresh table: `New` keeps the list for the display's lifetime, so it must not be
---shared between displays.
---@param maxIcons number Initial per-group icon budget (SetMaxIcons re-budgets per category).
---@return AuraDisplayGroupSpec[]
function M:BuildCategoryGroups(maxIcons)
	return {
		self:GroupSpec("CrowdControl", maxIcons),
		self:GroupSpec("BigDefensive", maxIcons),
		self:GroupSpec("ExternalDefensive", maxIcons),
		self:GroupSpec("Important", maxIcons),
	}
end

---Applies the per-category toggles to a four-category display. A budget of 0 hides the group.
---@param display AuraContainerDisplay
---@param maxIcons number Budget for each enabled category.
---@param showCC boolean?
---@param showDefensives boolean? Covers both the big and external defensive groups.
---@param showImportant boolean?
function M:ApplyCategoryBudgets(display, maxIcons, showCC, showDefensives, showImportant)
	display:SetMaxIcons(M.GroupKey.CrowdControl, showCC and maxIcons or 0)
	display:SetMaxIcons(M.GroupKey.BigDefensive, showDefensives and maxIcons or 0)
	display:SetMaxIcons(M.GroupKey.ExternalDefensive, showDefensives and maxIcons or 0)
	display:SetMaxIcons(M.GroupKey.Important, showImportant and maxIcons or 0)
end
