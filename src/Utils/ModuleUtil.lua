---@type string, Addon
local _, addon = ...
---@type Db
local db

---@class ModuleName
local ModuleName = {
	CrowdControl = "CrowdControlModule",
	HealerCrowdControl = "HealerCrowdControlModule",
	Portrait = "PortraitModule",
	Alerts = "AlertsModule",
	Nameplates = "NameplatesModule",
	KickTimer = "KickTimerModule",
	Trinkets = "TrinketsModule",
	FriendlyIndicator = "FriendlyIndicatorModule",
}

---@class ModuleUtil
local M = {}

addon.Utils.ModuleUtil = M
addon.Utils.ModuleName = ModuleName

function M:Init()
	db = addon.Core.Framework:GetSavedVars()
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

	-- Check if Always is enabled first
	if settings.Always then
		return true
	end

	-- Determine current context
	local inInstance, instanceType = IsInInstance()

	if not inInstance then
		return settings.Always
	end

	-- Check specific instance types
	if instanceType == "arena" then
		return settings.Arena
	elseif instanceType == "pvp" then
		-- Battlegrounds/Raids
		return settings.Raids
	elseif instanceType == "party" then
		-- Dungeons
		return settings.Dungeons
	elseif instanceType == "raid" then
		-- Raid instances
		return settings.Raids
	end

	return settings.Always
end
