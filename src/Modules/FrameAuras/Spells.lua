---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local trackedBuffs = addon.Core.TrackedBuffs

-- An id nothing will ever have, for a tracked set that comes out empty. An empty spell-id map
-- reads to the engine as "no ids required", so the group would match every buff on the unit
-- instead of none of them.
local NEVER_MATCHED_SPELL_ID = 2147483647
local EMPTY = {}
-- The section holding whatever the player added by hand. Always shown, even when empty, because
-- it is where the add box lives.
local CUSTOM_GROUP_KEY = "CUSTOM"

addon.Modules.FrameAuras = addon.Modules.FrameAuras or {}

---@class FrameAurasSpells
local M = {}

addon.Modules.FrameAuras.Spells = M

M.CustomGroupKey = CUSTOM_GROUP_KEY

---The module's saved settings, or nil before saved variables are up.
---@return table?
local function Options()
	local db = mini:GetSavedVars()

	return db and db.Modules and db.Modules.FrameAuras or nil
end

---The two override maps, created on first read. A profile written before the module existed has
---neither, and the panel writes into them as soon as it is opened.
---@return table? disabled, table? custom
local function Overrides()
	local options = Options()

	if not options then
		return nil, nil
	end

	options.Spells = options.Spells or {}
	options.Spells.Disabled = options.Spells.Disabled or {}
	options.Spells.Custom = options.Spells.Custom or {}

	return options.Spells.Disabled, options.Spells.Custom
end

---Whether a spell id is one the addon ships tracking.
---@param spellId number
---@return boolean
function M:IsCurated(spellId)
	return trackedBuffs.ById[spellId] == true
end

---Whether a spell id is tracked right now, curated or added by hand.
---@param spellId number
---@return boolean
function M:IsTracked(spellId)
	local disabled, custom = Overrides()

	if M:IsCurated(spellId) then
		return not (disabled and disabled[spellId])
	end

	return (custom and custom[spellId]) == true
end

---Tracks or stops tracking one spell id. A curated id is switched off rather than removed, and an
---added one is forgotten outright, so the overrides never grow entries that say nothing.
---@param spellId number
---@param tracked boolean
function M:SetTracked(spellId, tracked)
	local disabled, custom = Overrides()

	if not disabled then
		return
	end

	if M:IsCurated(spellId) then
		disabled[spellId] = not tracked or nil

		return
	end

	custom[spellId] = tracked or nil
end

---Forgets a hand-added spell outright, which is what the list's remove button does. A curated one
---is only ever switched off, and the list is where it gets switched back on.
---@param spellId number
function M:Forget(spellId)
	local _, custom = Overrides()

	if custom then
		custom[spellId] = nil
	end
end

---Whether the refresh-window reveal is switched on for the buff row.
---@return boolean
function M:IsPandemicEnabled()
	local options = Options()

	return options ~= nil and options.Buffs ~= nil and options.Buffs.PandemicGlow == true
end

---Whether a spell lights up as it enters its refresh window. Which spells carry the cue is fixed
---in the tracked data, so the only thing a player moves is whether any of them do.
---@param spellId number
---@return boolean
function M:HasPandemic(spellId)
	return M:IsPandemicEnabled() and trackedBuffs.Pandemic[spellId] == true
end

---Every spell id tracked right now, in ascending order, for a list the player reads.
---@param out number[] Refilled in place.
---@return number[] out
function M:TrackedList(out)
	local disabled, custom = Overrides()

	disabled = disabled or EMPTY
	custom = custom or EMPTY

	for index = #out, 1, -1 do
		out[index] = nil
	end

	for spellId in pairs(trackedBuffs.ById) do
		if not disabled[spellId] then
			out[#out + 1] = spellId
		end
	end

	for spellId, tracked in pairs(custom) do
		if tracked == true and not trackedBuffs.ById[spellId] then
			out[#out + 1] = spellId
		end
	end

	table.sort(out)

	return out
end

---The sections the spell list is read in: one per class the addon ships spells for, then the ones
---the player added by hand. Every curated id is listed whether it is switched on or not, since
---the list is how it gets switched back on.
---@return { Key: string, Ids: number[], Custom: boolean? }[]
function M:SpellGroups()
	local out = {}

	for _, group in ipairs(trackedBuffs.Groups) do
		out[#out + 1] = { Key = group.Class, Ids = group.Ids }
	end

	local _, custom = Overrides()
	local added = {}

	for spellId, tracked in pairs(custom or EMPTY) do
		if tracked == true and not trackedBuffs.ById[spellId] then
			added[#added + 1] = spellId
		end
	end

	table.sort(added)

	out[#out + 1] = { Key = CUSTOM_GROUP_KEY, Ids = added, Custom = true }

	return out
end

---How many spells can light up on refresh at once, which is the most icons the glow group can ever
---need. The engine hands out a group's buttons from the count it was born with.
---@return number
function M:PandemicCount()
	local count = 0

	if not M:IsPandemicEnabled() then
		return 0
	end

	for _, spellId in ipairs(M:TrackedList({})) do
		if trackedBuffs.Pandemic[spellId] == true then
			count = count + 1
		end
	end

	return count
end

---Every tracked id as one map, for a row that draws them all through a single group.
---
---A fresh table each time, since the engine keeps whatever reference it is handed and this changes
---as the player edits the list.
---@return table<number, boolean>
function M:BuildSpellMap()
	local map = {}

	for _, spellId in ipairs(M:TrackedList({})) do
		map[spellId] = true
	end

	-- An empty map reads to the engine as "no ids required", so it would match every buff on the
	-- unit rather than none of them.
	if next(map) == nil then
		map[NEVER_MATCHED_SPELL_ID] = true
	end

	return map
end

---The tracked ids as the engine wants them, split by whether they light up on refresh. Two sets
---because the reveal is registered on a button when it is built and the engine drives it from a
---window nothing can read, so the only way to pick which spells get one is to put them in their
---own group.
---
---Fresh tables each time, since the engine keeps whatever reference it is handed and these change
---as the player edits the list.
---@return table<number, boolean> pandemic, table<number, boolean> plain
function M:BuildSpellSets()
	local pandemic, plain = {}, {}
	-- Asked once because it reads the settings and the list runs to hundreds.
	local glowing = M:IsPandemicEnabled()

	for _, spellId in ipairs(M:TrackedList({})) do
		if glowing and trackedBuffs.Pandemic[spellId] == true then
			pandemic[spellId] = true
		else
			plain[spellId] = true
		end
	end

	-- An empty map reads to the engine as "no ids required", so a group carrying one would match
	-- every buff on the unit rather than none of them.
	if next(pandemic) == nil then
		pandemic[NEVER_MATCHED_SPELL_ID] = true
	end

	if next(plain) == nil then
		plain[NEVER_MATCHED_SPELL_ID] = true
	end

	return pandemic, plain
end
