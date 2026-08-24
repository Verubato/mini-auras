---@type string, Addon
local _, addon = ...

-- The TTS Spells tab saves an opt-out list per category, so a spell it has never been told about is
-- announced. For the handful in AuraCategoryIds.TtsDefaultOff the rule flips and an absent id is
-- silent. Both the tab and the sound registrations read the state through here.

local auraCategoryIds = addon.Core.AuraCategoryIds

-- One effective set per category, refilled on each read rather than allocated: the nameplate
-- path asks for one per token.
local effectiveByCategory = {}

---@class TtsMutes
local M = {}

addon.Core.TtsMutes = M

---@param mutedIds table<number, boolean>? The saved opt-out list for the category.
---@param spellId number
---@return boolean
function M:IsMuted(mutedIds, spellId)
	local saved = mutedIds and mutedIds[spellId]

	if saved == nil then
		return auraCategoryIds.TtsDefaultOff[spellId] or false
	end

	return saved
end

---What to save when a row is switched on or off. A default-off spell needs an explicit false
---when it is switched on, since dropping the key would read as silent again.
---@param spellId number
---@param muted boolean
---@return boolean?
function M:StoredValue(spellId, muted)
	if muted then
		return true
	end

	if auraCategoryIds.TtsDefaultOff[spellId] then
		return false
	end

	return nil
end

---The set the registrations and their change check run off: the saved opt-outs plus whichever
---default-off spells the player has left alone. The table is reused per category, so a caller
---must be done with one read before asking for the next.
---@param category string "Important", "Defensive" or "EnemyDebuff"
---@param mutedIds table<number, boolean>?
---@return table<number, boolean>
function M:EffectiveSet(category, mutedIds)
	local set = effectiveByCategory[category]

	if not set then
		set = {}
		effectiveByCategory[category] = set
	end

	wipe(set)

	if mutedIds then
		for spellId, muted in pairs(mutedIds) do
			if muted then
				set[spellId] = true
			end
		end
	end

	for spellId in pairs(auraCategoryIds.TtsDefaultOff) do
		if M:IsMuted(mutedIds, spellId) then
			set[spellId] = true
		end
	end

	return set
end
