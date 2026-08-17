---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

-- Spelled out rather than read off NameplatesDisplay.ColorMode: a migration writes what its own
-- version expected, so a later rename of those values must not quietly change what this step did.
-- The migrator group also loads without the modules behind it.
local MODE_NONE = "NONE"
local MODE_DISPEL = "DISPEL"
local MODE_CUSTOM = "CUSTOM"

local NAMEPLATE_FACTIONS = { "Enemy", "Friendly" }
local NAMEPLATE_BARS = { "Bar1", "Bar2" }

---Folds a bar's ColorByCategory/UseDispelColors pair into the single ColorMode it became. Both
---halves were only ever written together, and UseDispelColors never shipped, so an untouched db
---has the first and not the second.
local function FoldBarColorMode(modules)
	local nameplates = modules and modules.NameplatesModule

	if not nameplates then
		return
	end

	for _, faction in ipairs(NAMEPLATE_FACTIONS) do
		for _, bar in ipairs(NAMEPLATE_BARS) do
			local icons = nameplates[faction] and nameplates[faction][bar]
				and nameplates[faction][bar].Icons

			if icons and icons.ColorMode == nil then
				if icons.ColorByCategory == false then
					icons.ColorMode = MODE_NONE
				elseif icons.UseDispelColors == false then
					icons.ColorMode = MODE_CUSTOM
				else
					icons.ColorMode = MODE_DISPEL
				end
			end

			if icons then
				icons.ColorByCategory = nil
				icons.UseDispelColors = nil
			end
		end
	end
end

function M:UpgradeToVersion69(vars)
	if vars.Version ~= 68 then return false end

	FoldBarColorMode(vars.Modules)

	-- Snapshots are written back over the live db wholesale on a profile switch, so one still
	-- carrying the booleans would put a bar back on the shipped mode.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			FoldBarColorMode(profile.Modules)
		end
	end

	vars.Version = 69
	return true
end
