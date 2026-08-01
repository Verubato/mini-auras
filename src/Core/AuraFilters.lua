---@type string, Addon
local _, addon = ...
local auraSoundData = addon.Core.AuraSoundData

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
-- The ID lists come from Core/AuraSoundData - the same generated in-game scan of the
-- CROWD_CONTROL / IMPORTANT / defensive spell flags that feeds the aura-sound registrations,
-- filtered offline to player PvP abilities. That last part is the one behaviour change: on the
-- paths where the gate DOES apply the maps, category members with no player PvP ability behind
-- them (mob and boss CC, PvE-only important buffs) stop showing.
--
-- Other candidate filters are NOT identity-gated and are always safe: dispel types and the
-- booleans (isStealable, isBossAura, nameplateShowPersonal, maxDuration, ...). Precognition uses
-- the maxDuration one for exactly this reason.

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

-- Spell-ID maps per category, keyed to match M.Filter so a caller holding a filter name can look
-- up both. The generated Defensive list is not split into big/external - it does not have to be,
-- because the filter strings still partition those two groups, so an aura is never drawn twice.
M.SpellIds = {
	CrowdControl = auraSoundData.CC,
	BigDefensive = auraSoundData.Defensive,
	ExternalDefensive = auraSoundData.Defensive,
	Important = auraSoundData.Important,
	ImportantOnly = auraSoundData.Important,
}

-- Ready-made candidateFilters tables, keyed to match M.Filter, so a group spec can point straight
-- at one instead of allocating a wrapper per display (the nameplate and alert pools build these
-- by the dozen). Shared and read-only: the engine keeps the reference it is handed and nothing
-- here mutates it. Displays needing extra candidate filters (precognition's maxDuration) build
-- their own table from M.SpellIds instead.
M.CandidateFilters = {
	CrowdControl = { includeSpellIDs = M.SpellIds.CrowdControl },
	BigDefensive = { includeSpellIDs = M.SpellIds.BigDefensive },
	ExternalDefensive = { includeSpellIDs = M.SpellIds.ExternalDefensive },
	Important = { includeSpellIDs = M.SpellIds.Important },
	ImportantOnly = { includeSpellIDs = M.SpellIds.ImportantOnly },
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
		{
			Key = M.GroupKey.CrowdControl,
			FilterString = M.Filter.CrowdControl,
			CandidateFilters = M.CandidateFilters.CrowdControl,
			MaxIcons = maxIcons,
		},
		{
			Key = M.GroupKey.BigDefensive,
			FilterString = M.Filter.BigDefensive,
			CandidateFilters = M.CandidateFilters.BigDefensive,
			MaxIcons = maxIcons,
		},
		{
			Key = M.GroupKey.ExternalDefensive,
			FilterString = M.Filter.ExternalDefensive,
			CandidateFilters = M.CandidateFilters.ExternalDefensive,
			MaxIcons = maxIcons,
		},
		{
			Key = M.GroupKey.Important,
			FilterString = M.Filter.Important,
			CandidateFilters = M.CandidateFilters.Important,
			MaxIcons = maxIcons,
		},
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
