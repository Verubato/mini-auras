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
---auras are secret, which covers combat but ALSO out-of-combat moments inside M+/encounters/
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
