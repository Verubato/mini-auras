---@type string, Addon
local _, addon = ...

-- 12.1 AuraContainer filter strings and group keys, in one place.
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
-- WHY THESE ARE FILTER STRINGS AND NOT SPELL-ID LISTS
-- The obvious way to track "the CC spells we care about" would be a candidateFilters
-- includeSpellIDs map, and it is a trap: the engine only APPLIES spell-ID include/exclude maps
-- when the aura is helpful on an assistable unit or harmful on a non-assistable one. Everywhere
-- else they are SILENTLY SKIPPED - no error, the filter just does nothing and every aura passes.
-- For this addon that kills the main case outright: debuffs on friendlies (party/raid CC), which
-- is exactly what CrowdControl/FriendlyIndicator/HealerCC track. Blizzard's CROWD_CONTROL /
-- BIG_DEFENSIVE / EXTERNAL_DEFENSIVE / IMPORTANT flags are the only curation available there, so
-- the addon no longer decides which spells count - the game does.
-- Filters that are NOT identity-gated and therefore always safe: dispel types and the booleans
-- (isStealable, isBossAura, nameplateShowPersonal, maxDuration, ...). Precognition uses the
-- maxDuration one for exactly this reason.

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
	-- Unpartitioned importants, for displays that show nothing else (precognition).
	ImportantOnly = "HELPFUL|IMPORTANT",
}

-- Group keys. Always reference these rather than writing the string inline: SetMaxIcons is the
-- per-category on/off switch, and a typo there would silently disable a whole category.
M.GroupKey = {
	CrowdControl = "cc",
	BigDefensive = "bigdef",
	ExternalDefensive = "extdef",
	Important = "important",
}

---Builds the standard four-category group spec list for a display, in priority order.
---Returns a fresh table: `New` keeps the list for the display's lifetime, so it must not be
---shared between displays.
---@param maxIcons number Initial per-group icon budget (SetMaxIcons re-budgets per category).
---@return AuraDisplayGroupSpec[]
function M:BuildCategoryGroups(maxIcons)
	return {
		{ Key = M.GroupKey.CrowdControl, FilterString = M.Filter.CrowdControl, MaxIcons = maxIcons },
		{ Key = M.GroupKey.BigDefensive, FilterString = M.Filter.BigDefensive, MaxIcons = maxIcons },
		{ Key = M.GroupKey.ExternalDefensive, FilterString = M.Filter.ExternalDefensive, MaxIcons = maxIcons },
		{ Key = M.GroupKey.Important, FilterString = M.Filter.Important, MaxIcons = maxIcons },
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
