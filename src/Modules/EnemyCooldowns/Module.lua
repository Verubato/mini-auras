---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local rules      = addon.Modules.Cooldowns.Rules
local fcdTalents = addon.Modules.Cooldowns.Talents
local fcdBrain   = addon.Modules.Cooldowns.Brain
local SignatureDetector = addon.Modules.Cooldowns.SignatureDetector
local observer   = addon.Modules.EnemyCooldowns.Observer
local display    = addon.Modules.EnemyCooldowns.Display

---@class EnemyCooldownTrackerModule : IModule
local M = {}
addon.Modules.EnemyCooldowns.Module = M
addon.Modules.EnemyCooldownTrackerModule = M

local arenaUnits = { "arena1", "arena2", "arena3" }
local watchEntries = {}  ---@type table<string, EcdWatchEntry>  keyed by unit string
local testModeActive = false
local editModeActive = false
local observersEnabled = false  -- true once EnableAll() has been called; prevents redundant ForceFullUpdate on every Refresh
local eventsFrame
---@type Db
local db

-- Seconds of timing tolerance when matching a measured buff duration to a rule.
-- Shared with FriendlyCooldowns Brain to ensure identical matching behaviour.
local evidenceTolerance = 0.15
local castWindow = 0.15

-- Per-unit evidence timestamps (separate from FriendlyCooldowns Brain's state so
-- enemy and friendly evidence don't cross-contaminate).
local lastUnitFlagsTime      = {}  ---@type table<string, number>
local lastDebuffTime         = {}  ---@type table<string, number>
local lastCastTime           = {}  ---@type table<string, number>
local lastShieldTime         = {}  ---@type table<string, number>
-- True while in the arena prep room (PvPMatchState.StartUp). Auras are still tracked so pre-applied
-- buffs aren't treated as new when the gates open, but cooldown prediction/commit is suppressed -
-- otherwise pre-existing enemy buffs seen as the watcher starts would falsely trigger cooldowns.
local inPrepRoom             = false

local function GetOptions()
	return db and db.Modules.EnemyCooldownTrackerModule
end

-- Evidence

---Builds an EvidenceSet for a unit at detectionTime from our own evidence tables.
---For enemies, Cast evidence is never collected (UNIT_SPELLCAST_SUCCEEDED is unavailable).
---@param unit string
---@param detectionTime number
---@return EvidenceSet?
local function BuildEvidenceSet(unit, detectionTime)
	local ev = nil
	if lastDebuffTime[unit] and math.abs(lastDebuffTime[unit] - detectionTime) <= evidenceTolerance then
		ev = ev or {}
		ev.Debuff = true
	end
	if lastShieldTime[unit] and math.abs(lastShieldTime[unit] - detectionTime) <= evidenceTolerance then
		ev = ev or {}
		ev.Shield = true
	end
	if lastUnitFlagsTime[unit] and math.abs(lastUnitFlagsTime[unit] - detectionTime) <= castWindow then
		ev = ev or {}
		ev.UnitFlags = true
	end
	return ev
end

---Merges Cast into a base EvidenceSet for prediction.
---hasCast is true when there is cast evidence (real snapshot or synthesised on 12.0.5+).
---@param base EvidenceSet?
---@param hasCast boolean
---@return EvidenceSet?
local function BuildPredictEvidence(base, hasCast)
	if not hasCast then return base end
	if base then
		local ev = {}
		for k, v in pairs(base) do ev[k] = v end
		ev.Cast = true
		return ev
	end
	return { Cast = true }
end

-- Aura ID classification

local function AuraTypesSignature(auraTypes)
	local s = ""
	if auraTypes["BIG_DEFENSIVE"]      then s = s .. "B" end
	if auraTypes["EXTERNAL_DEFENSIVE"] then s = s .. "E" end
	if auraTypes["CROWD_CONTROL"]      then s = s .. "C" end
	return s
end

---Builds a map of current aura instance IDs and their types from the watcher state.
---@param unit string
---@param watcher Watcher
---@return table<number, {AuraTypes: table<string,boolean>, DurationObject: table}>
local function BuildCurrentAuraIds(unit, watcher)
	local currentIds = {}

	local function applyCC(id, auraTypes)
		local isHarmful = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HARMFUL|CROWD_CONTROL")
		local isHelpful = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|CROWD_CONTROL")
		if isHarmful or isHelpful then
			auraTypes["CROWD_CONTROL"] = true
			if isHarmful then auraTypes["CC_HARMFUL"] = true end
			if isHelpful then auraTypes["CC_HELPFUL"] = true end
		end
	end

	for _, aura in ipairs(watcher:GetDefensiveState()) do
		local id = aura.AuraInstanceID
		if id then
			-- EXTERNAL_DEFENSIVE takes priority: some spells (e.g. Ironbark) pass both
			-- BIG_DEFENSIVE and EXTERNAL_DEFENSIVE filters, but their cooldown belongs to
			-- the caster, not the recipient.
			local isExtDef = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|EXTERNAL_DEFENSIVE")
			local auraTypes = {}
			if isExtDef then
				auraTypes["EXTERNAL_DEFENSIVE"] = true
			else
				auraTypes["BIG_DEFENSIVE"] = true
			end
			applyCC(id, auraTypes)
			currentIds[id] = { AuraTypes = auraTypes, DurationObject = aura.DurationObject }
		end
	end

	return currentIds
end

-- Display dispatch

---Routes display updates based on the current display mode.
---  Linear:      arena1's container shows combined cooldowns from all entries.
---  ArenaFrames: each entry's container is updated independently.
---@param entry EcdWatchEntry
local function TriggerDisplayUpdate(entry)
	local options = GetOptions()
	if not options then
		display:UpdateDisplay(entry)
		return
	end
	local mode = options.DisplayMode
	if mode == "Linear" then
		display:UpdateLinearDisplay(watchEntries)
	else
		display:UpdateDisplay(entry)
	end
end

-- Cooldown commit

---Stores a committed cooldown entry on the watch entry and schedules its cleanup.
local function CommitCooldown(entry, tracked, rule, measuredDuration)
	-- Rules flagged ExcludeFromEnemyTracking are never tracked for enemies (e.g. Burrow, whose
	-- talent we can't confirm on opponents).  The aura-match path already drops these, so this
	-- guard exists for the signature-detection path, which commits synthetic rules directly.
	if rules.IsExcludedFromEnemyTracking(rule.SpellId) then return end

	-- Apply talent-based cooldown reduction and look up max charges.
	local cooldown = rule.Cooldown
	local maxCharges = nil
	if rule.SpellId then
		local specId = fcdTalents:GetUnitSpecId(entry.Unit)
		local _, classToken = UnitClass(entry.Unit)
		if classToken then
			cooldown = fcdTalents:GetUnitCooldown(entry.Unit, specId, classToken, rule.SpellId, cooldown, measuredDuration)
			local ruleBaseCharges = rule.BaseCharges or 1
			if (rule.MaxCharges or ruleBaseCharges) > 1 then
				local charges = fcdTalents:GetUnitMaxCharges(entry.Unit, specId, classToken, rule.SpellId)
				maxCharges = math.max(ruleBaseCharges, charges)
			end
		end
	end

	local auraTypesKey = tracked.AuraTypes["BIG_DEFENSIVE"] and "BIG_DEFENSIVE"
		or "EXTERNAL_DEFENSIVE"
	local cdKey = rule.SpellId or (auraTypesKey .. "_" .. (rule.BuffDuration or 0) .. "_" .. rule.Cooldown)

	if maxCharges and maxCharges > 1 then
		local existing = entry.ActiveCooldowns[cdKey]
		if existing and existing.MaxCharges == maxCharges and existing.UsedCharges then
			-- Check if this exact use was already committed (prediction then OnAuraRemoved
			-- both call CommitCooldown for the same tracked entry).  Each charge stores the
			-- StartTime of its originating tracked entry so we can detect the recommit.
			for _, uc in ipairs(existing.UsedCharges) do
				if uc.StartTime == tracked.StartTime then
					return  -- already committed; timers are accurate, nothing to do
				end
			end
			if #existing.UsedCharges < existing.MaxCharges then
				-- New charge while an earlier one is still recharging: append sequentially.
				local prevCharge = existing.UsedCharges[#existing.UsedCharges]
				local newExpiry  = math.max(prevCharge.Expiry + cooldown, tracked.StartTime + cooldown)
				local newCharge  = { Expiry = newExpiry, StartTime = tracked.StartTime }
				existing.UsedCharges[#existing.UsedCharges + 1] = newCharge
				newCharge.Timer = C_Timer.NewTimer(math.max(0, newExpiry - GetTime()), function()
					for i, uc in ipairs(existing.UsedCharges) do
						if uc == newCharge then
							table.remove(existing.UsedCharges, i)
							break
						end
					end
					if #existing.UsedCharges == 0 and entry.ActiveCooldowns[cdKey] == existing then
						entry.ActiveCooldowns[cdKey] = nil
					end
					TriggerDisplayUpdate(entry)
				end)
				return
			end
		end
		-- No existing entry with room (or stale): cancel old per-charge timers and create fresh.
		if existing and existing.UsedCharges then
			for _, uc in ipairs(existing.UsedCharges) do
				if uc.Timer then uc.Timer:Cancel() end
			end
		end
		local firstExpiry = tracked.StartTime + cooldown
		local firstCharge = { Expiry = firstExpiry, StartTime = tracked.StartTime }
		local cdData = {
			StartTime   = tracked.StartTime,
			Cooldown    = cooldown,
			Remaining   = cooldown - measuredDuration,
			SpellId     = rule.SpellId,
			MaxCharges  = maxCharges,
			UsedCharges = { firstCharge },
		}
		entry.ActiveCooldowns[cdKey] = cdData
		firstCharge.Timer = C_Timer.NewTimer(math.max(0, firstExpiry - GetTime()), function()
			for i, uc in ipairs(cdData.UsedCharges) do
				if uc == firstCharge then
					table.remove(cdData.UsedCharges, i)
					break
				end
			end
			if #cdData.UsedCharges == 0 and entry.ActiveCooldowns[cdKey] == cdData then
				entry.ActiveCooldowns[cdKey] = nil
			end
			TriggerDisplayUpdate(entry)
		end)
		return
	end

	-- Single-charge: cancel any stale timer and store the new entry.
	local existing = entry.ActiveCooldowns[cdKey]
	if existing and existing.CleanupTimer then
		existing.CleanupTimer:Cancel()
	end

	local cdData = {
		StartTime = tracked.StartTime,
		Cooldown  = cooldown,
		Remaining = cooldown - measuredDuration,
		SpellId   = rule.SpellId,
	}
	cdData.CleanupTimer = C_Timer.NewTimer(math.max(0, tracked.StartTime + cooldown - GetTime()), function()
		if entry.ActiveCooldowns[cdKey] == cdData then
			entry.ActiveCooldowns[cdKey] = nil
		end
		TriggerDisplayUpdate(entry)
	end)

	entry.ActiveCooldowns[cdKey] = cdData
end

-- Event-signature detection (Burrow + Emerald Communion).
-- No talent checks on the enemy path: talent data is unavailable for arena opponents.
-- Burrow never commits here because its rule is flagged ExcludeFromEnemyTracking (see
-- CommitCooldown's guard); it remains here only so the detector's shared state stays consistent.
local sd = SignatureDetector:New({
	checkTalent  = false,
	burrowCommit = function(unit, now, castTime)
		local entry = watchEntries[unit]
		if not entry then return end
		local syntheticTracked = { StartTime = castTime, AuraTypes = {} }
		CommitCooldown(entry, syntheticTracked, { SpellId = 409293, Cooldown = 120 }, now - castTime)
		TriggerDisplayUpdate(entry)
	end,
	ecCommit = function(unit, now, castTime)
		local entry = watchEntries[unit]
		if not entry then return end
		local syntheticTracked = { StartTime = castTime, AuraTypes = {} }
		CommitCooldown(entry, syntheticTracked, { SpellId = 370960, Cooldown = 180 }, now - castTime)
		TriggerDisplayUpdate(entry)
	end,
})

-- Aura lifecycle

---Called when a tracked aura disappears. Tries to match a rule; returns true if a cooldown was committed.
local function OnAuraRemoved(entry, tracked)
	-- Don't commit cooldowns from auras dropping during the prep room.
	if inPrepRoom then
		return false
	end

	local now              = GetTime()
	local measuredDuration = now - tracked.StartTime

	-- For non-external auras the caster is usually entry.Unit itself, but two cases require
	-- expanding the candidate list to all arena units so FindBestCandidate can attribute the
	-- cooldown to the correct caster:
	--   Shield evidence: a CastableOnOthers absorb spell (e.g. AMS Spellwarding) was cast by
	--     another enemy unit, not the aura's recipient.
	-- For external defensives all arena units are always valid casters.
	local candidateUnits = {}
	if tracked.AuraTypes["EXTERNAL_DEFENSIVE"]
	   or (tracked.Evidence and tracked.Evidence["Shield"])
	then
		for unit in pairs(watchEntries) do
			candidateUnits[#candidateUnits + 1] = unit
		end
	end

	local rule, ruleUnit = fcdBrain:FindBestCandidate(entry, tracked, measuredDuration, candidateUnits, { IgnoreTalentRequirements = true })

	if not rule then
		return false
	end

	CommitCooldown(watchEntries[ruleUnit] or entry, tracked, rule, measuredDuration)
	return true
end

---Records a newly detected aura and schedules a deferred backfill for evidence
---that may arrive slightly after UNIT_AURA (e.g. UNIT_FLAGS, UNIT_SPELLCAST_SUCCEEDED).
local function TrackNewAura(entry, trackedAuras, id, info, now)
	local unit     = entry.Unit
	local evidence = BuildEvidenceSet(unit, now)

	-- Snapshot cast times for all arena units so FindBestCandidate can attribute the
	-- cooldown to the correct caster (used for both external and self-cast auras).
	local castSnapshot = {}
	for _, u in ipairs(arenaUnits) do
		castSnapshot[u] = lastCastTime[u]
	end

	trackedAuras[id] = {
		StartTime      = now,
		AuraTypes      = info.AuraTypes,
		Evidence       = evidence,
		DurationObject = info.DurationObject,
		CastSnapshot   = castSnapshot,
	}

	-- During the prep room, track the aura (above) but don't predict/commit a cooldown from it -
	-- pre-existing enemy buffs would otherwise falsely trigger as the watcher starts. Tracking it
	-- still means it won't be seen as "new" (re-triggering) once the gates open.
	if inPrepRoom then
		return
	end

	-- Deferred backfill: UNIT_FLAGS and UNIT_SPELLCAST_SUCCEEDED can arrive slightly after UNIT_AURA.
	C_Timer.After(evidenceTolerance, function()
		local tracked = trackedAuras[id]
		if not tracked then
			return
		end

		-- Merge any evidence that arrived after UNIT_AURA.
		local ev = BuildEvidenceSet(unit, now)
		if ev then
			tracked.Evidence = tracked.Evidence or {}
			for k in pairs(ev) do
				tracked.Evidence[k] = true
			end
		end

		-- Backfill cast timestamps that arrived after UNIT_AURA.
		for _, u in ipairs(arenaUnits) do
			if not tracked.CastSnapshot[u] then
				local ct = lastCastTime[u]
				if ct and math.abs(ct - now) <= castWindow then
					tracked.CastSnapshot[u] = ct
				end
			end
		end

		-- Early prediction: identify and commit the cooldown while the buff is still active
		-- so the icon appears immediately when the enemy uses the ability rather than after
		-- the buff drops. OnAuraRemoved will recommit when the buff ends with accurate
		-- measured duration; CommitCooldown's CleanupTimer:Cancel() handles deduplication.
		if not tracked.PredictedSpellId then
			local predEntry, predRule
			if tracked.AuraTypes["EXTERNAL_DEFENSIVE"] then
				for _, candidateUnit in ipairs(arenaUnits) do
					local candidateEntry = watchEntries[candidateUnit]
					if candidateEntry then
						local hasCast = true
						local predEv  = BuildPredictEvidence(tracked.Evidence, hasCast)
						local spellId, isOnCd = fcdBrain:PredictSpellId(
							candidateUnit, tracked.AuraTypes, predEv, candidateEntry.ActiveCooldowns)
						if spellId and not isOnCd then
							local r = fcdBrain:MatchRule(candidateUnit, tracked.AuraTypes, 0,
								{ KnownSpellIds = { spellId } })
							if r then
								predEntry = candidateEntry
								predRule  = r
								break
							end
						end
					end
				end
			else
				local snap    = tracked.CastSnapshot[unit]
				local hasCast = snap ~= nil and math.abs(snap - now) <= castWindow
				local predEv  = BuildPredictEvidence(tracked.Evidence, hasCast)
				local spellId, isOnCd = fcdBrain:PredictSpellId(
					unit, tracked.AuraTypes, predEv, entry.ActiveCooldowns)
				if spellId and not isOnCd then
					local r = fcdBrain:MatchRule(unit, tracked.AuraTypes, 0,
						{ KnownSpellIds = { spellId } })
					if r then
						predEntry = entry
						predRule  = r
					end
				end
			end

			if predRule then
				tracked.PredictedSpellId = predRule.SpellId
				CommitCooldown(predEntry, tracked, predRule, 0)
				TriggerDisplayUpdate(predEntry)
			end
		end
	end)
end

---Processes a watcher state change: detects new / removed auras and commits cooldowns.
---@param entry EcdWatchEntry
---@param watcher Watcher
local function OnWatcherChanged(entry, watcher)
	local now         = GetTime()
	local trackedAuras = entry.TrackedAuras
	local currentIds  = BuildCurrentAuraIds(entry.Unit, watcher)

	-- Collect unmatched new IDs for heuristic reconciliation.
	-- On full updates the server may reassign aura instance IDs; if the AuraTypes signature
	-- matches an orphaned tracked entry, carry tracking forward under the new ID.
	local unmatchedNewIds = {}
	for id in pairs(currentIds) do
		if not trackedAuras[id] then
			unmatchedNewIds[#unmatchedNewIds + 1] = id
		end
	end

	local newIdsBySignature = {}
	for _, id in ipairs(unmatchedNewIds) do
		local sig = AuraTypesSignature(currentIds[id].AuraTypes)
		newIdsBySignature[sig] = newIdsBySignature[sig] or {}
		newIdsBySignature[sig][#newIdsBySignature[sig] + 1] = id
	end

	local cooldownCommitted = false
	for id, tracked in pairs(trackedAuras) do
		if not currentIds[id] then
			local sig        = AuraTypesSignature(tracked.AuraTypes)
			local candidates = newIdsBySignature[sig]
			if candidates and #candidates > 0 then
				-- Carry tracking forward under the new instance ID.
				local reassignedId = table.remove(candidates, 1)
				trackedAuras[reassignedId] = tracked
			else
				if OnAuraRemoved(entry, tracked) then
					cooldownCommitted = true
				end
			end
			trackedAuras[id] = nil
		end
	end

	for id, info in pairs(currentIds) do
		if not trackedAuras[id] then
			TrackNewAura(entry, trackedAuras, id, info, now)
		end
	end

	if cooldownCommitted then
		TriggerDisplayUpdate(entry)
	end
end

-- Entry management

local function EnsureEntry(unit, index)
	local options = GetOptions()
	if not options then
		return nil
	end

	local entry = watchEntries[unit]
	if not entry then
		local size     = tonumber(options.Icons.Size) or 24
		local container = iconSlotContainer:New(
			UIParent, 20, size, (options.IconSpacing or 2),
			"Enemy CDs " .. unit, true, "Enemy CDs"
		)
		-- Hide immediately so ShowHideAllEntries sees wasHidden=true on first show
		-- and calls TriggerDisplayUpdate to populate the slots.
		container.Frame:Hide()
		entry = {
			Unit            = unit,
			Index           = index,
			Container       = container,
			TrackedAuras    = {},
			ActiveCooldowns = {},
		}
		watchEntries[unit] = entry
		observer:Watch(entry)

		-- Arena1 is the drag anchor for Linear mode.
		-- SetMovable/SetClampedToScreen are applied only during test mode (see StartTesting/StopTesting)
		-- so that the frame's anchor behaves identically to arena2/3 during normal play.
		if index == 1 then
			local frame = container.Frame
			frame:EnableMouse(false)
			frame:RegisterForDrag("LeftButton")
			frame:SetScript("OnDragStart", function(f) f:StartMoving() end)
			frame:SetScript("OnDragStop", function(f)
				f:StopMovingOrSizing()
				local opts = GetOptions()
				if opts then
					local point, relativeTo, relativePoint, x, y = f:GetPoint()
					opts.Linear.Point         = point
					opts.Linear.RelativeTo    = (relativeTo and relativeTo:GetName()) or "UIParent"
					opts.Linear.RelativePoint = relativePoint
					opts.Linear.X             = x
					opts.Linear.Y             = y
				end
			end)
		end
	end

	return entry
end

local function EnsureAllEntries()
	for i, unit in ipairs(arenaUnits) do
		EnsureEntry(unit, i)
	end
end

---Returns true when any arena opponent slot exists (or test mode is active).
---Used to decide whether the combined linear bar should be visible.
---During arena prep the unit tokens (arena1-3) don't exist yet, but opponent specs are already
---known via GetNumArenaOpponentSpecs - treat that as "present" so the always-show icons can be
---displayed in the prep room rather than only once the gates open.
local function AnyArenaUnitExists()
	return testModeActive
		or UnitExists("arena1") or UnitExists("arena2") or UnitExists("arena3")
		or (GetNumArenaOpponentSpecs and GetNumArenaOpponentSpecs() > 0)
end

---Returns true when a specific arena opponent slot is present: either its unit token exists (once
---the gates open) or its spec is already known during the prep room (before the tokens exist).
---@param unit string
---@param index number  1=arena1, 2=arena2, 3=arena3
local function ArenaUnitPresent(unit, index)
	if UnitExists(unit) then
		return true
	end
	local spec = GetArenaOpponentSpec and GetArenaOpponentSpec(index)
	return spec ~= nil and spec > 0
end

---Shows or hides each entry's container frame based on display mode and unit visibility.
---  Linear:      only arena1 visible (acts as the combined bar); arena2/3 hidden.
---  ArenaFrames: per-unit containers visible (when arena frame addons supply the anchor).
local function ShowHideAllEntries()
	local options = GetOptions()
	if not options then return end

	local mode = options.DisplayMode

	for i, unit in ipairs(arenaUnits) do
		local entry = watchEntries[unit]
		if entry then
			local shouldShow
			if mode == "Linear" then
				-- Only arena1's container is visible in Linear mode; it shows all enemies combined.
				shouldShow = i == 1 and not editModeActive and AnyArenaUnitExists()
			else
				-- ArenaFrames mode uses per-unit visibility based on the opponent slot being
				-- present (existing unit token, or known spec during prep) plus an arena frame to
				-- anchor to.  Using ArenaUnitPresent lets the per-unit containers show in the prep
				-- room, before the unit tokens exist, the same way the linear bar already does.
				shouldShow = not editModeActive and (testModeActive or ArenaUnitPresent(unit, i))
				if shouldShow and not testModeActive then
					shouldShow = display:GetArenaEnemyFrame(i) ~= nil
				end
			end

			if shouldShow then
				local wasHidden = not entry.Container.Frame:IsShown()
				entry.Container.Frame:Show()
				-- Only refresh display content when transitioning from hidden->visible.
				-- Avoiding this on every Refresh eliminates redundant SetSlot/Layout work.
				if wasHidden then
					TriggerDisplayUpdate(entry)
				end
			else
				entry.Container.Frame:Hide()
			end
		end
	end
end

local function DisableAll()
	if not observersEnabled then
		return
	end
	observersEnabled = false
	for _, entry in pairs(watchEntries) do
		observer:Disable(entry)
		entry.Container:ResetAllSlots()
		entry.Container.Frame:Hide()
	end
end

local function EnableAll()
	if observersEnabled then
		return
	end
	observersEnabled = true
	for _, entry in pairs(watchEntries) do
		observer:Enable(entry)
	end
end

-- State reset

---Cancels all active cooldown timers and wipes per-entry and per-unit evidence state.
---Called on PLAYER_ENTERING_WORLD (arena exit) and PVP_MATCH_STATE_CHANGED/StartUp (new match).
local function ClearAllCooldownState()
	for k in pairs(lastCastTime)           do lastCastTime[k]           = nil end
	for k in pairs(lastShieldTime)         do lastShieldTime[k]         = nil end
	for k in pairs(lastDebuffTime)         do lastDebuffTime[k]         = nil end
	for k in pairs(lastUnitFlagsTime)      do lastUnitFlagsTime[k]      = nil end
	sd:ResetAll()
	for _, entry in pairs(watchEntries) do
		for _, cd in pairs(entry.ActiveCooldowns) do
			if cd.CleanupTimer then cd.CleanupTimer:Cancel() end
			if cd.UsedCharges then
				for _, uc in ipairs(cd.UsedCharges) do
					if uc.Timer then uc.Timer:Cancel() end
				end
			end
		end
		entry.ActiveCooldowns = {}
		entry.TrackedAuras    = {}
		display:UpdateDisplay(entry)
	end
end

-- Module interface

function M:Refresh()
	local options = GetOptions()
	if not options then
		return
	end

	-- In test mode, simulate arena: respect options.Enabled.Arena so the checkbox works.
	local moduleEnabled = testModeActive
		and (options.Enabled and options.Enabled.Arena)
		or moduleUtil:IsModuleEnabled(moduleName.EnemyCooldownTracker)

	if not moduleEnabled then
		DisableAll()
		return
	end

	EnsureAllEntries()
	EnableAll()

	local size = tonumber(options.Icons.Size) or 24
	local spacing = options.IconSpacing or 2

	local prevEntry
	for i, unit in ipairs(arenaUnits) do
		local entry = watchEntries[unit]
		if entry then
			entry.Container:SetIconSize(size)
			entry.Container:SetCount(20)
			entry.Container:SetSpacing(spacing)
			display:AnchorContainer(entry, i, prevEntry)
			prevEntry = entry
		end
	end

	ShowHideAllEntries()

	-- Drag state: arena1 is the drag handle in Linear mode, writing to options.Linear.
	-- Guarded with IsMovable() to avoid the expensive EnableMouse rebuild on every Refresh.
	local entry1 = watchEntries["arena1"]
	if entry1 then
		local canDrag = testModeActive and options.DisplayMode == "Linear"
		if entry1.Container.Frame:IsMovable() ~= canDrag then
			local frame = entry1.Container.Frame
			frame:SetMovable(canDrag)
			frame:SetClampedToScreen(canDrag)
			frame:EnableMouse(canDrag)
		end
	end
end

function M:RefreshDisplays()
	for _, entry in pairs(watchEntries) do
		TriggerDisplayUpdate(entry)
	end
end

function M:StartTesting()
	testModeActive = true
	observer:SetTestMode(true)
	display:SetTestMode(true)
	EnsureAllEntries()
	M:Refresh()
end

function M:StopTesting()
	testModeActive = false
	observer:SetTestMode(false)
	display:SetTestMode(false)
	for _, entry in pairs(watchEntries) do
		entry.Container:ResetAllSlots()
	end
	M:Refresh()
end

function M:Init()
	db = mini:GetSavedVars()
	display:Init()

	-- Wire Observer callbacks into our brain logic.
	observer:RegisterAuraChangedCallback(function(entry, watcher)
		OnWatcherChanged(entry, watcher)
	end)
	observer:RegisterCastCallback(function(unit)
		lastCastTime[unit] = GetTime()
	end)
	observer:RegisterUnitFlagsCallback(function(unit)
		local now = GetTime()
		lastUnitFlagsTime[unit] = now
		sd:OnUnitFlags(unit, now)
	end)
	observer:RegisterModelChangedCallback(function(unit)
		sd:OnModelChanged(unit, GetTime())
	end)
	observer:RegisterPortraitUpdateCallback(function(unit)
		sd:OnPortraitUpdate(unit, GetTime())
	end)
	observer:RegisterChannelStartCallback(function(unit)
		sd:OnChannelStart(unit, GetTime())
	end)
	observer:RegisterChannelStopCallback(function(unit)
		sd:OnChannelStop(unit, GetTime())
	end)
	observer:RegisterDebuffEvidenceCallback(function(unit, updateInfo)
		if updateInfo and not updateInfo.isFullUpdate and updateInfo.addedAuras then
			for _, aura in ipairs(updateInfo.addedAuras) do
				if
					aura.auraInstanceID
					and not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, aura.auraInstanceID, "HARMFUL")
				then
					lastDebuffTime[unit] = GetTime()
					break
				end
			end
		end
	end)

	-- Track absorb changes on enemy units as Shield evidence (e.g. AMS on a DK, Divine Protection).
	-- Registered globally (same approach as FriendlyCooldowns Observer) because UNIT_ABSORB_AMOUNT_CHANGED
	-- fires per-unit but only as a global event - the unit is passed as the first argument.
	local absorbFrame = CreateFrame("Frame")
	absorbFrame:SetScript("OnEvent", function(_, _, unit)
		if watchEntries[unit] then
			lastShieldTime[unit] = GetTime()
		end
	end)
	absorbFrame:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event)
		if event == "ARENA_PREP_OPPONENT_SPECIALIZATIONS"
		   or event == "ARENA_OPPONENT_UPDATE"
		   or event == "GROUP_ROSTER_UPDATE"
		then
			C_Timer.After(0, function()
				M:Refresh()
			end)
		elseif event == "PVP_MATCH_STATE_CHANGED" then
			-- StartUp is the prep room; suppress cooldown prediction while in it (auras are still
			-- tracked) so pre-existing enemy buffs don't falsely trigger. Cleared once the gates open.
			inPrepRoom = C_PvP.GetActiveMatchState() == Enum.PvPMatchState.StartUp
			if inPrepRoom then
				-- Arena match is starting: clear all tracked state so the previous match's
				-- cooldowns don't bleed into the new one.
				ClearAllCooldownState()
				-- Then refresh so the prep-room icons are shown using the now-available opponent
				-- spec data, rather than only once the gates open.
				C_Timer.After(0, function() M:Refresh() end)
			end
		elseif event == "PLAYER_ENTERING_WORLD" then
			-- Fired after every loading screen, including when leaving an arena.
			-- Ensures stale cooldowns from the previous match are cleared before
			-- the next arena begins (PVP_MATCH_STATE_CHANGED/StartUp also fires,
			-- but PLAYER_ENTERING_WORLD covers the case where a match ends without
			-- a new StartUp following immediately).
			inPrepRoom = C_PvP.GetActiveMatchState() == Enum.PvPMatchState.StartUp
			ClearAllCooldownState()
		end
	end)
	eventsFrame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
	eventsFrame:RegisterEvent("ARENA_OPPONENT_UPDATE")
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

	EventRegistry:RegisterCallback("EditMode.Enter", function()
		editModeActive = true
		for _, entry in pairs(watchEntries) do
			entry.Container.Frame:Hide()
		end
	end)
	EventRegistry:RegisterCallback("EditMode.Exit", function()
		editModeActive = false
		M:Refresh()
	end)

	-- When arena opponent talent data arrives, refresh displays so spec-specific
	-- rule matching and static ability icons use the latest information.
	fcdTalents:RegisterTalentCallback(function()
		M:RefreshDisplays()
	end)

	M:Refresh()
end

-- Type annotations

---@class EcdWatchEntry
---@field Unit            string
---@field Index           number                           1=arena1, 2=arena2, 3=arena3
---@field Container       IconSlotContainer
---@field TrackedAuras    table<number, EcdTrackedAura>   keyed by auraInstanceID
---@field ActiveCooldowns table<number|string, EcdCooldownEntry>

---@class EcdTrackedAura
---@field StartTime        number
---@field AuraTypes        table<string,boolean>
---@field Evidence         EvidenceSet?
---@field DurationObject   table?
---@field CastSnapshot     table<string,number>   snapshot of lastCastTime per arena unit at detection time
---@field PredictedSpellId number?                SpellId committed early via prediction; nil if not yet predicted

---@class EcdCooldownEntry
---@field StartTime   number
---@field Cooldown    number
---@field Remaining   number
---@field SpellId     number?
---@field MaxCharges  number?   effective max charges; nil = single-charge
---@field UsedCharges {Expiry:number, StartTime:number, Timer:table?}[]?  per-charge recharge timers; nil = single-charge
---@field CleanupTimer table?   single-charge cleanup timer; nil for multi-charge entries
