---@type string, Addon
local _, addon = ...

-- Captures the spell ids the player casts, so a group can be built without a spell database.
--
-- Only the LOCAL player's cast ids are readable on 12.1; a group member's arrive as secret values
-- that cannot even be used as a table key. What it records is the CAST id, which is usually but
-- not always the id of the aura it applies.

addon.Modules.CustomAuras = addon.Modules.CustomAuras or {}

-- Long enough for a full rotation, short enough to still scan.
local MAX_ENTRIES = 40

---@type table?
local eventsFrame
local recording = false
-- Newest first, which is the order the list is read in.
---@type CustomAuraRecordedCast[]
local entries = {}
---@type table<number, CustomAuraRecordedCast>
local byId = {}
---@type fun()[]
local changeCallbacks = {}

---@class CustomAurasRecorder
local M = {}

addon.Modules.CustomAuras.Recorder = M

local function NotifyChanged()
	for _, fn in ipairs(changeCallbacks) do
		fn()
	end
end

---@param spellId number
local function Record(spellId)
	local existing = byId[spellId]

	if existing then
		existing.Count = existing.Count + 1

		-- A spell pressed again is the one being looked for.
		for index, entry in ipairs(entries) do
			if entry == existing then
				table.remove(entries, index)
				break
			end
		end

		table.insert(entries, 1, existing)
		NotifyChanged()
		return
	end

	table.insert(entries, 1, { SpellId = spellId, Count = 1 })
	byId[spellId] = entries[1]

	local dropped = entries[MAX_ENTRIES + 1]

	if dropped then
		byId[dropped.SpellId] = nil
		table.remove(entries, MAX_ENTRIES + 1)
	end

	NotifyChanged()
end

local function OnEvent(_, _, _, _, spellId)
	if not recording then
		return
	end

	spellId = tonumber(spellId)

	if spellId then
		Record(spellId)
	end
end

local function EnsureFrame()
	if eventsFrame then
		return
	end

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
end

function M:Start()
	if recording then
		return
	end

	EnsureFrame()
	recording = true
	-- Only while recording: the event fires on every global cooldown.
	eventsFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
end

function M:Stop()
	if not recording then
		return
	end

	recording = false
	eventsFrame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
end

---@return boolean
function M:IsRecording()
	return recording
end

---The captured casts, newest first. Shared table, so do not keep or mutate it.
---@return CustomAuraRecordedCast[]
function M:GetEntries()
	return entries
end

function M:Clear()
	wipe(entries)
	wipe(byId)
	NotifyChanged()
end

---@param fn fun()
function M:OnChanged(fn)
	changeCallbacks[#changeCallbacks + 1] = fn
end

---@class CustomAuraRecordedCast
---@field SpellId number
---@field Count number
