---@type string, Addon
local _, addon = ...

---@class WoWEx
local M = {}

addon.Utils.WoWEx = M

-- Expiry times for duration objects built by CreateDuration, keyed weakly so expired objects
-- can collect. Duration objects are otherwise write-only to addon code; this is how displays
-- colour a countdown whose times the addon itself supplied (test icons, kick timers) while
-- engine-made secret objects stay untouched.
local durationExpiries = setmetatable({}, { __mode = "k" })

---True when the client can drive pandemic (refresh-window) regions on aura buttons. Probes the
---C_UnitAuras functions the engine computes the window from rather than the button mixin, which
---lives in the secure environment and is not a readable global.
---@return boolean
function M:HasPandemicRegions()
	return C_UnitAuras ~= nil
		and C_UnitAuras.GetRefreshExtendedDuration ~= nil
		and C_UnitAuras.GetAuraBaseDuration ~= nil
end

---True while AuraButton styling is blocked: button APIs Lua-error from addon code whenever
---auras are secret, which covers combat but also out-of-combat moments inside M+, encounters and
---PvP matches, so InCombatLockdown alone is not a sufficient guard.
---@return boolean
function M:IsAuraStylingRestricted()
	if InCombatLockdown() then
		return true
	end
	if C_Secrets and C_Secrets.ShouldAurasBeSecret then
		return C_Secrets.ShouldAurasBeSecret()
	end
	return false
end

-- 12.1 moved the specialization functions onto C_SpecializationInfo and the globals stopped
-- answering, which silently emptied every spec lookup in the addon. The classic clients only
-- ever had the globals. Resolved per call rather than bound once, because this file loads
-- before the client has finished filling either shape in.
local function SpecFunction(name)
	local namespaced = C_SpecializationInfo and C_SpecializationInfo[name]

	if namespaced then
		return namespaced
	end

	return _G[name]
end

---The player's active specialization index, or nil when the client cannot say yet.
---@return number?
function M:GetSpecializationIndex()
	local fn = SpecFunction("GetSpecialization")

	if not fn then
		return nil
	end

	return fn()
end

---@param specIndex number?
---@return number? specId
---@return string? specName
function M:GetSpecializationInfo(specIndex)
	local fn = SpecFunction("GetSpecializationInfo")

	if not fn or not specIndex then
		return nil
	end

	return fn(specIndex)
end

---The player's active specialization id, or nil when it cannot be read.
---@return number?
function M:GetPlayerSpecId()
	local specIndex = M:GetSpecializationIndex()

	if not specIndex then
		return nil
	end

	local specId = M:GetSpecializationInfo(specIndex)

	if type(specId) ~= "number" or specId <= 0 then
		return nil
	end

	return specId
end

---@return number
function M:GetNumSpecializations()
	local fn = SpecFunction("GetNumSpecializations")

	if not fn then
		return 0
	end

	return fn() or 0
end

---@param specId number
---@return number? specId
function M:GetSpecializationInfoByID(specId)
	local fn = SpecFunction("GetSpecializationInfoByID")

	if not fn then
		return nil
	end

	return fn(specId)
end

---@param classId number
---@return number
function M:GetNumSpecializationsForClassID(classId)
	local fn = SpecFunction("GetNumSpecializationsForClassID")

	if not fn then
		return 0
	end

	return fn(classId) or 0
end

---@param classId number
---@param specIndex number
---@return number? specId
---@return string? specName
function M:GetSpecializationInfoForClassID(classId, specIndex)
	local fn = SpecFunction("GetSpecializationInfoForClassID")

	if not fn then
		return nil
	end

	return fn(classId, specIndex)
end

function M:IsAddOnEnabled(addonName)
	return C_AddOns.GetAddOnEnableState(addonName, UnitName("player")) == 2
end

function M:IsDandersEnabled()
	return M:IsAddOnEnabled("DandersFrames")
end

---Creates and populates a DurationObject from a start time and duration.
---@param startTime number  GetTime()-style timestamp when the effect began
---@param duration number   Total duration in seconds
---@param modRate number?   Optional haste modifier (defaults to 1.0)
---@return table DurationObject
function M:CreateDuration(startTime, duration, modRate)
	local d = C_DurationUtil.CreateDuration()
	d:SetTimeFromStart(startTime, duration, modRate)
	-- A haste modifier changes the real remaining time in ways this plain sum cannot track.
	if not modRate or modRate == 1 then
		durationExpiries[d] = startTime + duration
	end
	return d
end

---Expiry (GetTime clock) for a duration object built by CreateDuration; nil for foreign or
---haste-modified objects, whose remaining time the addon cannot know.
---@param durationObject table?
---@return number?
function M:GetDurationExpiry(durationObject)
	return durationObject and durationExpiries[durationObject] or nil
end
