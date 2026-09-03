---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

---@param vars table The live saved variables, or one profile's snapshot of them.
local function ShowNumbers(vars)
	if type(vars) ~= "table" or type(vars.Modules) ~= "table" then
		return
	end

	local personalAuras = vars.Modules.PersonalAuras

	if type(personalAuras) ~= "table" or type(personalAuras.Groups) ~= "table" then
		return
	end

	for _, group in ipairs(personalAuras.Groups) do
		local icons = type(group) == "table" and group.Icons

		if type(icons) == "table" then
			icons.EnableNumbers = icons.HideNumbers ~= true
			icons.HideNumbers = nil
		end
	end
end

function M:UpgradeToVersion85(vars)
	if vars.Version ~= 84 then return false end

	ShowNumbers(vars)

	-- A snapshot nobody ever loads is never normalised, so it would carry the dead key forever.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			ShowNumbers(profile)
		end
	end

	vars.Version = 85
	return true
end
