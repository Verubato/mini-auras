---@type string, Addon
local _, addon = ...

---@class WoWEx
local M = {}

addon.Utils.WoWEx = M

-- 12.1 removes addon access to aura data (UnitAura APIs return secrets/nil) and replaces it with
-- the AuraContainer system. True when running on a 12.1+ client, where all aura display must go
-- through AuraContainers and aura-reading modules (party cooldown tracking) must be disabled.
-- TEMPORARY dual-path support: remove the 12.0 path once 12.1 is live everywhere.
--
-- Resolved once at file load, and most modules then cache it into their own file-load-time
-- `USE_AURA_CONTAINERS` local. It can never change during a session, so this is intentional -
-- but it does mean tests must set the build number BEFORE loading any module, or the module
-- captures the wrong path and no amount of later re-stubbing will move it.
local INTERFACE_VERSION = select(4, GetBuildInfo())
M.IsAuraContainerEra = INTERFACE_VERSION >= 120100

-- Expiry times for duration objects built by CreateDuration, keyed weakly so expired objects
-- can collect. Duration objects are otherwise write-only to addon code; this is how displays
-- colour a countdown whose times the addon itself supplied (test icons, kick timers) while
-- engine-made secret objects stay untouched.
local durationExpiries = setmetatable({}, { __mode = "k" })

---@return boolean
function M:UseAuraContainers()
	return M.IsAuraContainerEra
end

---True when the client can drive pandemic (refresh-window) regions on aura buttons. Probes the
---C_UnitAuras functions the engine computes the window from rather than the button mixin, which
---lives in the secure environment and is not a readable global.
---@return boolean
function M:HasPandemicRegions()
	return M.IsAuraContainerEra
		and C_UnitAuras ~= nil
		and C_UnitAuras.GetRefreshExtendedDuration ~= nil
		and C_UnitAuras.GetAuraBaseDuration ~= nil
end

---True while AuraButton styling is blocked: button APIs Lua-error from addon code whenever
---auras are secret, which covers combat but ALSO out-of-combat moments inside M+/encounters/
---PvP matches - so InCombatLockdown alone is not a sufficient guard.
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

-- TEMPORARY: only the 12.0 TTS alerts call this; it goes with the legacy path.
-- Resolves the TTS voice ID to use, validating storedID against available voices.
-- If storedID is valid it is returned as-is; if the voice list is available but
-- storedID is absent or unrecognised the first available voice is returned;
-- if no voice list is available the system default (or storedID) is used.
---@param storedID number?
---@return number
function M:ResolveVoiceID(storedID)
	local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices() or nil
	if voices and #voices > 0 then
		if storedID ~= nil then
			for _, v in ipairs(voices) do
				if v.voiceID == storedID then
					return storedID
				end
			end
		end
		return voices[1].voiceID
	end
	return storedID or C_TTSSettings.GetVoiceOptionID(0)
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
