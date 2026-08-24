---@type string, Addon
local _, addon = ...

-- Shared plumbing for engine-side aura sounds (C_UnitAuras.AddAuraSound): on 12.1 the addon cannot
-- see auras appear, but the engine can play a sound when a spell it knows lands on a unit it knows.

---@class AuraSounds
local M = {}

addon.Core.AuraSounds = M

-- Reused UnitAuraSoundInfo for registrations; AddAuraSound reads it synchronously.
local infoScratch = { unitToken = nil, spellID = nil, soundFileName = nil, outputChannel = nil }
-- Freed handle lists, reused by the next registration instead of allocating a fresh one. A list can
-- run to ~1k entries per unit, so garbaging one per roster change adds up.
local idListPool = {}

---Registers an Added-trigger sound on one unit for every spell id in the set, appending the
---handles to `ids`. Pass nil to start a new list from the pool, or a previous return value to
---register a second set under the same key.
---@param ids number[]?
---@param unitToken string
---@param spellIds table<number, boolean>
---@param soundFile string resolved sound file path
---@param channel string
---@param excludedSpellIds table<number, boolean>? spells to skip
---@return number[] ids
function M:RegisterSet(ids, unitToken, spellIds, soundFile, channel, excludedSpellIds)
	ids = ids or table.remove(idListPool) or {}

	local info = infoScratch
	info.unitToken = unitToken
	info.soundFileName = soundFile
	info.outputChannel = channel

	for spellId in pairs(spellIds) do
		if not (excludedSpellIds and excludedSpellIds[spellId]) then
			info.spellID = spellId

			local handle = C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, info)

			if handle then
				ids[#ids + 1] = handle
			end
		end
	end

	return ids
end

---Registers an Added-trigger sound per spell id with that spell's own file, appending the
---handles to `ids`. The per-spell variant of RegisterSet for baked TTS clips.
---@param ids number[]?
---@param unitToken string
---@param filesBySpellId table<number, string> spell id -> file name
---@param basePath string prefix joined onto each file name
---@param channel string
---@param excludedSpellIds table<number, boolean>? spells to skip
---@return number[] ids
function M:RegisterMappedSet(ids, unitToken, filesBySpellId, basePath, channel, excludedSpellIds)
	ids = ids or table.remove(idListPool) or {}

	local info = infoScratch
	info.unitToken = unitToken
	info.outputChannel = channel

	for spellId, file in pairs(filesBySpellId) do
		if not (excludedSpellIds and excludedSpellIds[spellId]) then
			info.spellID = spellId
			info.soundFileName = basePath .. file

			local handle = C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, info)

			if handle then
				ids[#ids + 1] = handle
			end
		end
	end

	return ids
end

---Removes every registration in the list and hands the now-empty list back to the pool.
---Callers must drop their reference; the next RegisterSet may reuse the table.
---@param ids number[]?
function M:RemoveSet(ids)
	if not ids then
		return
	end

	for i = #ids, 1, -1 do
		C_UnitAuras.RemoveAuraSound(ids[i])
		ids[i] = nil
	end

	idListPool[#idListPool + 1] = ids
end
