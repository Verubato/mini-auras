---@diagnostic disable: unused-function
local _, addon = ...
local M = addon.Config.Migrator

-- The modules that take a copy of the old global font scale on the module table itself.
local FONT_SCALE_MODULES = {
	"Nameplates",
	"PetCrowdControl",
	"Portrait",
	"Alerts",
	"Trinkets",
	"EnemyKickTracker",
	"AllyKickTracker",
	"HealerCrowdControl",
}

-- Crowd Control and Important Auras keep a font scale per instance tab, so both tabs take the copy.
local PER_INSTANCE_MODULES = { "CrowdControl", "ImportantAuras" }
local INSTANCES = { "Default", "Raid" }

local FRAME_AURA_ROWS = { "Buffs", "Debuffs", "TargetFocus" }

-- A later version moving these sliders must not change what this step decided.
local SHIPPED_TEXT_SCALE = 100
local MIN_FONT_SCALE = 0.5
local MAX_FONT_SCALE = 2.0
local UNCHANGED_FONT_SCALE = 1.0

---@param value number
---@return number
local function Held(value)
	return math.max(MIN_FONT_SCALE, math.min(MAX_FONT_SCALE, value))
end

---Turns a percentage text size into a font scale with the old global multiplied in. A row the
---player never sized keeps nothing of its own unless the global has something to carry over.
---@param options table A frame aura row, or one personal aura group's icon options.
---@param scale number The old global font scale.
local function ToFontScale(options, scale)
	local percent = tonumber(options.TextScale)

	options.TextScale = nil

	if not percent and scale == UNCHANGED_FONT_SCALE then
		return
	end

	options.FontScale = Held((percent or SHIPPED_TEXT_SCALE) / 100 * scale)
end

---Converts the two modules that sized their own text as a percentage, so their text comes out of
---the upgrade the size it went in at.
---@param modules table
---@param scale number
local function ConvertOwnTextSize(modules, scale)
	local frameAuras = modules.FrameAuras

	for _, row in ipairs(FRAME_AURA_ROWS) do
		local options = frameAuras and frameAuras[row]

		if type(options) == "table" then
			ToFontScale(options, scale)
		end
	end

	local personalAuras = modules.PersonalAuras

	for _, group in ipairs(personalAuras and personalAuras.Groups or {}) do
		if type(group.Icons) == "table" then
			ToFontScale(group.Icons, scale)
		end
	end
end

---A profile that never touched a module has no table for it, and the merge against the defaults
---would then hand it 1.0 rather than what the player was seeing.
---@param parent table
---@param key string
---@return table
local function Table(parent, key)
	if type(parent[key]) ~= "table" then
		parent[key] = {}
	end

	return parent[key]
end

---@param modules table
---@param held number The old global, inside the range the new sliders offer.
local function Distribute(modules, held)
	for _, name in ipairs(FONT_SCALE_MODULES) do
		Table(modules, name).FontScale = held
	end

	for _, name in ipairs(PER_INSTANCE_MODULES) do
		local module = Table(modules, name)

		for _, instance in ipairs(INSTANCES) do
			Table(module, instance).FontScale = held
		end
	end
end

---@param vars table The live saved variables, or one profile's snapshot of them.
local function SplitFontScale(vars)
	local scale = tonumber(vars.FontScale)
	local modules = vars.Modules

	if type(modules) == "table" then
		if scale then
			Distribute(modules, Held(scale))
		end

		ConvertOwnTextSize(modules, scale or UNCHANGED_FONT_SCALE)
	end

	vars.FontScale = nil
end

function M:UpgradeToVersion79(vars)
	if vars.Version ~= 78 then return false end

	SplitFontScale(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still holding
	-- the old root key would put it straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			SplitFontScale(profile)
		end
	end

	vars.Version = 79
	return true
end
