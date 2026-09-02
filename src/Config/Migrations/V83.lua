---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

-- Spelled out rather than read off AuraContainerDisplay.ColorMode: a migration writes what its own
-- version expected, so a later rename of those values must not quietly change what this step did.
local MODE_DISPEL = "DISPEL"
local MODE_CUSTOM = "CUSTOM"

-- The CC/PetCC options tables that carried a ColorByDispelType flag before version 83, each one
-- holding its own Icons table.
local CC_INSTANCES = {
	{ "CrowdControl", "Default" },
	{ "CrowdControl", "Raid" },
	{ "PetCrowdControl" },
}

---Folds one instance's Icons.ColorByDispelType into the ColorMode it became.
---@param modules table
---@param path table A CC_INSTANCES entry: the module key, and an optional instance key under it.
local function FoldColorMode(modules, path)
	local options = modules and modules[path[1]]

	if path[2] then
		options = options and options[path[2]]
	end

	local icons = options and options.Icons

	if not icons then
		return
	end

	if icons.ColorMode == nil then
		icons.ColorMode = icons.ColorByDispelType == false and MODE_CUSTOM or MODE_DISPEL
	end

	icons.ColorByDispelType = nil
end

---@param vars table The live saved variables, or one profile's snapshot of them.
local function FoldAllColorModes(vars)
	if type(vars) ~= "table" or type(vars.Modules) ~= "table" then
		return
	end

	for _, path in ipairs(CC_INSTANCES) do
		FoldColorMode(vars.Modules, path)
	end
end

function M:UpgradeToVersion83(vars)
	if vars.Version ~= 82 then return false end

	FoldAllColorModes(vars)

	-- Snapshots are written back over the live db wholesale on a profile switch, so one still
	-- carrying the boolean would put an instance back on the shipped mode.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			FoldAllColorModes(profile)
		end
	end

	vars.Version = 83
	return true
end
