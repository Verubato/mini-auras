-- Lightweight spec inspector adapted from FrameSort's Inspector module, the fallback when
-- FrameSortApi is unavailable. Resolves friendly unit spec IDs through NotifyInspect and
-- INSPECT_READY, behind a GUID-keyed cache.
--
-- Init runs once from MiniAuras.lua. Without it GetUnitSpecId still answers from its synchronous
-- paths, but the async inspect queue never drains and the saved GUID->spec cache is never loaded,
-- which is what makes KickTracker's guess at the interrupting ally worse.
---@type string, Addon
local _, addon = ...

local INSPECT_INTERVAL  = 0.5
local INSPECT_TIMEOUT   = 10
local CACHE_TIMEOUT     = 60
local CACHE_EXPIRY      = 60 * 60 * 24 * 3 -- 3 days

local unitGuidToSpec      = {}
local priorityStack       = {}
local requestedUnit       = nil
local currentInspectUnit  = nil
local isOurInspect        = false
local needUpdate          = true
local initialised         = false
local inspectStarted      = nil
-- Whether a RunLoop tick is scheduled. The loop only runs while an inspect is in flight or a
-- spec is missing; ArmLoop wakes it, and an idle tick simply does not reschedule.
local loopArmed           = false
local callbacks           = {}
-- Lazily built map of "Spec Name Class Name" -> specId for tooltip matching.
-- e.g. "Discipline Priest" -> 256, "Holy Paladin" -> 65, etc.
local tooltipSpecMap = nil

---@class Inspector
local M = {}
addon.Core.Inspector = M

local function Now()
	return GetTimePreciseSec and GetTimePreciseSec() or GetTime()
end

local function GetFriendlyUnits()
	local units = { "player" }
	local numGroup = GetNumGroupMembers()
	if IsInRaid() then
		for i = 1, numGroup do
			units[#units + 1] = "raid" .. i
		end
	else
		for i = 1, numGroup do
			units[#units + 1] = "party" .. i
		end
	end
	return units
end

local function OnSpecInformationChanged()
	for _, callback in ipairs(callbacks) do
		pcall(callback)
	end
end

local function GetTooltipSpecMap()
	if tooltipSpecMap then
		return tooltipSpecMap
	end

	tooltipSpecMap = {}

	if not (GetNumClasses and GetClassInfo) then
		return tooltipSpecMap
	end

	local wowEx = addon.Utils.WoWEx

	for classIdx = 1, GetNumClasses() do
		local className, _, classId = GetClassInfo(classIdx)
		if className and classId then
			for specIdx = 1, wowEx:GetNumSpecializationsForClassID(classId) do
				local specId, specName = wowEx:GetSpecializationInfoForClassID(classId, specIdx)
				if specId and specName then
					tooltipSpecMap[specName .. " " .. className] = specId
				end
			end
		end
	end

	return tooltipSpecMap
end

---Returns a spec ID by inspecting the unit's tooltip, or nil if unrecognised.
---This is a synchronous fast path that avoids queuing an async NotifyInspect.
---@param unit string
---@return number|nil
local function SpecFromTooltip(unit)
	if not (C_TooltipInfo and C_TooltipInfo.GetUnit) then
		return nil
	end

	local tooltipData = C_TooltipInfo.GetUnit(unit)
	if not tooltipData then
		return nil
	end

	local specMap = GetTooltipSpecMap()

	for _, line in ipairs(tooltipData.lines) do
		if line and line.type == Enum.TooltipDataLineType.None and line.leftText then
			if not issecretvalue(line.leftText) then
				local specId = specMap[line.leftText]
				if specId then
					return specId
				end
			end
		end
	end

	return nil
end

-- UnitGUID throws "Player/pet name are not valid arguments for this call" when called
-- on an enemy unit by name. The error message is misleading since UnitGUID does accept
-- unit names in general -- pcall is the only way to handle this gracefully.
local function SafeUnitGUID(unit)
	local ok, guid = pcall(UnitGUID, unit)
	return ok and guid or nil
end

local function PurgeOldEntries()
	local now = Now()
	for guid, entry in pairs(unitGuidToSpec) do
		if not entry or type(entry) ~= "table" or not entry.LastSeen or (now - entry.LastSeen) > CACHE_EXPIRY then
			unitGuidToSpec[guid] = nil
		end
	end
end

local function EnsureCacheEntry(unit)
	local guid = SafeUnitGUID(unit)
	if not guid or issecretvalue(guid) then
		return nil
	end
	if not unitGuidToSpec[guid] then
		unitGuidToSpec[guid] = {}
	end
	return unitGuidToSpec[guid]
end

local function Inspect(unit)
	local specId = GetInspectSpecialization and GetInspectSpecialization(unit)
	-- A unit the client will not let an addon identify answers with a secret spec, and a
	-- mouseover of a stranger is the everyday way to get one. Nothing here can use it: comparing
	-- it errors, and caching it only moves that error to whoever reads the cache.
	if specId and not issecretvalue(specId) and specId > 0 then
		local cacheEntry = EnsureCacheEntry(unit)
		if cacheEntry then
			local before = cacheEntry.SpecId
			cacheEntry.SpecId = specId
			cacheEntry.LastSeen = Now()
			if before ~= specId then
				OnSpecInformationChanged()
			end
		end
	end

	if isOurInspect then
		currentInspectUnit = nil
		requestedUnit = nil
		isOurInspect = false
		ClearInspectPlayer()
	end
end

local function InvalidateEntry(unit)
	local guid = SafeUnitGUID(unit)
	if not guid or issecretvalue(guid) then
		return
	end
	unitGuidToSpec[guid] = nil
	needUpdate = true
end

local function OnClearInspect()
	requestedUnit = nil
end

local function OnNotifyInspect(unit)
	local guid = SafeUnitGUID(unit)
	if not guid or issecretvalue(guid) then
		return
	end
	-- Ignore inspects of non-friendly units (e.g. enemy players inspected by other addons).
	if not UnitIsFriend(unit, "player") then
		return
	end
	if currentInspectUnit and unit ~= currentInspectUnit then
		currentInspectUnit = nil
	end
	requestedUnit = unit
	inspectStarted = Now()
	isOurInspect = false
end

local function GetNextTarget()
	-- process priority stack first (LIFO)
	while #priorityStack > 0 do
		local unit = priorityStack[#priorityStack]
		priorityStack[#priorityStack] = nil
		if UnitExists(unit) then
			local guid = UnitGUID(unit)
			if guid and not issecretvalue(guid) then
				return unit
			end
		end
	end

	local units = GetFriendlyUnits()
	local now = Now()

	-- first pass: units with no cache entry
	for _, unit in ipairs(units) do
		if not UnitIsUnit(unit, "player") then
			local guid = UnitGUID(unit)
			if guid and not issecretvalue(guid) then
				local cacheEntry = unitGuidToSpec[guid]
				if not cacheEntry and CanInspect(unit) and UnitIsConnected(unit) then
					return unit
				end
			end
		end
	end

	-- second pass: units with stale or missing spec
	for _, unit in ipairs(units) do
		if not UnitIsUnit(unit, "player") then
			local guid = UnitGUID(unit)
			if guid and not issecretvalue(guid) then
				local cacheEntry = unitGuidToSpec[guid]
				if cacheEntry
					and (not cacheEntry.SpecId or cacheEntry.SpecId == 0)
					and CanInspect(unit)
					and UnitIsConnected(unit)
					and (not cacheEntry.LastAttempt or (now - cacheEntry.LastAttempt > CACHE_TIMEOUT))
				then
					return unit
				end
			end
		end
	end

	return nil
end

---One pass of the inspect loop. Returns whether another tick is needed: an inspect is in
---flight or queued work remains. Idle passes return false, and the loop sleeps until ArmLoop.
local function Step()
	local now = Now()
	local timeSinceLastInspect = inspectStarted and (now - inspectStarted)

	if requestedUnit ~= nil and timeSinceLastInspect and timeSinceLastInspect < INSPECT_TIMEOUT then
		-- An inspect is in flight; stay scheduled to time it out if INSPECT_READY never comes.
		return true
	end

	if requestedUnit ~= nil then
		-- timeout: give up and move on
		if isOurInspect then
			ClearInspectPlayer()
		end
		requestedUnit = nil
		currentInspectUnit = nil
		isOurInspect = false
	end

	if not needUpdate then
		return false
	end

	local unit = GetNextTarget()
	if not unit then
		needUpdate = false
		return false
	end

	local cacheEntry = EnsureCacheEntry(unit)
	if not cacheEntry then
		-- The unit's GUID would not resolve just now; try again next tick.
		return true
	end

	cacheEntry.LastAttempt = now
	ClearInspectPlayer()
	NotifyInspect(unit)
	isOurInspect = true
	inspectStarted = now
	requestedUnit = unit
	currentInspectUnit = unit

	-- Stay scheduled as the watchdog for the inspect just started.
	return true
end

local function RunLoop()
	loopArmed = false

	if Step() then
		loopArmed = true
		C_Timer.After(INSPECT_INTERVAL, RunLoop)
	end
end

---Wakes the run loop when something queues work for it; a no-op while a tick is already
---scheduled, so callers never stack timers.
local function ArmLoop()
	if not initialised or loopArmed then
		return
	end

	loopArmed = true
	C_Timer.After(INSPECT_INTERVAL, RunLoop)
end

---Returns the specialization ID for the given unit, or nil if unknown.
---@param unit string
---@return number|nil
function M:GetUnitSpecId(unit)
	if not unit then
		return nil
	end

	if UnitIsUnit(unit, "player") then
		return addon.Utils.WoWEx:GetPlayerSpecId()
	end

	local guid = UnitGUID(unit)
	if not guid or issecretvalue(guid) then
		return nil
	end

	local cacheEntry = unitGuidToSpec[guid]
	if cacheEntry and cacheEntry.SpecId and cacheEntry.SpecId > 0 then
		return cacheEntry.SpecId
	end

	-- Try the tooltip as a synchronous fast path before falling back to async inspect.
	-- Intentionally does not call OnSpecInformationChanged to avoid re-entrancy issues.
	local specId = SpecFromTooltip(unit)
	if specId then
		cacheEntry = EnsureCacheEntry(unit)
		if cacheEntry then
			cacheEntry.SpecId = specId
			cacheEntry.LastSeen = Now()
		end
		return specId
	end

	-- Queue for async inspection on the next run loop tick, but only once Init has run: nothing
	-- drains the stack before then, so it would grow for the whole session.
	if initialised and not cacheEntry then
		priorityStack[#priorityStack + 1] = unit
	end

	-- Any miss arms the loop, not just a first sight: an entry whose inspect timed out is only
	-- retried by the scan once its CACHE_TIMEOUT passes, and someone asking is what wakes the
	-- loop to get there.
	if initialised and (not cacheEntry or not cacheEntry.SpecId or cacheEntry.SpecId == 0) then
		needUpdate = true
		ArmLoop()
	end

	return cacheEntry and cacheEntry.SpecId
end

---Registers a callback to invoke when spec information changes.
---@param callback function
function M:RegisterCallback(callback)
	callbacks[#callbacks + 1] = callback
end

function M:Init()
	if not (CanInspect and NotifyInspect and ClearInspectPlayer and GetInspectSpecialization) then
		return
	end

	-- Persist the GUID->spec cache in saved variables so it survives reloads.
	local db = addon.Framework:GetSavedVars()
	db.SpecCache = db.SpecCache or {}
	unitGuidToSpec = db.SpecCache

	PurgeOldEntries()

	hooksecurefunc("NotifyInspect", OnNotifyInspect)
	hooksecurefunc("ClearInspectPlayer", OnClearInspect)

	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, ...)
		if event == "INSPECT_READY" then
			if requestedUnit then
				Inspect(requestedUnit)
			end
		elseif event == "GROUP_ROSTER_UPDATE" then
			needUpdate = true
			ArmLoop()
		elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
			local unit = ...
			InvalidateEntry(unit)
			ArmLoop()
		elseif event == "PLAYER_ENTERING_WORLD" then
			priorityStack = {}
		end
	end)
	eventsFrame:RegisterEvent("INSPECT_READY")
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

	initialised = true
	ArmLoop()
end

---@class Inspector
---@field Init fun(self: Inspector)
---@field GetUnitSpecId fun(self: Inspector, unit: string): number|nil
---@field RegisterCallback fun(self: Inspector, callback: function)
