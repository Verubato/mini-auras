---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

-- Where each frame aura part sat before the player could move it. Spelled out rather than read off
-- the defaults table, so a later version shipping a different corner cannot rewrite this step.
local PLACEMENT = {
	Buffs = { Anchor = "BOTTOMRIGHT", Grow = "LEFT_UP", X = -2, Y = 2 },
	Debuffs = { Anchor = "BOTTOMLEFT", Grow = "RIGHT_UP", X = 2, Y = 2 },
	-- One mark per frame, so there is nothing to grow.
	ClassBuff = { Anchor = "TOPRIGHT", X = -2, Y = -2 },
}

---Seeds the placement keys on a table that predates them, leaving anything already there.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function SeedPlacement(vars)
	if type(vars) ~= "table" or type(vars.Modules) ~= "table" then
		return
	end

	local frameAuras = vars.Modules.FrameAuras

	if type(frameAuras) ~= "table" then
		return
	end

	for part, shipped in pairs(PLACEMENT) do
		local options = frameAuras[part]

		if type(options) == "table" then
			if options.Anchor == nil then
				options.Anchor = shipped.Anchor
			end

			if shipped.Grow ~= nil and options.Grow == nil then
				options.Grow = shipped.Grow
			end

			if type(options.Offset) ~= "table" then
				options.Offset = { X = shipped.X, Y = shipped.Y }
			end
		end
	end
end

function M:UpgradeToVersion81(vars)
	if vars.Version ~= 80 then return false end

	SeedPlacement(vars)

	-- A profile switch writes its snapshot back over the live db key by key, so a snapshot without
	-- these would nil them out and leave the sliders bound to a table nothing reads.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			SeedPlacement(profile)
		end
	end

	vars.Version = 81
	return true
end
