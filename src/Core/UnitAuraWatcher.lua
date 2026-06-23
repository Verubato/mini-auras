---@type string, Addon
local _, addon = ...

-- Dispel type color mapping
local dispelColours = {
	-- https://wago.tools/db2/SpellDispelType
	[0] = DEBUFF_TYPE_NONE_COLOR,
	[1] = DEBUFF_TYPE_MAGIC_COLOR,
	[2] = DEBUFF_TYPE_CURSE_COLOR,
	[3] = DEBUFF_TYPE_DISEASE_COLOR,
	[4] = DEBUFF_TYPE_POISON_COLOR,
	[11] = DEBUFF_TYPE_BLEED_COLOR,
}
local dispelColorCurve
-- Shared empty state returned when a unit has no live data. Never mutate this.
local emptyAuraState = {}
-- Scratch table reused by RebuildStates as a dedup set; wiped at start of each call.
local rebuildSeen = {}
-- Context for the hoisted RebuildStates collectors, set before each IterateAuras pass so the
-- callbacks aren't reallocated as closures every rebuild. Entry tables live in `rebuildTarget` and
-- are reused by index across rebuilds, avoiding a per-aura table allocation (a GC hotspot in groups).
local rebuildTarget
local rebuildCount = 0

local function InitColourCurve()
	if dispelColorCurve then
		return
	end

	dispelColorCurve = C_CurveUtil.CreateColorCurve()
	dispelColorCurve:SetType(Enum.LuaCurveType.Step)

	for type, colour in pairs(dispelColours) do
		dispelColorCurve:AddPoint(type, colour)
	end
end

-- Hoisted sort comparators so RebuildStates doesn't allocate new closures each call.
local function byInstanceIdForward(a, b) return a.AuraInstanceID < b.AuraInstanceID end
local function byInstanceIdReverse(a, b) return a.AuraInstanceID > b.AuraInstanceID end

---@class UnitAuraWatcher
local M = {}
addon.Core.UnitAuraWatcher = M

---@param watcher Watcher
local function NotifyCallbacks(watcher)
	local callbacks = watcher.State.Callbacks

	if not callbacks or #callbacks == 0 then
		return
	end

	for _, callback in ipairs(callbacks) do
		callback(watcher)
	end
end

---Quick check using updateInfo to avoid a full RebuildStates when nothing we care about changed.
---@param watcher Watcher
---@param updateInfo table?
---@return boolean
local function InterestedIn(watcher, updateInfo)
	if not updateInfo or updateInfo.isFullUpdate then
		return true
	end

	local state = watcher.State
	local unit = state.Unit
	local activeFilters = state.ActiveFilters

	if updateInfo.addedAuras then
		for _, aura in pairs(updateInfo.addedAuras) do
			local id = aura.auraInstanceID
			if id then
				for _, filter in ipairs(activeFilters) do
					if not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, filter) then
						return true
					end
				end
			end
		end
	end

	if updateInfo.updatedAuraInstanceIDs then
		for _, id in pairs(updateInfo.updatedAuraInstanceIDs) do
			if id then
				for _, filter in ipairs(activeFilters) do
					if not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, filter) then
						return true
					end
				end
			end
		end
	end

	-- Removed auras are already gone, so the filter API can't be used.
	-- Instead check whether any removed ID matches one we were tracking.
	if updateInfo.removedAuraInstanceIDs and next(updateInfo.removedAuraInstanceIDs) ~= nil then
		local ccState = state.CcAuraState
		local defState = state.DefensiveState
		local buffState = state.BuffState
		for _, id in pairs(updateInfo.removedAuraInstanceIDs) do
			for _, aura in ipairs(ccState) do
				if aura.AuraInstanceID == id then return true end
			end
			for _, aura in ipairs(defState) do
				if aura.AuraInstanceID == id then return true end
			end
			for _, aura in ipairs(buffState) do
				if aura.AuraInstanceID == id then return true end
			end
		end
	end

	return false
end

local function WatcherFrameOnEvent(frame, event, ...)
	local watcher = frame.Watcher
	if not watcher then
		return
	end
	watcher:OnEvent(event, ...)
end

local Watcher = {}
Watcher.__index = Watcher

function Watcher:GetUnit()
	return self.State.Unit
end

---@param callback fun(self: Watcher)
function Watcher:RegisterCallback(callback)
	if not callback then
		return
	end
	self.State.Callbacks[#self.State.Callbacks + 1] = callback
end

function Watcher:IsEnabled()
	return self.State.Enabled
end

function Watcher:Enable()
	if self.State.Enabled then
		return
	end

	local frame = self.Frame
	if not frame then
		return
	end

	frame:RegisterUnitEvent("UNIT_AURA", self.State.Unit)

	if self.State.Events then
		for _, event in ipairs(self.State.Events) do
			frame:RegisterEvent(event)
		end
	end

	self.State.Enabled = true
end

function Watcher:Disable()
	if not self.State.Enabled then
		return
	end

	local frame = self.Frame
	if frame then
		frame:UnregisterAllEvents()
	end

	self.State.Enabled = false
end

---@param notify boolean?
function Watcher:ClearState(notify)
	local state = self.State
	wipe(state.CcAuraState)
	wipe(state.DefensiveState)
	wipe(state.BuffState)
	wipe(state.CcById)
	wipe(state.DefById)
	wipe(state.BuffById)

	if notify then
		NotifyCallbacks(self)
	end
end

function Watcher:ForceFullUpdate()
	-- force a rebuild immediately
	self:OnEvent("UNIT_AURA", self.State.Unit, { isFullUpdate = true })
end

---@param sortRule number
---@param sortDirection number
function Watcher:SetSort(sortRule, sortDirection)
	if self.State.SortRule == sortRule and self.State.SortDirection == sortDirection then
		return
	end
	self.State.SortRule = sortRule
	self.State.SortDirection = sortDirection
	self:ForceFullUpdate()
end

function Watcher:Dispose()
	local frame = self.Frame
	if frame then
		frame:UnregisterAllEvents()
		frame:SetScript("OnEvent", nil)
		frame.Watcher = nil
	end
	self.Frame = nil

	-- ensure we don't keep references alive
	self.State.Callbacks = {}
	self:ClearState(false)
end

---@return AuraInfo[]
function Watcher:GetCcState()
	local unit = self.State.Unit
	if not unit or not UnitExists(unit) or UnitIsDeadOrGhost(unit) then
		return emptyAuraState
	end

	return self.State.CcAuraState
end

---@return AuraInfo[]
function Watcher:GetDefensiveState()
	local unit = self.State.Unit
	if not unit or not UnitExists(unit) or UnitIsDeadOrGhost(unit) then
		return emptyAuraState
	end

	return self.State.DefensiveState
end

---Every HELPFUL aura on the unit (no IsSpellImportant/IsDefensive gating). Callers that only
---want "important" auras must check C_Spell.IsSpellImportant themselves - it returns a secret
---value, so it can't be filtered here.
---@return AuraInfo[]
function Watcher:GetBuffState()
	local unit = self.State.Unit
	if not unit or not UnitExists(unit) or UnitIsDeadOrGhost(unit) then
		return emptyAuraState
	end

	return self.State.BuffState
end

---@param unit string
---@param filter string
---@param sortRule number?
---@param sortDirection number?
---@param callback fun(auraData: table, start: number, duration: number, dispelColor: table)
local function IterateAuras(unit, filter, sortRule, sortDirection, callback)
	local auras = C_UnitAuras.GetUnitAuras(unit, filter, nil, sortRule, sortDirection)

	for _, auraData in ipairs(auras) do
		local durationInfo = C_UnitAuras.GetAuraDuration(unit, auraData.auraInstanceID)

		if durationInfo then
			local dispelColor = C_UnitAuras.GetAuraDispelTypeColor(unit, auraData.auraInstanceID, dispelColorCurve)
			callback(auraData, durationInfo, dispelColor)
		end
	end
end

-- Returns the next pooled entry in rebuildTarget, creating it once and reusing it on later rebuilds.
local function NextRebuildEntry()
	rebuildCount = rebuildCount + 1
	local entry = rebuildTarget[rebuildCount]
	if not entry then
		entry = {}
		rebuildTarget[rebuildCount] = entry
	end
	return entry
end

-- Trims pooled entries past `count` so #arr reflects the live entries (and releases the surplus).
local function TrimRebuildArray(arr, count)
	for i = #arr, count + 1, -1 do
		arr[i] = nil
	end
end

-- Fills the shared per-aura fields on an entry. IsCC / IsDefensive are set by the caller.
local function Populate(entry, auraData, durationInfo, dispelColor)
	entry.SpellId = auraData.spellId
	entry.SpellName = auraData.name
	entry.SpellIcon = auraData.icon
	entry.DurationObject = durationInfo
	entry.DispelColor = dispelColor
	entry.AuraInstanceID = auraData.auraInstanceID
end

local function CollectBigDefensive(auraData, durationInfo, dispelColor)
	-- units out of range produce garbage data, so double check
	local isDefensive = C_UnitAuras.AuraIsBigDefensive(auraData.spellId)
	if issecretvalue(isDefensive) or isDefensive then
		local entry = NextRebuildEntry()
		entry.IsDefensive = isDefensive
		Populate(entry, auraData, durationInfo, dispelColor)
	end

	rebuildSeen[auraData.auraInstanceID] = true
end

local function CollectExternalDefensive(auraData, durationInfo, dispelColor)
	if not rebuildSeen[auraData.auraInstanceID] then
		local entry = NextRebuildEntry()
		entry.IsDefensive = true
		Populate(entry, auraData, durationInfo, dispelColor)

		rebuildSeen[auraData.auraInstanceID] = true
	end
end

local function CollectCC(auraData, durationInfo, dispelColor)
	-- protect against garbage data
	local isCC = C_Spell.IsSpellCrowdControl(auraData.spellId)
	if issecretvalue(isCC) or isCC then
		local entry = NextRebuildEntry()
		entry.IsCC = isCC
		Populate(entry, auraData, durationInfo, dispelColor)
	end

	rebuildSeen[auraData.auraInstanceID] = true
end

local function CollectBuff(auraData, durationInfo, dispelColor)
	-- Every helpful aura, ungated. The "important" check (precog, Nullifying Shroud) is a secret
	-- value, so consumers apply it themselves at display time.
	Populate(NextRebuildEntry(), auraData, durationInfo, dispelColor)
end

-- Removes the given entry table from a state list (linear scan; the lists are small).
local function RemoveEntry(list, entry)
	for i = 1, #list do
		if list[i] == entry then
			table.remove(list, i)
			return
		end
	end
end

local function SortById(list, reverse)
	table.sort(list, reverse and byInstanceIdReverse or byInstanceIdForward)
end

-- Rebuilds the AuraInstanceID -> entry lookups from the freshly-built state lists, so the
-- incremental path (which keys off them) stays in sync after a full rebuild.
local function RebuildIdMaps(state)
	local ccById, defById, buffById = state.CcById, state.DefById, state.BuffById
	wipe(ccById)
	wipe(defById)
	wipe(buffById)
	for _, e in ipairs(state.CcAuraState) do ccById[e.AuraInstanceID] = e end
	for _, e in ipairs(state.DefensiveState) do defById[e.AuraInstanceID] = e end
	for _, e in ipairs(state.BuffState) do buffById[e.AuraInstanceID] = e end
end

function Watcher:RebuildStates()
	local unit = self.State.Unit

	if not unit then
		return
	end

	if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then
		local state = self.State
		local hasState = next(state.CcAuraState) ~= nil
			or next(state.DefensiveState) ~= nil
			or next(state.BuffState) ~= nil
		if hasState then
			self:ClearState(true)
		end
		return
	end

	local state = self.State

	---@type AuraTypeFilter?
	local interestedIn = state.InterestedIn
	local interestedInDefensives = not interestedIn or (interestedIn and interestedIn.Defensives)
	local interestedInCC = not interestedIn or (interestedIn and interestedIn.CC)
	-- Buffs are opt-in only (never part of the "all" default) to avoid duplicating defensives.
	local interestedInBuffs = interestedIn and interestedIn.Buffs

	-- Reuse the existing state arrays in-place to avoid per-call allocation. Entry tables are pooled
	-- (reused by index via NextRebuildEntry), so the arrays are NOT wiped up front - instead each is
	-- trimmed to its live count after filling.
	---@type AuraInfo[]
	local ccSpellData = state.CcAuraState
	---@type AuraInfo[]
	local defensivesSpellData = state.DefensiveState
	---@type AuraInfo[]
	local buffSpellData = state.BuffState
	wipe(rebuildSeen)

	local sortRule = state.SortRule
	local sortDirection = state.SortDirection

	if interestedInDefensives then
		rebuildTarget = defensivesSpellData
		rebuildCount = 0
		IterateAuras(unit, "HELPFUL|BIG_DEFENSIVE", sortRule, sortDirection, CollectBigDefensive)
		IterateAuras(unit, "HELPFUL|EXTERNAL_DEFENSIVE", sortRule, sortDirection, CollectExternalDefensive)
		TrimRebuildArray(defensivesSpellData, rebuildCount)
	else
		TrimRebuildArray(defensivesSpellData, 0)
	end

	if interestedInCC then
		rebuildTarget = ccSpellData
		rebuildCount = 0
		IterateAuras(unit, "HARMFUL|CROWD_CONTROL", sortRule, sortDirection, CollectCC)
		TrimRebuildArray(ccSpellData, rebuildCount)
	else
		TrimRebuildArray(ccSpellData, 0)
	end

	if interestedInBuffs then
		rebuildTarget = buffSpellData
		rebuildCount = 0
		IterateAuras(unit, "HELPFUL", sortRule, sortDirection, CollectBuff)
		TrimRebuildArray(buffSpellData, rebuildCount)
	else
		TrimRebuildArray(buffSpellData, 0)
	end

	-- When unsorted, the API may return auras in a non-deterministic order (observed on Chinese clients).
	-- Sort by AuraInstanceID to ensure a consistent order, respecting the requested direction.
	if sortRule == Enum.UnitAuraSortRule.Unsorted then
		local byInstanceId = sortDirection == Enum.UnitAuraSortDirection.Reverse
			and byInstanceIdReverse or byInstanceIdForward
		table.sort(ccSpellData, byInstanceId)
		table.sort(defensivesSpellData, byInstanceId)
		table.sort(buffSpellData, byInstanceId)
	end

	-- Resync the AuraInstanceID -> entry lookups the incremental path keys off.
	RebuildIdMaps(state)
	-- Arrays were modified in-place; no reassignment needed.
end

-- Which category lists changed during the current ApplyIncremental call (module-level scratch, set
-- by AddAuraIncremental and the removal loop; safe because UNIT_AURA handling is never reentrant).
local incTouched = { cc = false, def = false, buff = false }

-- Classifies one added aura into the state lists + id-maps exactly as RebuildStates would: the
-- secret-safe IsCC / IsDefensive gating and the BIG-before-EXTERNAL defensive dedup. Returns true
-- if it landed in any category.
local function AddAuraIncremental(state, unit, auraData)
	local id = auraData.auraInstanceID
	if not id or state.CcById[id] or state.DefById[id] or state.BuffById[id] then
		return false
	end

	local durationInfo = C_UnitAuras.GetAuraDuration(unit, id)
	if not durationInfo then
		return false
	end
	local dispelColor = C_UnitAuras.GetAuraDispelTypeColor(unit, id, dispelColorCurve)
	local added = false

	if state.WantsCC and not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HARMFUL|CROWD_CONTROL") then
		local isCC = C_Spell.IsSpellCrowdControl(auraData.spellId)
		if issecretvalue(isCC) or isCC then
			local entry = { IsCC = isCC }
			Populate(entry, auraData, durationInfo, dispelColor)
			local list = state.CcAuraState
			list[#list + 1] = entry
			state.CcById[id] = entry
			incTouched.cc = true
			added = true
		end
	end

	if state.WantsDefensives then
		local entry
		if not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|BIG_DEFENSIVE") then
			-- BIG matched: include only when AuraIsBigDefensive agrees (secret-safe), and never fall
			-- through to EXTERNAL (mirrors the rebuild's `seen` dedup).
			local isBig = C_UnitAuras.AuraIsBigDefensive(auraData.spellId)
			if issecretvalue(isBig) or isBig then
				entry = { IsDefensive = isBig }
			end
		elseif not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|EXTERNAL_DEFENSIVE") then
			entry = { IsDefensive = true }
		end
		if entry then
			Populate(entry, auraData, durationInfo, dispelColor)
			local list = state.DefensiveState
			list[#list + 1] = entry
			state.DefById[id] = entry
			incTouched.def = true
			added = true
		end
	end

	if state.WantsBuffs and not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL") then
		local entry = {}
		Populate(entry, auraData, durationInfo, dispelColor)
		local list = state.BuffState
		list[#list + 1] = entry
		state.BuffById[id] = entry
		incTouched.buff = true
		added = true
	end

	return added
end

-- Applies a partial UNIT_AURA delta (removed/added/updated) without re-querying the whole unit.
-- The caller guarantees an Unsorted watcher on a live unit. Returns true when something relevant
-- changed (so the caller knows whether to notify).
function Watcher:ApplyIncremental(updateInfo)
	local state = self.State
	local unit = state.Unit
	local changed = false
	incTouched.cc = false
	incTouched.def = false
	incTouched.buff = false

	-- Removals first so a remove+re-add of the same AuraInstanceID in one update behaves correctly.
	if updateInfo.removedAuraInstanceIDs then
		for _, id in pairs(updateInfo.removedAuraInstanceIDs) do
			local e = state.CcById[id]
			if e then RemoveEntry(state.CcAuraState, e); state.CcById[id] = nil; incTouched.cc = true; changed = true end
			e = state.DefById[id]
			if e then RemoveEntry(state.DefensiveState, e); state.DefById[id] = nil; incTouched.def = true; changed = true end
			e = state.BuffById[id]
			if e then RemoveEntry(state.BuffState, e); state.BuffById[id] = nil; incTouched.buff = true; changed = true end
		end
	end

	if updateInfo.addedAuras then
		for _, auraData in pairs(updateInfo.addedAuras) do
			if AddAuraIncremental(state, unit, auraData) then changed = true end
		end
	end

	-- Updates change an aura's data (duration/stacks) but not its category or sort position, so
	-- refresh the tracked entries in place without re-sorting.
	if updateInfo.updatedAuraInstanceIDs then
		for _, id in pairs(updateInfo.updatedAuraInstanceIDs) do
			local cc, def, buff = state.CcById[id], state.DefById[id], state.BuffById[id]
			if cc or def or buff then
				local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, id)
				local durationInfo = C_UnitAuras.GetAuraDuration(unit, id)
				if aura and durationInfo then
					local dispelColor = C_UnitAuras.GetAuraDispelTypeColor(unit, id, dispelColorCurve)
					if cc then Populate(cc, aura, durationInfo, dispelColor) end
					if def then Populate(def, aura, durationInfo, dispelColor) end
					if buff then Populate(buff, aura, durationInfo, dispelColor) end
					changed = true
				end
			end
		end
	end

	if incTouched.cc or incTouched.def or incTouched.buff then
		local reverse = state.SortDirection == Enum.UnitAuraSortDirection.Reverse
		if incTouched.cc then SortById(state.CcAuraState, reverse) end
		if incTouched.def then SortById(state.DefensiveState, reverse) end
		if incTouched.buff then SortById(state.BuffState, reverse) end
	end

	return changed
end

function Watcher:OnEvent(event, ...)
	local state = self.State

	if event == "UNIT_AURA" then
		local unit, updateInfo = ...
		if unit and unit ~= state.Unit then
			return
		end
		if not state.Unit then
			return
		end

		-- Incremental fast path: apply just the delta instead of re-querying every aura. Limited to a
		-- partial update (a full update has no usable delta), an Unsorted watcher (the Default sort
		-- order can't be reproduced without re-querying), and a live unit (dead/absent units clear).
		if updateInfo and not updateInfo.isFullUpdate
			and state.SortRule == Enum.UnitAuraSortRule.Unsorted
			and UnitExists(state.Unit) and not UnitIsDeadOrGhost(state.Unit) then
			if self:ApplyIncremental(updateInfo) then
				NotifyCallbacks(self)
			end
			return
		end

		-- Full path: full update, Default sort, or dead/absent unit.
		if not InterestedIn(self, updateInfo) then
			return
		end
	elseif event == "ARENA_OPPONENT_UPDATE" then
		local unit = ...
		if unit ~= state.Unit then
			return
		end
	end

	if not state.Unit then
		return
	end

	self:RebuildStates()
	NotifyCallbacks(self)
end

---@param unit string
---@param events string[]?
---@param interestedIn AuraTypeFilter?
---@param sortRule number? -- Enum.UnitAuraSortRule value, defaults to Enum.UnitAuraSortRule.Unsorted
---@param sortDirection number? -- Enum.UnitAuraSortDirection value, defaults to Enum.UnitAuraSortDirection.Normal
---@return Watcher
function M:New(unit, events, interestedIn, sortRule, sortDirection)
	if not unit then
		error("unit must not be nil")
	end

	-- Pre-compute which filters this watcher will query, so InterestedIn
	-- doesn't have to rebuild this list on every UNIT_AURA event.
	local all = not interestedIn
	local activeFilters = {}
	if all or interestedIn.Defensives then
		activeFilters[#activeFilters + 1] = "HELPFUL|BIG_DEFENSIVE"
		activeFilters[#activeFilters + 1] = "HELPFUL|EXTERNAL_DEFENSIVE"
	end
	if all or interestedIn.CC then
		activeFilters[#activeFilters + 1] = "HARMFUL|CROWD_CONTROL"
	end
	-- Opt-in only; not part of the "all" default (would duplicate the defensive filters).
	if interestedIn and interestedIn.Buffs then
		activeFilters[#activeFilters + 1] = "HELPFUL"
	end

	---@type Watcher
	local watcher = setmetatable({
		Frame = nil,
		State = {
			Unit = unit,
			Events = events,
			Enabled = false,
			Callbacks = {},
			CcAuraState = {},
			DefensiveState = {},
			BuffState = {},
			-- AuraInstanceID -> entry lookups for the incremental delta path (one per category list).
			CcById = {},
			DefById = {},
			BuffById = {},
			InterestedIn = interestedIn,
			-- Normalised interest flags, also used by the incremental classifier.
			WantsCC = all or interestedIn.CC == true,
			WantsDefensives = all or interestedIn.Defensives == true,
			WantsBuffs = interestedIn ~= nil and interestedIn.Buffs == true,
			ActiveFilters = activeFilters,
			SortRule = sortRule or Enum.UnitAuraSortRule.Unsorted,
			SortDirection = sortDirection or Enum.UnitAuraSortDirection.Normal,
		},
	}, Watcher)

	local frame = CreateFrame("Frame")
	frame.Watcher = watcher
	frame:SetScript("OnEvent", WatcherFrameOnEvent)

	watcher.Frame = frame
	watcher:Enable()

	-- Prime once so state is immediately available to callers that read it
	-- synchronously or via a deferred callback after registering.
	watcher:ForceFullUpdate()

	return watcher
end

InitColourCurve()

---@class AuraTypeFilter
---@field CC boolean?
---@field Defensives boolean?
---@field Buffs boolean?  -- collect every HELPFUL aura (ungated); opt-in only

---@class AuraInfo
---@field IsCC? boolean
---@field IsDefensive? boolean
---@field SpellId number?
---@field SpellIcon string?
---@field SpellName string?
---@field DurationObject table?
---@field DispelColor table?
---@field AuraInstanceID number?

---@class WatcherState
---@field Unit string
---@field Events string[]?
---@field Enabled boolean
---@field Callbacks (fun(self: Watcher))[]
---@field CcAuraState AuraInfo[]
---@field DefensiveState AuraInfo[]
---@field BuffState AuraInfo[]
---@field CcById table<number, AuraInfo>
---@field DefById table<number, AuraInfo>
---@field BuffById table<number, AuraInfo>
---@field InterestedIn AuraTypeFilter
---@field WantsCC boolean
---@field WantsDefensives boolean
---@field WantsBuffs boolean
---@field ActiveFilters string[]
---@field SortRule number
---@field SortDirection number

---@class Watcher
---@field Frame table?
---@field State WatcherState
---@field GetCcState fun(self: Watcher): AuraInfo[]
---@field GetDefensiveState fun(self: Watcher): AuraInfo[]
---@field GetBuffState fun(self: Watcher): AuraInfo[]
---@field RegisterCallback fun(self: Watcher, callback: fun(self: Watcher))
---@field GetUnit fun(self: Watcher): string
---@field IsEnabled fun(self: Watcher): boolean
---@field Enable fun(self: Watcher)
---@field Disable fun(self: Watcher)
---@field ClearState fun(self: Watcher, notify: boolean?)
---@field ForceFullUpdate fun(self: Watcher)
---@field SetSort fun(self: Watcher, sortRule: number, sortDirection: number)
---@field ApplyIncremental fun(self: Watcher, updateInfo: table): boolean
---@field Dispose fun(self: Watcher)
