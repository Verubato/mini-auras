---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

-- Swapping a grow for its twin moves only the vertical half of the pin, so a row anchored to a top
-- or bottom edge lands back where the player left it.
local KEEPS_PLACEMENT = {
	BOTTOM = { LEFT = "LEFT_UP", RIGHT = "RIGHT_UP" },
	TOP = { LEFT_UP = "LEFT", RIGHT_UP = "RIGHT" },
}

-- The edge each anchor point sits on. A mid-height point is left out because no grow reproduces
-- the pin it used to get.
local ANCHOR_HALF = {
	TOPLEFT = "TOP",
	TOP = "TOP",
	TOPRIGHT = "TOP",
	BOTTOMLEFT = "BOTTOM",
	BOTTOM = "BOTTOM",
	BOTTOMRIGHT = "BOTTOM",
}

local SIDES = { "Buffs", "Debuffs" }

---@param vars table The live saved variables, or one profile's snapshot of them.
local function KeepPlacement(vars)
	if type(vars) ~= "table" or type(vars.Modules) ~= "table" then
		return
	end

	local frameAuras = vars.Modules.FrameAuras

	if type(frameAuras) ~= "table" then
		return
	end

	for _, side in ipairs(SIDES) do
		local options = frameAuras[side]
		local half = type(options) == "table" and ANCHOR_HALF[options.Anchor]
		local twin = half and KEEPS_PLACEMENT[half][options.Grow]

		if twin then
			options.Grow = twin
		end
	end
end

function M:UpgradeToVersion84(vars)
	if vars.Version ~= 83 then return false end

	KeepPlacement(vars)

	-- A profile switch writes its snapshot back over the live db key by key, so a snapshot left on
	-- the old grow would move the row again the moment it is loaded.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			KeepPlacement(profile)
		end
	end

	vars.Version = 84
	return true
end
