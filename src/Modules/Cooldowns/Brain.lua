---@type string, Addon
local _, addon = ...

-- Loaded before this file in TOC order.
local rules = addon.Modules.Cooldowns.Rules
local fcdTalents = addon.Modules.Cooldowns.Talents

addon.Modules.Cooldowns = addon.Modules.Cooldowns or {}

---@class CooldownBrain
local B = {}
addon.Modules.Cooldowns.Brain = B

-- In patch 12.0.5 (TOC 120005), UNIT_SPELLCAST_SUCCEEDED no longer fires for other players,
-- so cast evidence can never be populated for teammates. When running on that build or later,
-- RequiresEvidence="Cast" and mixed requirements including "Cast" are treated as satisfied.
-- When true, simulates patch 12.0.5 behaviour where UNIT_SPELLCAST_SUCCEEDED no longer fires
-- for other players. Two consequences:
--   1. RecordCast is a no-op for non-local units, so CastSnapshot and lastCastTime stay empty
--      for everyone except "player" (whose events still fire and are recorded as normal).
--   2. In FindBestCandidate and PredictRule, non-local candidates receive synthetic Cast=true
--      evidence (benefit of the doubt), while "player" uses real snapshot data — so if the
--      local player did NOT cast, they are correctly excluded as a candidate.
local simulateNoCastSucceeded = select(4, GetBuildInfo()) >= 120005

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
-- unit -> list of { SpellId, Time } for recent non-secret cast spell IDs within castWindow.
-- Stored as a list because a single keypress can fire multiple UNIT_SPELLCAST_SUCCEEDED events
-- (e.g. Desperate Prayer triggers procs or follow-up spells), and we must check all of them.
-- Only populated for the local player (UNIT_SPELLCAST_SUCCEEDED provides non-secret IDs locally).
local lastCastSpellIds = {}
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
-- Callback fired when a new non-external aura is detected and a predictive spell match is found.
-- Signature: fn(entry, spellId)
local predictiveGlowCallback = nil
-- Callback fired when a predictively-matched aura is removed.
-- Signature: fn(entry, spellId)
local predictiveGlowEndCallback = nil
-- Lookup function returning a unit's ActiveCooldowns table, or nil if the unit is not watched.
-- Registered by Module so Brain has no direct dependency on Module.
-- Signature: fn(unit) -> table?
local activeCooldownsLookup = nil
-- Callback fired when an active predicted-glow aura's duration changes (e.g. Combustion extended
-- by a talent proc, Avatar extended by a proc).  Lets Module refresh PredictedGlowDurations.
-- Signature: fn(entry, spellId, casterUnit, durationObject)
local predictiveGlowDurationChangedCallback = nil

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

---Finds the first rule for the given spellId that passes talent checks and aura type constraints.
---Used by the cast-spell-ID fast path in both MatchRule and PredictRule: having a non-secret
---spell ID from UNIT_SPELLCAST_SUCCEEDED means duration and evidence checks can be skipped.
---Returns the matching rule, or nil if none is found.
---@param unit string
---@param specId number?
---@param auraTypes table<string,boolean>
---@param spellId number
---@return table?
local function FindRuleBySpellId(unit, specId, auraTypes, spellId)
	local _, classToken = UnitClass(unit)
	if not classToken then return nil end

	local function checkList(ruleList)
		if not ruleList then return nil end
		for _, rule in ipairs(ruleList) do
			if rule.SpellId == spellId then
				local excluded = false
				if rule.ExcludeIfTalent then
					if type(rule.ExcludeIfTalent) == "table" then
						for _, talentId in ipairs(rule.ExcludeIfTalent) do
							if fcdTalents:UnitHasTalent(unit, talentId, specId) then excluded = true; break end
						end
					else
						excluded = fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
					end
				end
				local required = false
				if rule.RequiresTalent then
					if type(rule.RequiresTalent) == "table" then
						required = true
						for _, talentId in ipairs(rule.RequiresTalent) do
							if fcdTalents:UnitHasTalent(unit, talentId, specId) then required = false; break end
						end
					else
						required = not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
					end
				end
				if not excluded and not required and AuraTypeMatchesRule(auraTypes, rule) then
					return rule
				end
			end
		end
		return nil
	end

	return checkList(specId and rules.BySpec[specId]) or checkList(rules.ByClass[classToken])
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
	-- When the caller has confirmed the aura was actually present (ECD aura-based matching),
	-- talent requirements are redundant — the buff's existence proves the ability was used.
	-- Enemy PvP talent data is never available via PvPTalentSync, so RequiresTalent would
	-- always fail for enemies even when they demonstrably have the talent (e.g. Nether Ward).
	local ignoreTalentReqs = context and context.IgnoreTalentRequirements

	-- Fast path: non-secret spell IDs from UNIT_SPELLCAST_SUCCEEDED skip duration and evidence
	-- checks when an ID matches a tracked rule.  Falls through to normal matching when none match:
	-- MatchRule has MinCancelDuration and duration/evidence guards that correctly reject short proc
	-- buffs, so returning nil here would only create false negatives (e.g. Desperate Prayer).
	-- Multiple IDs are checked because one keypress can fire several UNIT_SPELLCAST_SUCCEEDED events.
	local knownSpellIds = context and context.KnownSpellIds
	if knownSpellIds then
		for _, sid in ipairs(knownSpellIds) do
			local fastRule = FindRuleBySpellId(unit, specId, auraTypes, sid)
			if fastRule then return fastRule end
		end
	end

	local function tryRuleList(ruleList)
		if not ruleList then
			return nil
		end
		local fallback = nil
		for _, rule in ipairs(ruleList) do
			local excluded = false
			if rule.ExcludeIfTalent then
				if type(rule.ExcludeIfTalent) == "table" then
					for _, talentId in ipairs(rule.ExcludeIfTalent) do
						if fcdTalents:UnitHasTalent(unit, talentId, specId) then excluded = true; break end
					end
				else
					excluded = fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
				end
			end
			local required = false
			if not ignoreTalentReqs and rule.RequiresTalent then
				if type(rule.RequiresTalent) == "table" then
					required = true
					for _, talentId in ipairs(rule.RequiresTalent) do
						if fcdTalents:UnitHasTalent(unit, talentId, specId) then required = false; break end
					end
				else
					required = not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
				end
			end
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
								and (not rule.MinCancelDuration or measuredDuration >= rule.MinCancelDuration)
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

---Tries to match auraTypes + evidence against a single unit's rule lists.
---Returns the matched SpellId and whether that spell is currently on cooldown, or nil.
---Stops at the FIRST matching rule (the intended ability) rather than falling through to
---alternatives — a fallback to a different spell would cause false ambiguity in PredictRule
---when compared against other candidates who correctly matched the primary spell.
---@param unit string
---@param auraTypes table<string,boolean>
---@param evidence EvidenceSet?
---@param castableFilter string?  nil = no filter; "only" = only CastableOnOthers rules; "exclude" = exclude CastableOnOthers rules
---@return number? spellId
---@return boolean isOnCooldown
local function PredictSpellIdForUnit(unit, auraTypes, evidence, castableFilter)
	local _, classToken = UnitClass(unit)
	if not classToken then
		return nil
	end

	local specId = fcdTalents:GetUnitSpecId(unit)
	local activeCooldowns = activeCooldownsLookup and activeCooldownsLookup(unit)

	local function tryRuleList(ruleList)
		if not ruleList then
			return nil
		end
		for _, rule in ipairs(ruleList) do
			if rule.SpellId then
				if not (castableFilter == "only" and not rule.CastableOnOthers)
				and not (castableFilter == "exclude" and rule.CastableOnOthers) then
					local excluded = false
					if rule.ExcludeIfTalent then
						if type(rule.ExcludeIfTalent) == "table" then
							for _, talentId in ipairs(rule.ExcludeIfTalent) do
								if fcdTalents:UnitHasTalent(unit, talentId, specId) then excluded = true; break end
							end
						else
							excluded = fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
						end
					end
					local required = false
					if rule.RequiresTalent then
						if type(rule.RequiresTalent) == "table" then
							required = true
							for _, talentId in ipairs(rule.RequiresTalent) do
								if fcdTalents:UnitHasTalent(unit, talentId, specId) then required = false; break end
							end
						else
							required = not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
						end
					end
					if not excluded and not required then
						if AuraTypeMatchesRule(auraTypes, rule) and EvidenceMatchesReq(rule.RequiresEvidence, evidence) then
							-- Return the first match plus its CD state.  Do NOT fall through to
							-- other rules: if this spell is on CD this candidate is ineligible
							-- rather than being attributed to a different spell, which would
							-- produce false ambiguity against candidates who matched correctly.
							return rule.SpellId, activeCooldowns and activeCooldowns[rule.SpellId] ~= nil
						end
					end
				end
			end
		end
		return nil
	end

	-- Spec rules take priority.  Explicit branch rather than `or` so both return values
	-- (spellId, isOnCooldown) are forwarded correctly — `or` only propagates one value.
	local spellId, onCd = tryRuleList(specId and rules.BySpec[specId])
	if spellId ~= nil then
		return spellId, onCd
	end
	return tryRuleList(rules.ByClass[classToken])
end

---Returns the predicted SpellId and caster unit for a newly-detected aura, or nil.
---For non-external auras, matches against the target unit itself (which is the caster).
---For EXTERNAL_DEFENSIVE, searches candidateUnits for a unit with recent cast evidence and a matching rule.
---Returns spellId, casterUnit — casterUnit is nil for self-cast auras (caster == target).
---@param targetUnit string
---@param auraTypes table<string,boolean>
---@param evidence EvidenceSet?
---@param castSnapshot table<string,number>
---@param castSpellIdSnapshot table<string,{SpellId:number,Time:number}>
---@param detectionTime number
---@param candidateUnits string[]
---@return number?, string?
local function PredictRule(targetUnit, auraTypes, evidence, castSnapshot, castSpellIdSnapshot, detectionTime, candidateUnits)
	-- Fast path: UNIT_SPELLCAST_SUCCEEDED provides a non-secret spell ID for the local player.
	-- If the target unit's cast spell ID is known and falls within the detection window, verify
	-- it against talent checks + aura type and return immediately — no ambiguity analysis needed.
	-- This bypasses evidence inference entirely, which is the correct behaviour: having the exact
	-- spell ID is a stronger signal than any combination of indirect evidence types.
	-- Not applicable to EXTERNAL_DEFENSIVE (where the caster is a different unit).
	if not auraTypes["EXTERNAL_DEFENSIVE"] then
		local knownCasts = castSpellIdSnapshot and castSpellIdSnapshot[targetUnit]
		if knownCasts then
			-- Check whether any entry in the list falls within the detection window.
			-- A single keypress can produce multiple UNIT_SPELLCAST_SUCCEEDED events, so the list
			-- may contain several spell IDs; we check all of them before falling through.
			local anyInWindow = false
			for _, knownCast in ipairs(knownCasts) do
				if math.abs(knownCast.Time - detectionTime) <= castWindow then
					anyInWindow = true
					break
				end
			end
			if anyInWindow then
				local specId = fcdTalents:GetUnitSpecId(targetUnit)
				for _, knownCast in ipairs(knownCasts) do
					if math.abs(knownCast.Time - detectionTime) <= castWindow then
						if FindRuleBySpellId(targetUnit, specId, auraTypes, knownCast.SpellId) then
							return knownCast.SpellId, nil
						end
					end
				end
				-- None of the known spell IDs matched a tracked rule.  Don't fall through to
				-- indirect evidence matching: we know what was cast (e.g. Fade -> Phase Shift proc).
				return nil, nil
			end
		end
	end

	local matchSpellId = nil
	local matchCasterUnit = nil
	local matchCastDiff = nil -- absolute cast-time distance for the current best caster
	local ambiguous = false

	-- Evaluates one candidate and records the match (or ambiguity) into the outer locals.
	-- castableFilter: nil = no filter, "only" = CastableOnOthers rules only, "exclude" = exclude them.
	local function consider(candidate, useSnapshot, castableFilter)
		if ambiguous then return end
		local candidateEvidence = evidence
		local castTime = nil
		if useSnapshot then
			castTime = castSnapshot[candidate]
			if not castTime or math.abs(castTime - detectionTime) > castWindow then return end
			candidateEvidence = { Cast = true }
			if evidence then
				for k, v in pairs(evidence) do
					if k ~= "Cast" then candidateEvidence[k] = v end
				end
			end
		end
		-- Synthetic cast evidence is intentionally NOT added here for 12.0.5+ builds.
		-- PredictRule fires while the buff is still active and has no duration guard,
		-- so synthetic Cast would cause false-positive predictions for any candidate
		-- whose class/spec has a matching rule.  FindBestCandidate (the commit path)
		-- retains synthetic cast because it also matches against measured buff duration.
		local spellId, isOnCd = PredictSpellIdForUnit(candidate, auraTypes, candidateEvidence, castableFilter)
		-- nil  -> no rule matched this aura for this candidate at all
		-- true -> rule matched but spell is on CD; candidate is ineligible, not ambiguous
		if not spellId or isOnCd then return end
		if matchSpellId == nil then
			matchSpellId = spellId
			matchCasterUnit = (candidate ~= targetUnit) and candidate or nil
			matchCastDiff = castTime and math.abs(castTime - detectionTime) or nil
		elseif matchSpellId ~= spellId then
			ambiguous = true
		else
			-- Same spell matched by a different candidate.  Prefer whoever's cast was closest
			-- to the moment the buff appeared — disambiguates e.g. two Paladins who both had
			-- recent casts but only one actually pressed BoP.
			local diff = castTime and math.abs(castTime - detectionTime) or nil
			if diff and (not matchCastDiff or diff < matchCastDiff) then
				matchCasterUnit = (candidate ~= targetUnit) and candidate or nil
				matchCastDiff = diff
			end
		end
	end

	if auraTypes["EXTERNAL_DEFENSIVE"] then
		-- Some externals (e.g. Ironbark) can be self-cast; targetUnit is a valid candidate.
		local seen = {}
		for _, candidate in ipairs(candidateUnits) do
			if not seen[candidate] then
				seen[candidate] = true
				consider(candidate, true, nil)
			end
		end
	else
		-- Self-cast path: check what the target unit's own self-only rules match.
		consider(targetUnit, false, "exclude")
		-- Also check whether the target matches a CastableOnOthers rule via cast snapshot.
		-- If so, and the spellId differs, the prediction is ambiguous (e.g. a Paladin self-casting
		-- Blessing of Freedom — we can't distinguish it from Avenging Crusader at detection time).
		consider(targetUnit, true, "only")
		-- Cross-unit path: only CastableOnOthers rules, so self-only spells like Avenging Crusader
		-- are never returned as the caster of a buff on a different unit.
		local seen = { [targetUnit] = true }
		for _, candidate in ipairs(candidateUnits) do
			if not seen[candidate] then
				seen[candidate] = true
				consider(candidate, true, "only")
			end
		end
	end

	if ambiguous then return nil, nil end
	return matchSpellId, matchCasterUnit
end

---Evaluates all candidate units and returns the best-matching rule and caster unit.
---candidateUnits is supplied by Observer from its internal watched-entry map so Brain
---has no direct dependency on Module.
---Primary tiebreaker: most recent cast evidence wins (distinguishes caster from recipient).
---Secondary tiebreaker: for EXTERNAL_DEFENSIVE, a non-target is preferred when neither has cast evidence.
---@param candidateUnits string[]  list of unit strings from all active watch entries
---@return table? rule
---@return string ruleUnit
local function FindBestCandidate(entry, tracked, measuredDuration, candidateUnits, opts)
	local rule = nil
	local ruleUnit = entry.Unit
	local bestTime = nil
	local bestIsTarget = false   -- true when the current best match came from the target unit
	local isExternal = tracked.AuraTypes["EXTERNAL_DEFENSIVE"]
	local ambiguous = false
	local ignoreTalentReqs = opts and opts.IgnoreTalentRequirements

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
		elseif simulateNoCastSucceeded and candidate ~= "player" then
			-- 12.0.5+: UNIT_SPELLCAST_SUCCEEDED no longer fires for other players, so absence
			-- of a cast snapshot is uninformative — give non-local candidates benefit of the doubt.
			-- For "player" we have reliable cast data, so no snapshot means they did NOT cast
			-- and will correctly fail RequiresEvidence="Cast", excluding them as a candidate.
			scratch.Cast = true
			hasEvidence = true
		end
		local candidateEvidence = hasEvidence and scratch or nil
		-- Extract non-secret spell IDs for this candidate if any were snapshotted within the cast window.
		local castSpellDataList = tracked.CastSpellIdSnapshot and tracked.CastSpellIdSnapshot[candidate]
		local knownSpellIds = nil
		if castSpellDataList then
			for _, data in ipairs(castSpellDataList) do
				if math.abs(data.Time - tracked.StartTime) <= castWindow then
					knownSpellIds = knownSpellIds or {}
					knownSpellIds[#knownSpellIds + 1] = data.SpellId
				end
			end
		end
		local candidateRule = MatchRule(
			candidate,
			tracked.AuraTypes,
			measuredDuration,
			{ Evidence = candidateEvidence, ActiveCooldowns = entry.ActiveCooldowns, KnownSpellIds = knownSpellIds, IgnoreTalentRequirements = ignoreTalentReqs }
		)
		if not candidateRule then
			return
		end
		local isBetter = not rule
			or (castTime and (not bestTime or castTime > bestTime))
			or (not castTime and not bestTime and isExternal and not isTarget and bestIsTarget and candidateRule == rule)
		if isBetter then
			rule, ruleUnit, bestTime, bestIsTarget = candidateRule, candidate, castTime, isTarget
		elseif not castTime and not bestTime then
			-- A second candidate also qualifies, but neither this candidate nor the current
			-- winner has real cast evidence to break the tie — the match is ambiguous.
			ambiguous = true
		end
	end

	consider(entry.Unit, true)
	-- On 12.0.5+ UNIT_SPELLCAST_SUCCEEDED no longer fires for other players, so all
	-- non-local candidates receive synthetic Cast evidence.  For BIG_DEFENSIVE and IMPORTANT
	-- auras (always self-cast), that causes false ambiguity when multiple same-class players
	-- are in the group (e.g. two Druids both matching Barkskin).  Restrict candidate search
	-- to EXTERNAL_DEFENSIVE auras where the caster genuinely differs from the target.
	-- On earlier builds real cast snapshots disambiguate correctly, so the full loop runs.
	if isExternal or not simulateNoCastSucceeded then
		for _, unit in ipairs(candidateUnits) do
			if unit ~= entry.Unit then
				consider(unit, false)
			end
		end
	end

	if ambiguous then return nil, nil end
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

---Builds a table of current aura instance IDs -> { AuraTypes } from the watcher.
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
			currentIds[id] = { AuraTypes = auraTypes, DurationObject = aura.DurationObject }
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
				currentIds[id] = { AuraTypes = { IMPORTANT = true }, DurationObject = aura.DurationObject }
			end
		end
	end
	return currentIds
end

---Begins tracking a newly detected aura: records evidence and a cast snapshot,
---then schedules a deferred backfill for events that may arrive after UNIT_AURA.
local function TrackNewAura(entry, trackedAuras, id, info, now, candidateUnits)
	local unit = entry.Unit

	-- candidateUnits is a shared scratch table in Observer that is reused on every aura event.
	-- Copy it now so the deferred timer closure has a stable snapshot of the current candidates.
	local candidatesCopy = {}
	for i = 1, #candidateUnits do
		candidatesCopy[i] = candidateUnits[i]
	end
	candidateUnits = candidatesCopy

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

	-- Snapshot non-secret cast spell IDs (local player only).  Used by PredictRule as a
	-- definitive signal when the player's own UNIT_SPELLCAST_SUCCEEDED is available.
	-- Stored as a list per unit so all events from a single keypress are captured.
	local castSpellIdSnapshot = {}
	for snapshotUnit, list in pairs(lastCastSpellIds) do
		local filtered = {}
		for _, data in ipairs(list) do
			if math.abs(data.Time - now) <= castWindow then
				filtered[#filtered + 1] = data
			end
		end
		if #filtered > 0 then
			castSpellIdSnapshot[snapshotUnit] = filtered
		end
	end

	trackedAuras[id] = {
		StartTime = now,
		AuraTypes = info.AuraTypes,
		Evidence = evidence,
		CastSnapshot = castSnapshot,
		CastSpellIdSnapshot = castSpellIdSnapshot,
		DurationObject = info.DurationObject,
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
		-- Backfill non-secret cast spell IDs that arrived after UNIT_AURA.
		for snapshotUnit, list in pairs(lastCastSpellIds) do
			for _, data in ipairs(list) do
				if math.abs(data.Time - now) <= castWindow then
					local existing = tracked.CastSpellIdSnapshot[snapshotUnit]
					if not existing then
						tracked.CastSpellIdSnapshot[snapshotUnit] = { data }
					else
						local found = false
						for _, e in ipairs(existing) do
							if e.SpellId == data.SpellId and e.Time == data.Time then found = true; break end
						end
						if not found then existing[#existing + 1] = data end
					end
				end
			end
		end

		-- Predictive glow: identify the spell by aura type + talent + evidence.
		-- For EXTERNAL_DEFENSIVE, searches candidateUnits for the caster via cast snapshot.
		if predictiveGlowCallback and not tracked.PredictedSpellId then
			local spellId, casterUnit = PredictRule(unit, info.AuraTypes, tracked.Evidence, tracked.CastSnapshot, tracked.CastSpellIdSnapshot, now, candidateUnits)
			if spellId then
				tracked.PredictedSpellId = spellId
				tracked.PredictedCasterUnit = casterUnit
				predictiveGlowCallback(entry, spellId, casterUnit, tracked.DurationObject)
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
				-- Fire glow-end before OnAuraRemoved so that when UpdateDisplay runs the glow is already cleared.
				if tracked.PredictedSpellId and predictiveGlowEndCallback then
					predictiveGlowEndCallback(entry, tracked.PredictedSpellId, tracked.PredictedCasterUnit)
				end
				if OnAuraRemoved(entry, tracked, now, candidateUnits) then
					cooldownCommitted = true
				end
			end
			trackedAuras[id] = nil
		elseif tracked.PredictedSpellId and predictiveGlowDurationChangedCallback then
			-- Aura is still active: refresh DurationObject so the glow icon tracks any
			-- duration extensions (e.g. Combustion extended by talents, Avatar by procs).
			local newDuration = currentIds[id].DurationObject
			if newDuration then
				tracked.DurationObject = newDuration
				predictiveGlowDurationChangedCallback(entry, tracked.PredictedSpellId, tracked.PredictedCasterUnit, newDuration)
			end
		end
	end

	for id, info in pairs(currentIds) do
		if not trackedAuras[id] then
			TrackNewAura(entry, trackedAuras, id, info, now, candidateUnits)
		end
	end

	-- Only update the detected entry's display when a cooldown was actually committed.
	-- The caster entry is updated immediately in the cooldownCallback; this covers the
	-- case where the detected entry differs from the caster entry (e.g. external defensives).
	if displayCallback and cooldownCommitted then
		displayCallback(entry)
	end
end

local function RecordCast(unit, spellId)
	if simulateNoCastSucceeded and unit ~= "player" then return end
	local now = GetTime()
	if lastCastTime[unit] ~= now then
		lastCastTime[unit] = now
	end
	-- Store the spell ID only when non-secret (i.e. the local player).  Remote players'
	-- UNIT_SPELLCAST_SUCCEEDED spell IDs are secret values that cannot be used for matching.
	-- Appended to a list (rather than overwriting) because one keypress can fire multiple events.
	if spellId and not issecretvalue(spellId) then
		local list = lastCastSpellIds[unit]
		if not list then
			list = {}
			lastCastSpellIds[unit] = list
		end
		list[#list + 1] = { SpellId = spellId, Time = now }
		-- Prune entries outside the cast window to bound list size.
		local cutoff = now - castWindow
		local keep = 1
		for i = 1, #list do
			if list[i].Time >= cutoff then
				if i ~= keep then list[keep] = list[i] end
				keep = keep + 1
			end
		end
		for i = keep, #list do list[i] = nil end
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

---Registers a lookup function that returns the ActiveCooldowns table for a given unit.
---Used by PredictSpellIdForUnit to skip rules whose spell is already on cooldown.
---@param fn fun(unit: string): table?
function B:RegisterActiveCooldownsLookup(fn)
	activeCooldownsLookup = fn
end

---Registers the callback fired when a new aura is matched to a predicted spell.
---entry is the detecting (target) entry. casterUnit is the predicted caster unit string,
---or nil when the caster is the target unit itself (self-cast auras).
---durationObject is the aura's DurationObject at detection time, for driving the countdown display.
---fn(entry, spellId, casterUnit, durationObject)
---@param fn fun(entry: FcdWatchEntry, spellId: number, casterUnit: string?, durationObject: table?)
function B:RegisterPredictiveGlowCallback(fn)
	predictiveGlowCallback = fn
end

---Registers the callback fired when a predictively-matched aura is removed.
---Mirrors RegisterPredictiveGlowCallback — casterUnit is nil for self-cast auras.
---fn(entry, spellId, casterUnit)
---@param fn fun(entry: FcdWatchEntry, spellId: number, casterUnit: string?)
function B:RegisterPredictiveGlowEndCallback(fn)
	predictiveGlowEndCallback = fn
end

---Registers the callback fired when an active predicted-glow aura's duration changes.
---Fired on every UNIT_AURA update while the glow is live, so callers should be cheap.
---fn(entry, spellId, casterUnit, durationObject)
---@param fn fun(entry: FcdWatchEntry, spellId: number, casterUnit: string?, durationObject: table?)
function B:RegisterPredictiveGlowDurationChangedCallback(fn)
	predictiveGlowDurationChangedCallback = fn
end

-- Clears all per-unit timestamp state. Called by tests between cases so state
-- from one test cannot bleed into the next.
function B._TestReset()
	for k in pairs(lastDebuffTime)      do lastDebuffTime[k]      = nil end
	for k in pairs(lastShieldTime)      do lastShieldTime[k]      = nil end
	for k in pairs(lastCastTime)        do lastCastTime[k]        = nil end
	for k in pairs(lastCastSpellIds)    do lastCastSpellIds[k]    = nil end
	for k in pairs(lastUnitFlagsTime)   do lastUnitFlagsTime[k]   = nil end
	for k in pairs(lastFeignDeathTime)  do lastFeignDeathTime[k]  = nil end
	for k in pairs(lastFeignDeathState) do lastFeignDeathState[k] = nil end
	for k in pairs(unitCanFeign)        do unitCanFeign[k]        = nil end
end

---Wires Brain into an observer. Called by FriendlyCooldowns Module during Init.
---Brain has no direct observer dependency; the caller supplies whichever observer to use.
---@param obs FriendlyCooldownObserver
function B:RegisterWithObserver(obs)
	obs:RegisterAuraChangedCallback(function(entry, watcher, candidateUnits)
		OnWatcherChanged(entry, watcher, candidateUnits)
	end)
	obs:RegisterCastCallback(RecordCast)
	obs:RegisterShieldCallback(RecordShield)
	obs:RegisterUnitFlagsCallback(RecordUnitFlagsChange)
	obs:RegisterDebuffEvidenceCallback(TryRecordDebuffEvidence)
end

-- Public API used by EnemyCooldowns module to share rule-matching logic.

---Matches a rule for the given unit using duration + evidence + talent checks.
---@param unit string
---@param auraTypes table<string,boolean>
---@param measuredDuration number
---@param context MatchRuleContext?
---@return table?
function B:MatchRule(unit, auraTypes, measuredDuration, context)
	return MatchRule(unit, auraTypes, measuredDuration, context)
end

---Finds the best-matching rule and caster unit for a tracked aura removal.
---entry must have Unit (string) and ActiveCooldowns (table) fields.
---tracked must have AuraTypes, Evidence?, StartTime, CastSnapshot (table<string,number>), and optionally CastSpellIdSnapshot.
---candidateUnits lists units to check as casters in addition to entry.Unit (always checked first).
---opts.IgnoreTalentRequirements skips RequiresTalent checks (e.g. for enemies where talent data is unavailable).
---@param entry table  { Unit: string, ActiveCooldowns: table }
---@param tracked table  { AuraTypes, Evidence?, StartTime, CastSnapshot, CastSpellIdSnapshot? }
---@param measuredDuration number
---@param candidateUnits string[]
---@param opts table?  { IgnoreTalentRequirements: boolean? }
---@return table? rule
---@return string ruleUnit
function B:FindBestCandidate(entry, tracked, measuredDuration, candidateUnits, opts)
	return FindBestCandidate(entry, tracked, measuredDuration, candidateUnits, opts)
end

---Test-only: override the simulateNoCastSucceeded flag so tests can exercise both
---pre-12.0.5 and 12.0.5+ code paths without changing the actual build number.
---@param val boolean
function B:_TestSetSimulateNoCastSucceeded(val)
	simulateNoCastSucceeded = val
end

---Predicts the first matching spell ID for a unit given aura types and evidence.
---Does NOT consult the module-level activeCooldownsLookup; pass activeCooldowns directly.
---@param unit string
---@param auraTypes table<string,boolean>
---@param evidence EvidenceSet?
---@param activeCooldowns table?  active cooldowns keyed by SpellId; nil = no cooldown filter
---@return number? spellId
---@return boolean isOnCooldown
function B:PredictSpellId(unit, auraTypes, evidence, activeCooldowns)
	local _, classToken = UnitClass(unit)
	if not classToken then return nil, false end

	local specId = fcdTalents:GetUnitSpecId(unit)

	local function tryRuleList(ruleList)
		if not ruleList then return nil, false end
		for _, rule in ipairs(ruleList) do
			if rule.SpellId then
				local excluded = false
				if rule.ExcludeIfTalent then
					if type(rule.ExcludeIfTalent) == "table" then
						for _, talentId in ipairs(rule.ExcludeIfTalent) do
							if fcdTalents:UnitHasTalent(unit, talentId, specId) then excluded = true; break end
						end
					else
						excluded = fcdTalents:UnitHasTalent(unit, rule.ExcludeIfTalent, specId)
					end
				end
				local required = false
				if rule.RequiresTalent then
					if type(rule.RequiresTalent) == "table" then
						required = true
						for _, talentId in ipairs(rule.RequiresTalent) do
							if fcdTalents:UnitHasTalent(unit, talentId, specId) then required = false; break end
						end
					else
						required = not fcdTalents:UnitHasTalent(unit, rule.RequiresTalent, specId)
					end
				end
				if not excluded and not required then
					if AuraTypeMatchesRule(auraTypes, rule) and EvidenceMatchesReq(rule.RequiresEvidence, evidence) then
						local onCd = activeCooldowns ~= nil and activeCooldowns[rule.SpellId] ~= nil
						return rule.SpellId, onCd
					end
				end
			end
		end
		return nil, false
	end

	local spellId, onCd = tryRuleList(specId and rules.BySpec[specId])
	if spellId ~= nil then return spellId, onCd end
	return tryRuleList(rules.ByClass[classToken])
end
