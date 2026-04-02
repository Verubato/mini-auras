---@type string, Addon
local _, addon = ...

-- Loaded before this file in TOC order.
local rules = addon.Modules.FriendlyCooldowns.Rules
local fcdTalents = addon.Modules.FriendlyCooldowns.Talents
local observer = addon.Modules.FriendlyCooldowns.Observer

addon.Modules.FriendlyCooldowns = addon.Modules.FriendlyCooldowns or {}

---@class FriendlyCooldownBrain
local B = {}
addon.Modules.FriendlyCooldowns.Brain = B

-- Seconds of timing tolerance when matching a measured buff duration to a rule.
-- Covers frame-rate jitter, network latency, and slight timestamp rounding.
local tolerance = 0.5
-- Seconds within which a UNIT_SPELLCAST_SUCCEEDED counts as cast evidence, and as a tiebreaker
-- when multiple watched units match the same rule (e.g. two Paladins, both can produce BoP).
-- Must be >= evidenceTolerance so the deferred backfill can still catch late-arriving cast events.
-- Both castWindow and evidenceTolerance are kept equal for this reason.
local castWindow = 0.15
-- How long (seconds) to wait for concurrent evidence after a buff appears.
-- For cross-unit spells (e.g. BoF, BoP), UNIT_SPELLCAST_SUCCEEDED on the caster can arrive
-- after UNIT_AURA on the target by one or more server ticks.
local evidenceTolerance = 0.15
-- unit -> timestamp of most recent HARMFUL aura addition (Forbearance indicates Divine Shield).
local lastDebuffTime = {}
-- unit -> timestamp of most recent absorb change (absorb application indicates Divine Protection).
local lastShieldTime = {}
-- unit -> timestamp of most recent UNIT_SPELLCAST_SUCCEEDED (self-cast evidence e.g. Alter Time).
local lastCastTime = {}
-- unit -> timestamp of most recent UNIT_FLAGS (unit combat/immune flags changed e.g. Aspect of the Turtle).
local lastUnitFlagsTime = {}
-- unit -> timestamp of most recent feign death activation (UnitIsFeignDeath transition false->true).
local lastFeignDeathTime = {}
-- unit -> last known feign death state, used to detect false->true transitions.
local lastFeignDeathState = {}
-- Module-level scratch table reused by FindBestCandidate to avoid per-call allocation.
local candidateEvidenceScratch = {}
-- unit -> boolean: whether the unit's class can feign death (Hunter only).
-- Populated lazily in RecordUnitFlagsChange so UnitIsFeignDeath is never called for units
-- that cannot feign, avoiding a pointless API call on every UNIT_FLAGS event in a raid.
local unitCanFeign = {}
-- Callback fired when a buff ends and a matching rule is found.
-- Signature: fn(ruleUnit, cdKey, cdData, detectedFromEntry)
-- cdData fields: StartTime, Cooldown, Remaining, SpellId, IsOffensive
local cooldownCallback = nil
-- Callback fired when a tracked defensive aura ends and a cooldown is committed,
-- so the detected entry's display (which may differ from the caster's entry) can update.
-- Signature: fn(entry)
local displayCallback = nil

---@class EvidenceSet
---@field Debuff     boolean?  a HARMFUL aura appeared near detectionTime (e.g. Forbearance from Divine Shield)
---@field Shield     boolean?  an absorb change appeared near detectionTime (e.g. Divine Protection)
---@field UnitFlags  boolean?  unit combat/immune flags changed near detectionTime (e.g. Aspect of the Turtle); suppressed when FeignDeath is the source
---@field FeignDeath boolean?  unit entered feign death near detectionTime; mutually exclusive with UnitFlags to prevent false AoT matches
---@field Cast       boolean?  the unit cast a spell near detectionTime

---Collects all concurrent evidence types for a unit near detectionTime.
---Returns an EvidenceSet or nil if no evidence was found.
---Multiple types can be present simultaneously when several events fire in the same window;
---callers check for specific keys rather than comparing a single string.
---@param unit string
---@param detectionTime number
---@return EvidenceSet?
local function BuildEvidenceSet(unit, detectionTime)
	---@type EvidenceSet?
	local ev = nil
	if lastDebuffTime[unit] and math.abs(lastDebuffTime[unit] - detectionTime) <= evidenceTolerance then
		ev = ev or {}
		ev.Debuff = true
	end
	if lastShieldTime[unit] and math.abs(lastShieldTime[unit] - detectionTime) <= evidenceTolerance then
		ev = ev or {}
		ev.Shield = true
	end
	-- FeignDeath and UnitFlags are mutually exclusive: if feign death is the source of the flags
	-- change, UnitFlags is suppressed to prevent false Aspect of the Turtle detections.
	if lastFeignDeathTime[unit] and math.abs(lastFeignDeathTime[unit] - detectionTime) <= castWindow then
		ev = ev or {}
		ev.FeignDeath = true
	elseif lastUnitFlagsTime[unit] and math.abs(lastUnitFlagsTime[unit] - detectionTime) <= castWindow then
		ev = ev or {}
		ev.UnitFlags = true
	end
	if lastCastTime[unit] and math.abs(lastCastTime[unit] - detectionTime) <= castWindow then
		ev = ev or {}
		ev.Cast = true
	end
	return ev
end

local function AuraTypesSignature(auraTypes)
	local s = ""
	if auraTypes["BIG_DEFENSIVE"] then
		s = s .. "B"
	end
	if auraTypes["EXTERNAL_DEFENSIVE"] then
		s = s .. "E"
	end
	if auraTypes["IMPORTANT"] then
		s = s .. "I"
	end
	return s
end

---Returns true if every defined flag on the rule matches the aura's type set.
--- true  -> type must be present
--- false -> type must be absent
--- nil   -> type is unconstrained
---@param auraTypes table<string,boolean>
local function AuraTypeMatchesRule(auraTypes, rule)
	if rule.BigDefensive == true and not auraTypes["BIG_DEFENSIVE"] then
		return false
	end
	if rule.BigDefensive == false and auraTypes["BIG_DEFENSIVE"] then
		return false
	end
	if rule.ExternalDefensive == true and not auraTypes["EXTERNAL_DEFENSIVE"] then
		return false
	end
	if rule.ExternalDefensive == false and auraTypes["EXTERNAL_DEFENSIVE"] then
		return false
	end
	if rule.Important == true and not auraTypes["IMPORTANT"] then
		return false
	end
	return true
end

---Returns true if evidence satisfies a RequiresEvidence value.
---  nil         -> no constraint (always ok)
---  false       -> requires no evidence present
---  string      -> that key must be present in evidence
---  string[]    -> ALL listed keys must be present in evidence
---@param req any
---@param evidence EvidenceSet?
---@return boolean
local function EvidenceMatchesReq(req, evidence)
	if req == nil then
		return true
	end
	if req == false then
		return not evidence or not next(evidence)
	end
	if type(req) == "string" then
		return evidence ~= nil and evidence[req] == true
	end
	if type(req) == "table" then
		if not evidence then
			return false
		end
		for _, k in ipairs(req) do
			if not evidence[k] then
				return false
			end
		end
		return true
	end
	return false
end

---Finds the first rule matching the aura type and measured duration.
---Tries spec-level rules first for precision, falls back to class-level rules.
---@param unit string   caster unit for EXTERNAL_DEFENSIVE, recipient unit for BIG_DEFENSIVE/IMPORTANT
---@param auraTypes table<string,boolean>
---@param measuredDuration number
---@param context MatchRuleContext?
---@return table?
local function MatchRule(unit, auraTypes, measuredDuration, context)
	local _, classToken = UnitClass(unit)
	if not classToken then
		return nil
	end

	local specId = fcdTalents:GetUnitSpecId(unit)
	local evidence = context and context.Evidence
	local activeCooldowns = context and context.ActiveCooldowns

	local function tryRuleList(ruleList)
		if not ruleList then
			return nil
		end
		local fallback = nil
		for _, rule in ipairs(ruleList) do
			local excluded = rule.ExcludeIfTalent and fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
			local required = rule.RequiresTalent and not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
			if not excluded and not required then
				local expectedDuration = rule.SpellId
						and fcdTalents:GetUnitBuffDuration(unit, specId, classToken, rule.SpellId, rule.BuffDuration)
					or rule.BuffDuration
				local typeMatch = AuraTypeMatchesRule(auraTypes, rule)
				if typeMatch then
					local req = rule.RequiresEvidence
					local evidenceOk = EvidenceMatchesReq(req, evidence)
					if evidenceOk then
						local durationOk
						if rule.MinDuration then
							durationOk = measuredDuration >= expectedDuration - tolerance
						elseif rule.CanCancelEarly == true then
							durationOk = measuredDuration <= expectedDuration + tolerance
						else
							durationOk = math.abs(measuredDuration - expectedDuration) <= tolerance
						end
						if durationOk then
							local alreadyOnCd = activeCooldowns and rule.SpellId and activeCooldowns[rule.SpellId]
							if not alreadyOnCd then
								return rule
							elseif not fallback then
								fallback = rule
							end
						end
					end
				end
			end
		end
		return fallback
	end

	-- Spec rules take priority; fall through to class rules if no match.
	return tryRuleList(specId and rules.BySpec[specId]) or tryRuleList(rules.ByClass[classToken])
end

---Evaluates all candidate units and returns the best-matching rule and caster unit.
---candidateUnits is supplied by Observer from its internal watched-entry map so Brain
---has no direct dependency on Module.
---Primary tiebreaker: most recent cast evidence wins (distinguishes caster from recipient).
---Secondary tiebreaker: for EXTERNAL_DEFENSIVE, a non-target is preferred when neither has cast evidence.
---@param candidateUnits string[]  list of unit strings from all active watch entries
---@return table? rule
---@return string ruleUnit
local function FindBestCandidate(entry, tracked, measuredDuration, candidateUnits)
	local rule = nil
	local ruleUnit = entry.Unit
	local bestTime = nil
	local isExternal = tracked.AuraTypes["EXTERNAL_DEFENSIVE"]

	local function consider(candidate, isTarget)
		-- Build candidate-specific evidence into the scratch table: share Debuff/Shield/UnitFlags
		-- from the aura's evidence, but only add Cast if THIS candidate has a CastSnapshot entry —
		-- so a cast by unit A cannot satisfy RequiresEvidence="Cast" when evaluating unit B.
		local scratch = candidateEvidenceScratch
		scratch.Debuff = nil
		scratch.Shield = nil
		scratch.UnitFlags = nil
		scratch.FeignDeath = nil
		scratch.Cast = nil
		local hasEvidence = false
		if tracked.Evidence then
			for k, v in pairs(tracked.Evidence) do
				if k ~= "Cast" then
					scratch[k] = v
					hasEvidence = true
				end
			end
		end
		local castTime = tracked.CastSnapshot[candidate]
		if castTime and math.abs(castTime - tracked.StartTime) <= castWindow then
			scratch.Cast = true
			hasEvidence = true
		end
		local candidateEvidence = hasEvidence and scratch or nil
		local candidateRule = MatchRule(
			candidate,
			tracked.AuraTypes,
			measuredDuration,
			{ Evidence = candidateEvidence, ActiveCooldowns = entry.ActiveCooldowns }
		)
		if not candidateRule then
			return
		end
		local isBetter = not rule
			or (castTime and (not bestTime or castTime > bestTime))
			or (not castTime and not bestTime and isExternal and not isTarget)
		if isBetter then
			rule, ruleUnit, bestTime = candidateRule, candidate, castTime
		end
	end

	consider(entry.Unit, true)
	for _, unit in ipairs(candidateUnits) do
		if unit ~= entry.Unit then
			consider(unit, false)
		end
	end

	return rule, ruleUnit
end

---Fires the cooldown callback so Module can store the cooldown and update all affected entries.
local function CommitCooldown(entry, tracked, rule, ruleUnit, measuredDuration)
	if not cooldownCallback then
		return
	end

	-- Apply talent-based cooldown reduction.
	local cooldown = rule.Cooldown
	if rule.SpellId then
		local specId = fcdTalents:GetUnitSpecId(ruleUnit)
		local _, classToken = UnitClass(ruleUnit)
		if classToken then
			cooldown =
				fcdTalents:GetUnitCooldown(ruleUnit, specId, classToken, rule.SpellId, cooldown, measuredDuration)
		end
	end

	local auraTypesKey = tracked.AuraTypes["BIG_DEFENSIVE"] and "BIG_DEFENSIVE"
		or tracked.AuraTypes["EXTERNAL_DEFENSIVE"] and "EXTERNAL_DEFENSIVE"
		or "IMPORTANT"
	local cdKey = rule.SpellId or (auraTypesKey .. "_" .. rule.BuffDuration .. "_" .. rule.Cooldown)
	local cdData = {
		StartTime = tracked.StartTime,
		Cooldown = cooldown,
		Remaining = cooldown - measuredDuration,
		SpellId = tracked.SpellId,
		IsOffensive = rule.SpellId ~= nil and rules.OffensiveSpellIds[rule.SpellId] == true,
	}

	cooldownCallback(ruleUnit, cdKey, cdData, entry)
end

---Called when a tracked aura instance disappears.
---Measures elapsed time and starts a cooldown entry if a rule matches.
---@param entry FcdWatchEntry
---@param tracked FcdTrackedAura
---@param now number
---@param candidateUnits string[]
---Returns true if a cooldown was committed, false if no rule matched.
local function OnAuraRemoved(entry, tracked, now, candidateUnits)
	local measuredDuration = now - tracked.StartTime
	local rule, ruleUnit = FindBestCandidate(entry, tracked, measuredDuration, candidateUnits)

	if not rule then
		return false
	end

	CommitCooldown(entry, tracked, rule, ruleUnit, measuredDuration)
	return true
end

---Builds a table of current aura instance IDs → { AuraTypes } from the watcher.
---GetDefensiveState doesn't expose which filter each aura came from, so each aura is
---re-checked via IsAuraFilteredOutByInstanceID to classify EXTERNAL_DEFENSIVE vs BIG_DEFENSIVE.
local function BuildCurrentAuraIds(unit, watcher)
	local currentIds = {}
	for _, aura in ipairs(watcher:GetDefensiveState()) do
		local id = aura.AuraInstanceID
		if id then
			local isExt = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|EXTERNAL_DEFENSIVE")
			local isImportant = not C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, id, "HELPFUL|IMPORTANT")
			local auraType = isExt and "EXTERNAL_DEFENSIVE" or "BIG_DEFENSIVE"
			local auraTypes = { [auraType] = true }
			if isImportant then
				auraTypes["IMPORTANT"] = true
			end
			currentIds[id] = { AuraTypes = auraTypes }
		end
	end
	-- Auras already added from GetDefensiveState are excluded from GetImportantState by the
	-- watcher's seen-set; IMPORTANT was already probed above via IsAuraFilteredOutByInstanceID.
	for _, aura in ipairs(watcher:GetImportantState()) do
		local id = aura.AuraInstanceID
		if id then
			if currentIds[id] then
				currentIds[id].AuraTypes["IMPORTANT"] = true
			else
				currentIds[id] = { AuraTypes = { IMPORTANT = true } }
			end
		end
	end
	return currentIds
end

---Begins tracking a newly detected aura: records evidence and a cast snapshot,
---then schedules a deferred backfill for events that may arrive after UNIT_AURA.
local function TrackNewAura(unit, trackedAuras, id, info, now)
	-- Collect concurrent Debuff/Shield/UnitFlags evidence (HARMFUL auras fire in the same
	-- UNIT_AURA batch). Cast evidence is intentionally excluded here — it is derived
	-- per-candidate from CastSnapshot in OnAuraRemoved so a cast by unit A cannot satisfy
	-- RequiresEvidence="Cast" when evaluating unit B.
	local evidence = BuildEvidenceSet(unit, now)

	-- Snapshot cast times so OnAuraRemoved can attribute the cooldown to the correct
	-- caster even after lastCastTime has been overwritten by subsequent casts.
	local castSnapshot = {}
	for snapshotUnit, snapshotTime in pairs(lastCastTime) do
		castSnapshot[snapshotUnit] = snapshotTime
	end

	trackedAuras[id] = {
		StartTime = now,
		AuraTypes = info.AuraTypes,
		Evidence = evidence,
		CastSnapshot = castSnapshot,
	}

	-- Deferred backfill: UNIT_SPELLCAST_SUCCEEDED and UNIT_ABSORB_AMOUNT_CHANGED can arrive
	-- slightly after UNIT_AURA. Augment Evidence and CastSnapshot once the window elapses.
	C_Timer.After(evidenceTolerance, function()
		local tracked = trackedAuras[id]
		if not tracked then
			return
		end
		local ev = BuildEvidenceSet(unit, now)
		if ev then
			tracked.Evidence = tracked.Evidence or {}
			for k in pairs(ev) do
				tracked.Evidence[k] = true
			end
		end
		-- Backfill casters whose UNIT_SPELLCAST_SUCCEEDED arrived after UNIT_AURA.
		-- Guard with castWindow to avoid picking up unrelated later casts.
		for snapshotUnit, snapshotTime in pairs(lastCastTime) do
			if math.abs(snapshotTime - now) <= castWindow and not tracked.CastSnapshot[snapshotUnit] then
				tracked.CastSnapshot[snapshotUnit] = snapshotTime
			end
		end
	end)
end

---Processes a watcher state change for an entry. Called via the Observer's aura-changed callback.
---entry.IsExcludedSelf: set by Module; when true, bypasses the container-visibility guard so
---  externals cast by the player are still captured even though the container is hidden.
---candidateUnits: supplied by Observer from its internal watched-entry map.
---@param entry FcdWatchEntry
---@param watcher Watcher
---@param candidateUnits string[]
local function OnWatcherChanged(entry, watcher, candidateUnits)
	if not entry.IsExcludedSelf and not entry.Container.Frame:IsVisible() then
		return
	end

	local now = GetTime()
	local trackedAuras = entry.TrackedAuras
	local currentIds = BuildCurrentAuraIds(entry.Unit, watcher)

	-- Collect new IDs (present in currentIds but not yet tracked) for heuristic reconciliation.
	-- On full updates the server reassigns aura instance IDs, so a tracked ID disappearing does
	-- not necessarily mean the buff dropped. We match orphaned entries to new IDs by AuraTypes
	-- signature — the only non-secret identity information available to us.
	local unmatchedNewIds = {}
	for id in pairs(currentIds) do
		if not trackedAuras[id] then
			unmatchedNewIds[#unmatchedNewIds + 1] = id
		end
	end

	-- Group unmatched new IDs by their AuraTypes signature.
	local newIdsBySignature = {}
	for _, id in ipairs(unmatchedNewIds) do
		local sig = AuraTypesSignature(currentIds[id].AuraTypes)
		newIdsBySignature[sig] = newIdsBySignature[sig] or {}
		newIdsBySignature[sig][#newIdsBySignature[sig] + 1] = id
	end

	local cooldownCommitted = false
	for id, tracked in pairs(trackedAuras) do
		if not currentIds[id] then
			local sig = AuraTypesSignature(tracked.AuraTypes)
			local candidates = newIdsBySignature[sig]
			if candidates and #candidates > 0 then
				-- Carry tracking forward under the new instance ID.
				local reassignedId = table.remove(candidates, 1)
				trackedAuras[reassignedId] = tracked
			else
				if OnAuraRemoved(entry, tracked, now, candidateUnits) then
					cooldownCommitted = true
				end
			end
			trackedAuras[id] = nil
		end
	end

	for id, info in pairs(currentIds) do
		if not trackedAuras[id] then
			TrackNewAura(entry.Unit, trackedAuras, id, info, now)
		end
	end

	-- Only update the detected entry's display when a cooldown was actually committed.
	-- The caster entry is updated immediately in the cooldownCallback; this covers the
	-- case where the detected entry differs from the caster entry (e.g. external defensives).
	if displayCallback and cooldownCommitted then
		displayCallback(entry)
	end
end

local function RecordCast(unit)
	local now = GetTime()
	if lastCastTime[unit] ~= now then
		lastCastTime[unit] = now
	end
end

local function RecordShield(unit)
	lastShieldTime[unit] = GetTime()
end

local function RecordUnitFlagsChange(unit)
	local now = GetTime()
	-- Populate canFeign lazily: only Hunters can feign death, so skip UnitIsFeignDeath for
	-- every other class. UNIT_FLAGS fires frequently in raids for mundane combat-state changes
	-- and calling UnitIsFeignDeath for 19 non-Hunter players on each event is wasted work.
	local canFeign = unitCanFeign[unit]
	if canFeign == nil then
		local _, classToken = UnitClass(unit)
		canFeign = classToken == "HUNTER"
		unitCanFeign[unit] = canFeign
	end
	local isFeign = canFeign and UnitIsFeignDeath(unit) or false
	if isFeign and not lastFeignDeathState[unit] then
		lastFeignDeathTime[unit] = now
	end
	lastFeignDeathState[unit] = isFeign
	if not isFeign then
		lastUnitFlagsTime[unit] = now
	end
end

local function TryRecordDebuffEvidence(unit, updateInfo)
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
end

---Registers the callback fired when a buff ends and a cooldown rule is matched.
---fn(ruleUnit, cdKey, cdData, detectedFromEntry)
---cdData: { StartTime, Cooldown, Remaining, SpellId, IsOffensive }
---@param fn fun(ruleUnit: string, cdKey: number|string, cdData: table, detectedFromEntry: FcdWatchEntry)
function B:RegisterCooldownCallback(fn)
	cooldownCallback = fn
end

---Registers the callback fired when the display should update after a watcher pass.
---fn(entry)
---@param fn fun(entry: FcdWatchEntry)
function B:RegisterDisplayCallback(fn)
	displayCallback = fn
end

-- Brain registers with Observer at file-load time; no explicit Init needed.
observer:RegisterAuraChangedCallback(function(entry, watcher, candidateUnits)
	OnWatcherChanged(entry, watcher, candidateUnits)
end)
observer:RegisterCastCallback(RecordCast)
observer:RegisterShieldCallback(RecordShield)
observer:RegisterUnitFlagsCallback(RecordUnitFlagsChange)
observer:RegisterDebuffEvidenceCallback(TryRecordDebuffEvidence)
