---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

-- The gap the two aura rows were drawn with before the player could set it. Spelled out rather
-- than read off the defaults table, so a later version shipping a wider gap cannot rewrite this
-- step.
local PADDING = 1
local PARTS = { "Buffs", "Debuffs" }

---Seeds the padding key on a table that predates it, leaving anything already there.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function SeedPadding(vars)
	if type(vars) ~= "table" or type(vars.Modules) ~= "table" then
		return
	end

	local frameAuras = vars.Modules.FrameAuras

	if type(frameAuras) ~= "table" then
		return
	end

	for _, part in ipairs(PARTS) do
		local options = frameAuras[part]

		if type(options) == "table" and options.Padding == nil then
			options.Padding = PADDING
		end
	end
end

function M:UpgradeToVersion82(vars)
	if vars.Version ~= 81 then return false end

	SeedPadding(vars)

	-- A profile switch writes its snapshot back over the live db key by key, so a snapshot without
	-- this would nil it out and leave the slider bound to a table nothing reads.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			SeedPadding(profile)
		end
	end

	vars.Version = 82
	return true
end
