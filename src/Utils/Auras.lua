---@type string, Addon
local _, addon = ...
---@class AuraUtil
local M = {}
addon.Utils.Auras = M

-- LEGACY PATH ONLY: every remaining caller reads Blizzard's nameplate buff lists, which the 12.1
-- path replaced with HELPFUL|IMPORTANT aura groups (the engine curates them, so there is no
-- purgeable garbage to strip). This whole file goes when the legacy path does.

---Returns true when a helpful aura is purgeable (has a dispel type the player can remove) AND is not
---a defensive cooldown. The important displays use this to strip the non-important purgeable garbage
---Blizzard's enemy nameplate list bundles in, while still keeping purgeable defensives (e.g. magic
---barriers) visible. Secret-safe: only secure aura filters, no IsSpellImportant/isStealable branching.
---@param unit string
---@param auraInstanceID number
---@return boolean
function M:IsPurgeableNonDefensive(unit, auraInstanceID)
	return not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, "HELPFUL|RAID_PLAYER_DISPELLABLE")
		and C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, "HELPFUL|BIG_DEFENSIVE")
		and C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, "HELPFUL|EXTERNAL_DEFENSIVE")
end

return M
