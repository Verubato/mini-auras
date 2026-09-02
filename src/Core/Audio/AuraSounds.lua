---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local debugOptions = addon.Core.DebugOptions
local moduleUtil = addon.Utils.ModuleUtil

-- Shared plumbing for engine-side aura sounds (C_UnitAuras.AddAuraSound): on 12.1 the addon cannot
-- see auras appear, but the engine can play a sound when a spell it knows lands on a unit it knows.

-- Failure lines one session may print. An engine that has stopped taking anything makes every
-- spell id its own failure, and the set registered per unit runs to a thousand ids.
local MAX_FAILURE_LINES = 10
-- Places where combat has no say over a registration. An allow-list, so a kind of place nobody has
-- thought of costs a sound rather than a blocked call.
local COMBAT_SAFE_PLACES = {
	none = true,
	pvp = true,
	arena = true,
}

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
-- Whether a caller with registrations to make has been turned away, so combat ending knows there
-- is work to redo.
local skipped = false

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

---Clears the record of what has failed, for every module, so failures are said again.
function M:ResetDebugLog()
	wipe(reportedFailures)

	printedFailures = 0
end

---Whether the engine will take a registration right now. AddAuraSound is blocked while the player
---is in combat inside instanced PvE, where the call raises a blocked action instead of failing.
---@return boolean
function M:CanRegister()
	return COMBAT_SAFE_PLACES[moduleUtil:InstanceType()] == true or not InCombatLockdown()
end

---Records that a pass with work to do was turned away.
function M:NoteSkipped()
	skipped = true
end

---Whether anything was noted since this was last asked, clearing the record.
---@return boolean
function M:ConsumeSkipped()
	local refused = skipped

	skipped = false

	return refused
end

---Registers one sound with the engine.
---@param trigger number a UnitAuraSoundTrigger value
---@param info table UnitAuraSoundInfo
---@return number? handle nil where the gate refuses or the engine took no id
function M:Add(trigger, info)
	-- The backstop for every caller, including the ones that register outside a reconcile pass.
	if not self:CanRegister() then
		return nil
	end

	local handle = C_UnitAuras.AddAuraSound(trigger, info)

	if handle then
		return handle
	end

	-- Checked here as well, because the key below builds a fresh string on every failure.
	if not debugOptions:Enabled() or ReportingSpent() then
		return nil
	end

	local spell = tostring(info.spellID)
	local unit = tostring(info.unitToken)

	ReportOnce(
		spell .. "|" .. unit .. "|" .. tostring(trigger),
		L["Sound registration failed. Spell %s, unit %s, trigger %s, file %s, channel %s."],
		spell,
		unit,
		tostring(trigger),
		tostring(info.soundFileName),
		tostring(info.outputChannel)
	)

	return nil
end

---Hands one registration back to the engine.
---@param handle number
function M:Remove(handle)
	local ok, err = pcall(C_UnitAuras.RemoveAuraSound, handle)

	if ok or not debugOptions:Enabled() or ReportingSpent() then
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

	-- Asked here as well as in Add, because the set behind one unit runs to a thousand ids.
	if not self:CanRegister() then
		return ids
	end

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

	if not self:CanRegister() then
		return ids
	end

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
