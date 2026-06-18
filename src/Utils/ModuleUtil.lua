---@type string, Addon
local _, addon = ...
---@type Db
local db

---@class ModuleName
local ModuleName = {
	CrowdControl = "CCModule",
	PetCC = "PetCCModule",
	HealerCrowdControl = "HealerCCModule",
	Portrait = "PortraitModule",
	Alerts = "AlertsModule",
	Nameplates = "NameplatesModule",
	KickTimer = "KickTimerModule",
	Trinkets = "TrinketsModule",
	FriendlyIndicator = "FriendlyIndicatorModule",
	PrecogGuesser = "PrecogGuesserModule",
	FriendlyCooldownTracker = "FriendlyCooldownTrackerModule",
	EnemyCooldownTracker    = "EnemyCooldownTrackerModule",
}

---@class ModuleUtil
local M = {}

addon.Utils.ModuleUtil = M
addon.Utils.ModuleName = ModuleName

function M:Init()
	db = addon.Core.Framework:GetSavedVars()
end

---Resolves the configured icon size, either as a static pixel value or as a percentage of
---the anchor frame's height when Icons.SizeIsPercent is enabled.
---Accounts for scale mismatch between the anchor and the container's parent (UIParent), so the
---rendered icon matches the anchor's on-screen height even when the anchor uses a custom scale
---(common with ElvUI, Cell, SUF, etc.).
---@param iconOptions table  The Icons sub-table from a module's options.
---@param anchorFrame table? The frame the container is anchored to; used to read GetHeight when percent mode is on.
---@param pixelFallback number  Fallback pixel size when Icons.Size is missing.
---@param percentFallback number  Fallback percent value when Icons.SizePercent is missing.
---@return number
function M:GetIconSize(iconOptions, anchorFrame, pixelFallback, percentFallback)
	if iconOptions.SizeIsPercent == true and anchorFrame then
		local h = anchorFrame:GetHeight()
		if h and h > 0 then
			local percent = tonumber(iconOptions.SizePercent) or percentFallback
			-- The icon container calls SetIgnoreParentScale(true), so it renders at scale 1.0
			-- regardless of UIParent's UI scale. Match the anchor's visible (physical) height by
			-- multiplying logical height by the anchor's effective scale.
			local anchorScale = anchorFrame.GetEffectiveScale and anchorFrame:GetEffectiveScale() or 1
			return math.max(1, math.floor(h * anchorScale * percent / 100 + 0.5))
		end
	end
	return tonumber(iconOptions.Size) or pixelFallback
end

---@param moduleName string The module key (e.g., "AlertsModule", "CcModule")
---@return boolean
function M:IsModuleEnabled(moduleName)
	if not db or not db.Modules or not db.Modules[moduleName] then
		return true -- Default to enabled if settings don't exist
	end

	local settings = db.Modules[moduleName].Enabled
	if not settings then
		return true
	end

	if settings.Always then
		-- this module is set to always enabled, so we can skip the instance check
		return true
	end

	local inInstance, instanceType = IsInInstance()

	if not inInstance then
		if IsInRaid() then
			return settings.Raid
		end
		return settings.World or false
	end

	-- Check specific instance types
	if instanceType == "arena" then
		return settings.Arena
	elseif instanceType == "pvp" then
		return settings.BattleGrounds
	end

	if IsInRaid() then
		return settings.Raid
	end

	return settings.Dungeons
end
