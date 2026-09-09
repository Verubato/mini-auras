---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

---@param vars table The live saved variables, or one profile's snapshot of them.
local function ShowKickBorder(vars)
	if type(vars) ~= "table" or type(vars.Modules) ~= "table" then
		return
	end

	local kickTracker = vars.Modules.EnemyKickTracker

	if type(kickTracker) ~= "table" or type(kickTracker.Icons) ~= "table" then
		return
	end

	-- The stored false came from an old default rather than from anyone, since the key had no
	-- control until now.
	kickTracker.Icons.Border = true
end

function M:UpgradeToVersion87(vars)
	if vars.Version ~= 86 then return false end

	ShowKickBorder(vars)

	-- A snapshot nobody ever loads is never normalised, so it would keep the dead value forever.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			ShowKickBorder(profile)
		end
	end

	vars.Version = 87
	return true
end
