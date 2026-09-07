---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx

-- Captures the auras that land on the player, so a group can be built without a spell database.

addon.Modules.PersonalAuras = addon.Modules.PersonalAuras or {}

-- Long enough for a fight's worth of auras, short enough to still scan.
local MAX_ENTRIES = 40

---@type table?
local eventsFrame
local recording = false
-- Newest first, which is the order the list is read in.
---@type PersonalAuraRecordedAura[]
local entries = {}
---@type table<number, PersonalAuraRecordedAura>
local byId = {}
---@type fun()[]
local changeCallbacks = {}

---@class PersonalAurasRecorder
local M = {}

addon.Modules.PersonalAuras.Recorder = M

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

		-- An aura that lands again is the one being looked for.
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

local function OnEvent(_, _, _, updateInfo)
	if not recording then
		return
	end

	-- The payload is a secret value while auras are hidden, so nothing reads it before this.
	if wowEx:IsAuraStylingRestricted() then
		return
	end

	local added = updateInfo and updateInfo.addedAuras

	if not added then
		return
	end

	for _, aura in ipairs(added) do
		local spellId = aura and tonumber(aura.spellId)

		if spellId then
			Record(spellId)
		end
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
	-- Registered only while recording, since UNIT_AURA is the busiest event the client has.
	eventsFrame:RegisterUnitEvent("UNIT_AURA", "player")
end

function M:Stop()
	if not recording then
		return
	end

	recording = false
	eventsFrame:UnregisterEvent("UNIT_AURA")
end

---@return boolean
function M:IsRecording()
	return recording
end

---The captured auras, newest first. Shared table, so do not keep or mutate it.
---@return PersonalAuraRecordedAura[]
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

---@class PersonalAuraRecordedAura
---@field SpellId number
---@field Count number
