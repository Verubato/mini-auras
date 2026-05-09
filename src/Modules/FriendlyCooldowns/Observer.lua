---@type string, Addon
local _, addon = ...
local unitAuraWatcher = addon.Core.UnitAuraWatcher

addon.Modules.FriendlyCooldowns = addon.Modules.FriendlyCooldowns or {}

---@class FriendlyCooldownObserver
local O = {}
addon.Modules.FriendlyCooldowns.Observer = O

-- entry -> { Watcher, CastEventFrame }
local watched = {}
local testModeActive = false
local auraChangedCallbacks    = {}
local castCallbacks           = {}
local shieldCallbacks         = {}
local unitFlagsCallbacks      = {}
local petAuraCallbacks        = {}
local debuffEvidenceCallbacks = {}
local modelChangedCallbacks   = {}
local portraitUpdateCallbacks = {}
local channelStartCallbacks   = {}
local channelStopCallbacks    = {}
-- Scratch table reused by FireAuraChanged to avoid per-event allocation.
local candidateUnitsScratch = {}
-- Scratch set reused by FireAuraChanged to deduplicate unit tokens.
local candidateSeenScratch = {}

local function FireAuraChanged(entry, watcher)
	-- Build a deduplicated candidateUnits list from all currently-watched entries.
	-- Multiple anchor frames can share the same unit token (e.g. 41 frames all pointing to "player"),
	-- so deduplication is required to avoid redundant cast-snapshot lookups and flooding debug output.
	local t = candidateUnitsScratch
	local seen = candidateSeenScratch
	local n = 0
	for e in pairs(watched) do
		local u = e.Unit
		if not seen[u] then
			seen[u] = true
			n = n + 1
			t[n] = u
		end
	end
	for i = n + 1, #t do t[i] = nil end -- trim tail from a prior larger group
	for k in pairs(seen) do seen[k] = nil end -- reset seen set for next call
	for _, fn in ipairs(auraChangedCallbacks) do
		fn(entry, watcher, t)
	end
end

local function FireCast(unit, spellId)
	for _, fn in ipairs(castCallbacks) do
		fn(unit, spellId)
	end
end

local function FireShield(unit)
	for _, fn in ipairs(shieldCallbacks) do
		fn(unit)
	end
end

local function FireUnitFlags(unit)
	for _, fn in ipairs(unitFlagsCallbacks) do
		fn(unit)
	end
end

local function FirePetAura(ownerUnit)
	for _, fn in ipairs(petAuraCallbacks) do
		fn(ownerUnit)
	end
end

local function FireModelChanged(unit)
	for _, fn in ipairs(modelChangedCallbacks) do
		fn(unit)
	end
end

local function FirePortraitUpdate(unit)
	for _, fn in ipairs(portraitUpdateCallbacks) do
		fn(unit)
	end
end

local function FireChannelStart(unit)
	for _, fn in ipairs(channelStartCallbacks) do fn(unit) end
end

local function FireChannelStop(unit)
	for _, fn in ipairs(channelStopCallbacks) do fn(unit) end
end

local function FireDebuffEvidence(unit, updateInfo)
	for _, fn in ipairs(debuffEvidenceCallbacks) do
		fn(unit, updateInfo)
	end
end

local function PetUnitForUnit(unit)
	return unit == "player" and "pet" or (unit .. "pet")
end

local function TryRecordPetDefensiveAura(ownerUnit, petUnit, updateInfo)
	if not updateInfo or updateInfo.isFullUpdate or not updateInfo.addedAuras then return end
	for _, aura in ipairs(updateInfo.addedAuras) do
		if aura.auraInstanceID
		   and not C_UnitAuras.IsAuraFilteredOutByInstanceID(petUnit, aura.auraInstanceID, "HELPFUL|BIG_DEFENSIVE")
		then
			FirePetAura(ownerUnit)
			return
		end
	end
end

local function CreatePetEventFrame(entry)
	local frame = CreateFrame("Frame")
	frame:SetScript("OnEvent", function(_, _, petUnit, updateInfo)
		TryRecordPetDefensiveAura(entry.Unit, petUnit, updateInfo)
	end)
	return frame
end

local function RegisterPetEvents(frame, unit)
	frame:RegisterUnitEvent("UNIT_AURA", PetUnitForUnit(unit))
end

local function CreateCastEventFrame(entry)
	local frame = CreateFrame("Frame")
	frame:SetScript("OnEvent", function(_, event, ...)
		-- Use entry.Unit rather than a closed-over unit string so that if the anchor
		-- is reassigned after a unit token change, evidence is keyed to the current unit.
		local u = entry.Unit
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			local _, _, spellId = ...
			FireCast(u, spellId)
		elseif event == "UNIT_FLAGS" then
			FireUnitFlags(u)
		elseif event == "UNIT_AURA" then
			local _, updateInfo = ...
			FireDebuffEvidence(u, updateInfo)
		elseif event == "UNIT_MODEL_CHANGED" then
			FireModelChanged(u)
		elseif event == "UNIT_PORTRAIT_UPDATE" then
			FirePortraitUpdate(u)
		elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
			FireChannelStart(u)
		elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
			FireChannelStop(u)
		end
	end)
	return frame
end

local function RegisterCastEvents(frame, unit)
	-- IMPORTANT: UNIT_AURA must fire before the watcher's own handler so that debuff evidence
	-- is recorded before FireAuraChanged runs. Callers must register cast events BEFORE
	-- creating/enabling the watcher to preserve this order.
	frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", unit)
	frame:RegisterUnitEvent("UNIT_FLAGS", unit)
	frame:RegisterUnitEvent("UNIT_AURA", unit)
	frame:RegisterUnitEvent("UNIT_MODEL_CHANGED", unit)
	frame:RegisterUnitEvent("UNIT_PORTRAIT_UPDATE", unit)
	frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", unit)
	frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", unit)
end

local function MakeWatcher(entry)
	local watcher = unitAuraWatcher:New(entry.Unit, nil, { Defensives = true, Important = true })
	watcher:RegisterCallback(function(w)
		if testModeActive then
			return
		end
		FireAuraChanged(entry, w)
	end)
	return watcher
end

---Begins watching a new entry. entry.Unit and entry.IsExcludedSelf must be set before calling.
---The cast event frame is registered BEFORE the watcher is created to preserve handler fire
---order (ensuring evidence is recorded before aura-changed callbacks run).
---@param entry FcdWatchEntry
function O:Watch(entry)
	local castEventFrame = CreateCastEventFrame(entry)
	RegisterCastEvents(castEventFrame, entry.Unit)

	local petEventFrame = CreatePetEventFrame(entry)
	RegisterPetEvents(petEventFrame, entry.Unit)

	local watcher = MakeWatcher(entry)
	watched[entry] = { Watcher = watcher, CastEventFrame = castEventFrame, PetEventFrame = petEventFrame }

	-- Seed: the watcher primed its state before our callback was registered; process it now.
	if not testModeActive then
		FireAuraChanged(entry, watcher)
	end
end

---Re-watches an entry after entry.Unit has changed (unit token reassignment).
---entry.Unit and entry.IsExcludedSelf must be updated before calling.
---@param entry FcdWatchEntry
function O:Rewatch(entry)
	local state = watched[entry]
	if not state then
		return
	end

	-- Re-register cast events BEFORE creating the new watcher to preserve fire order.
	state.CastEventFrame:UnregisterAllEvents()
	RegisterCastEvents(state.CastEventFrame, entry.Unit)

	state.PetEventFrame:UnregisterAllEvents()
	RegisterPetEvents(state.PetEventFrame, entry.Unit)

	state.Watcher:Dispose()
	state.Watcher = MakeWatcher(entry)

	if not testModeActive then
		FireAuraChanged(entry, state.Watcher)
	end
end

---Disables watching for an entry without releasing resources (watcher disabled, events cleared).
---@param entry FcdWatchEntry
function O:Disable(entry)
	local state = watched[entry]
	if not state then
		return
	end
	state.CastEventFrame:UnregisterAllEvents()
	state.PetEventFrame:UnregisterAllEvents()
	state.Watcher:Disable()
end

---Fully stops watching an entry and releases its watcher resources.
---Use instead of Disable when the entry will not be re-enabled.
---@param entry FcdWatchEntry
function O:Forget(entry)
	local state = watched[entry]
	if not state then
		return
	end
	state.CastEventFrame:UnregisterAllEvents()
	state.PetEventFrame:UnregisterAllEvents()
	state.Watcher:Dispose()
	watched[entry] = nil
end

---Re-enables watching for an entry after Disable.
---@param entry FcdWatchEntry
function O:Enable(entry)
	local state = watched[entry]
	if not state then
		return
	end
	-- Register cast events before Watcher:Enable to preserve handler fire order.
	RegisterCastEvents(state.CastEventFrame, entry.Unit)
	RegisterPetEvents(state.PetEventFrame, entry.Unit)
	state.Watcher:Enable()
	state.Watcher:ForceFullUpdate()
end

---Sets whether test mode is active. Watcher callbacks are suppressed during test mode.
---@param active boolean
function O:SetTestMode(active)
	testModeActive = active
end

---Registers a callback fired when a watched unit's aura state changes.
---fn(entry, watcher, candidateUnits) where candidateUnits is a flat list of all watched unit strings.
---@param fn fun(entry: FcdWatchEntry, watcher: Watcher, candidateUnits: string[])
function O:RegisterAuraChangedCallback(fn)
	auraChangedCallbacks[#auraChangedCallbacks + 1] = fn
end

---Registers a callback fired when a watched unit successfully casts a spell.
---@param fn fun(unit: string, spellId: number)
function O:RegisterCastCallback(fn)
	castCallbacks[#castCallbacks + 1] = fn
end

---Registers a callback fired when any unit's absorb amount changes (shield application).
---@param fn fun(unit: string)
function O:RegisterShieldCallback(fn)
	shieldCallbacks[#shieldCallbacks + 1] = fn
end

---Registers a callback fired when a watched unit's combat/immune flags change.
---@param fn fun(unit: string)
function O:RegisterUnitFlagsCallback(fn)
	unitFlagsCallbacks[#unitFlagsCallbacks + 1] = fn
end

---Registers a callback fired when a watched unit's pet receives a BIG_DEFENSIVE aura.
---fn(unit) where unit is the owner (hunter), not the pet.
---@param fn fun(unit: string)
function O:RegisterPetAuraCallback(fn)
	petAuraCallbacks[#petAuraCallbacks + 1] = fn
end

---Registers a callback fired when a HARMFUL aura is added to a watched unit.
---@param fn fun(unit: string, updateInfo: table?)
function O:RegisterDebuffEvidenceCallback(fn)
	debuffEvidenceCallbacks[#debuffEvidenceCallbacks + 1] = fn
end

---Registers a callback fired when a watched unit's model changes (UNIT_MODEL_CHANGED).
---@param fn fun(unit: string)
function O:RegisterModelChangedCallback(fn)
	modelChangedCallbacks[#modelChangedCallbacks + 1] = fn
end

---Registers a callback fired when a watched unit's portrait updates (UNIT_PORTRAIT_UPDATE).
---@param fn fun(unit: string)
function O:RegisterPortraitUpdateCallback(fn)
	portraitUpdateCallbacks[#portraitUpdateCallbacks + 1] = fn
end

---Registers a callback fired when a watched unit begins channeling a spell (UNIT_SPELLCAST_CHANNEL_START).
---@param fn fun(unit: string)
function O:RegisterChannelStartCallback(fn)
	channelStartCallbacks[#channelStartCallbacks + 1] = fn
end

---Registers a callback fired when a watched unit's channel ends or is interrupted (UNIT_SPELLCAST_CHANNEL_STOP).
---@param fn fun(unit: string)
function O:RegisterChannelStopCallback(fn)
	channelStopCallbacks[#channelStopCallbacks + 1] = fn
end

---Creates the global absorb-shield frame. Must be called once from M:Init.
---Tracks UNIT_ABSORB_AMOUNT_CHANGED globally (not per-unit) because absorb changes on any unit
---are used as concurrent evidence to disambiguate Paladin defensives.
function O:Init()
	local absorbFrame = CreateFrame("Frame")
	absorbFrame:SetScript("OnEvent", function(_, _, unit)
		FireShield(unit)
	end)
	absorbFrame:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")
end
