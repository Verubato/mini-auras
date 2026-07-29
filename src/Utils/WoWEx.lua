---@type string, Addon
local _, addon = ...

---@class WoWEx
local M = {}

addon.Utils.WoWEx = M

-- 12.1 removes addon access to aura data (UnitAura APIs return secrets/nil) and replaces it with
-- the AuraContainer system. True when running on a 12.1+ client, where all aura display must go
-- through AuraContainers and aura-reading modules (party cooldown tracking) must be disabled.
-- TEMPORARY dual-path support: remove the 12.0 path once 12.1 is live everywhere.
local interfaceVersion = select(4, GetBuildInfo())
M.IsAuraContainerEra = interfaceVersion >= 120100

---@return boolean
function M:UseAuraContainers()
	return M.IsAuraContainerEra
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
    return d
end
