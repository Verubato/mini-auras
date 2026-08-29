---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L

-- Shared plumbing for engine-side aura sounds (C_UnitAuras.AddAuraSound): on 12.1 the addon cannot
-- see auras appear, but the engine can play a sound when a spell it knows lands on a unit it knows.

-- Failure lines one session may print. An engine that has stopped taking anything makes every
-- spell id its own failure, and the set registered per unit runs to a thousand ids.
local MAX_FAILURE_LINES = 10

-- Reused UnitAuraSoundInfo for registrations; AddAuraSound reads it synchronously.
local infoScratch = { unitToken = nil, spellID = nil, soundFileName = nil, outputChannel = nil }
-- Freed handle lists, reused by the next registration instead of allocating a fresh one. A list can
-- run to ~1k entries per unit, so garbaging one per roster change adds up.
local idListPool = {}
-- Registrations are redone on every roster and nameplate change, so a failure that keeps coming
-- back would otherwise fill the chat frame.
---@type table<string, number>
local reportedFailures = {}
local printedFailures = 0

---@class AuraSounds
local M = {}

addon.Core.AuraSounds = M

---Whether the session has already said its last line.
---@return boolean
local function ReportingSpent()
	return printedFailures > MAX_FAILURE_LINES
end

---Says a failure the first time it comes back and counts it silently after that. The session gets
---a fixed number of lines, then one saying there will be no more.
---@param throttleKey string
---@param message string
---@param ... any format arguments
local function ReportOnce(throttleKey, message, ...)
	local seen = (reportedFailures[throttleKey] or 0) + 1

	reportedFailures[throttleKey] = seen

	if seen > 1 then
		return
	end

	if printedFailures < MAX_FAILURE_LINES then
		printedFailures = printedFailures + 1

		mini:NotifyWithPrefix(message, ...)

		return
	end

	if printedFailures == MAX_FAILURE_LINES then
		-- The summary takes a line of its own, so the ceiling holds back everything after it.
		printedFailures = printedFailures + 1

		mini:NotifyWithPrefix(L["No more sound failures will be reported this session."])
	end
end

---Whether a failed engine call is worth a line in chat.
---@return boolean
function M:DebugEnabled()
	local db = mini:GetSavedVars()

	return db.SoundDebugMessages ~= false
end

---Clears the record of what has failed, for every module, so failures are said again.
function M:ResetDebugLog()
	wipe(reportedFailures)

	printedFailures = 0
end

---Registers one sound with the engine, which is reported to throw now and again with no cause found.
---@param trigger number a UnitAuraSoundTrigger value
---@param info table UnitAuraSoundInfo
---@return number? handle nil when the engine refused the id or threw
function M:Add(trigger, info)
	local ok, handle = pcall(C_UnitAuras.AddAuraSound, trigger, info)

	if ok and handle then
		return handle
	end

	-- Checked here as well, because the key below builds a fresh string on every failure.
	if not self:DebugEnabled() or ReportingSpent() then
		return nil
	end

	local reason = not ok and tostring(handle) or L["the game returned no handle"]
	local spell = tostring(info.spellID)
	local unit = tostring(info.unitToken)

	ReportOnce(
		spell .. "|" .. unit .. "|" .. tostring(trigger) .. "|" .. reason,
		L["Sound registration failed. Spell %s, unit %s, trigger %s, file %s, channel %s. %s"],
		spell,
		unit,
		tostring(trigger),
		tostring(info.soundFileName),
		tostring(info.outputChannel),
		reason
	)

	return nil
end

---Hands one registration back to the engine.
---@param handle number
function M:Remove(handle)
	local ok, err = pcall(C_UnitAuras.RemoveAuraSound, handle)

	if ok or not self:DebugEnabled() or ReportingSpent() then
		return
	end

	-- Keyed on the reason alone, because a handle is only ever used once.
	local reason = tostring(err)

	ReportOnce(reason, L["Sound removal failed. Handle %s. %s"], tostring(handle), reason)
end

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

			local handle = self:Add(Enum.UnitAuraSoundTrigger.Added, info)

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

			local handle = self:Add(Enum.UnitAuraSoundTrigger.Added, info)

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
		self:Remove(ids[i])
		ids[i] = nil
	end

	idListPool[#idListPool + 1] = ids
end
