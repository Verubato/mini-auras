-- Tests for Config/Migrator.lua running against the REAL MiniFramework table utilities
-- (GetSavedVars/CopyTable/CleanTable), since the migration semantics live in that combination.
-- The Migrator transforms every user's saved variables on upgrade - the black-box invariant is
-- "any input produces a valid current-version db".

local fw = require("framework")
local wow = require("wow_api")
wow.setup()
local acm = require("aura_container_mock")
acm.setup()

local addon = {
	Utils = {},
	Core = {},
	Modules = {},
	Config = {},
	L = setmetatable({}, {
		__index = function(_, key)
			return key
		end,
	}),
}

assert(loadfile("src/Core/MiniFramework.lua"))("MiniCC", addon)
-- ProfileManager before Migrator: UpgradeToVersion37 snapshots profiles via its PayloadKeys.
addon.Utils.Scheduler = { Init = function() end }
assert(loadfile("src/Core/ProfileManager.lua"))("MiniCC", addon)
assert(loadfile("src/Config/Migrator.lua"))("MiniCC", addon)

local migrator = addon.Config.Migrator

local function deepEquals(a, b, path)
	path = path or "root"
	if type(a) ~= type(b) then
		return false, path .. " type mismatch"
	end
	if type(a) ~= "table" then
		if a ~= b then
			return false, path .. " " .. tostring(a) .. " ~= " .. tostring(b)
		end
		return true
	end
	for key, value in pairs(a) do
		local ok, why = deepEquals(value, b[key], path .. "." .. tostring(key))
		if not ok then
			return false, why
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false, path .. "." .. tostring(key) .. " only in second"
		end
	end
	return true
end

local function deepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for key, value in pairs(t) do
		out[key] = deepCopy(value)
	end
	return out
end

-- The current schema version, discovered from a fresh install rather than hardcoded.
_G.MiniCCDB = nil
local LATEST_VERSION = migrator:GetAndUpgradeDb().Version
assert(type(LATEST_VERSION) == "number" and LATEST_VERSION >= 55, "sane latest version")

local expectedModules = {
	"CCModule", "PetCCModule", "HealerCCModule", "PortraitModule", "AlertsModule",
	"NameplatesModule", "KickTimerModule", "TrinketsModule", "FriendlyIndicatorModule",
	"PrecogGuesserModule", "FriendlyCooldownTrackerModule", "EnemyCooldownTrackerModule",
}

fw.describe("Migrator - fresh install", function()
	fw.before_each(function()
		_G.MiniCCDB = nil
	end)

	fw.it("produces the full current-version schema", function()
		local db = migrator:GetAndUpgradeDb()
		assert(db.Version == LATEST_VERSION)
		for _, name in ipairs(expectedModules) do
			assert(type(db.Modules[name]) == "table", "missing module defaults: " .. name)
		end
		assert(type(db.Modules.CCModule.Default.Icons.Size) == "number", "representative nested default")
		assert(db.GlowType == "Proc Glow" and type(db.FontScale) == "number", "top-level defaults")
	end)

	fw.it("is idempotent", function()
		local first = deepCopy(migrator:GetAndUpgradeDb())
		local second = migrator:GetAndUpgradeDb()
		local ok, why = deepEquals(first, second)
		assert(ok, "second run changed the db: " .. tostring(why))
	end)
end)

fw.describe("Migrator - arbitrary input safety", function()
	local fixtures = {
		["empty table"] = {},
		["unknown garbage"] = { Foo = "bar", Nested = { Junk = true } },
		["mid-history version with junk"] = { Version = 3, Whatever = 1 },
	}

	for label, fixture in pairs(fixtures) do
		fw.it("recovers to a valid current db from " .. label, function()
			_G.MiniCCDB = deepCopy(fixture)
			local db = migrator:GetAndUpgradeDb()
			assert(db.Version == LATEST_VERSION, label .. ": version healed")
			assert(type(db.Modules) == "table" and db.Modules.CCModule, label .. ": modules present")
			assert(db.Foo == nil and db.Whatever == nil, label .. ": unknown keys cleaned")
		end)
	end

	fw.it("a db from a NEWER version soft-resets but keeps recognized settings", function()
		_G.MiniCCDB = { Version = LATEST_VERSION + 100, FontScale = 1.4, Garbage = "x" }
		local db = migrator:GetAndUpgradeDb()
		assert(db.Version == LATEST_VERSION, "version reset to current")
		assert(db.FontScale == 1.4, "recognized custom value preserved")
		assert(db.Garbage == nil, "unknown key cleaned")
	end)
end)

fw.describe("Migrator - individual migrations", function()
	fw.it("v21 rewrites the removed Action Button Glow type", function()
		local vars = { Version = 20, GlowType = "Action Button Glow" }
		assert(migrator:UpgradeToVersion21(vars) == true)
		assert(vars.GlowType == "Proc Glow" and vars.Version == 21)
	end)

	fw.it("v21 leaves other glow types alone", function()
		local vars = { Version = 20, GlowType = "Pixel Glow" }
		assert(migrator:UpgradeToVersion21(vars) == true)
		assert(vars.GlowType == "Pixel Glow")
	end)

	fw.it("migrations refuse to run against the wrong source version", function()
		local vars = { Version = 5, GlowType = "Action Button Glow" }
		assert(migrator:UpgradeToVersion21(vars) == false, "wrong version must be rejected")
		assert(vars.GlowType == "Action Button Glow", "and must not mutate")
	end)
end)

fw.describe("Migrator - defaults helpers", function()
	fw.it("GetModuleDefaults returns isolated deep copies", function()
		local first = migrator:GetModuleDefaults()
		first.CCModule.Default.Icons.Size = 999
		local second = migrator:GetModuleDefaults()
		assert(second.CCModule.Default.Icons.Size ~= 999, "mutating one copy must not leak into the next")
	end)

	fw.it("FillDefaults adds missing keys without overwriting existing values", function()
		_G.MiniCCDB = nil
		local db = migrator:GetAndUpgradeDb()
		db.FontScale = 1.25
		db.Modules.CCModule.Default.Icons.Size = 48
		migrator:FillDefaults()
		assert(db.FontScale == 1.25 and db.Modules.CCModule.Default.Icons.Size == 48, "existing values kept")
		assert(db.Modules.AlertsModule ~= nil, "missing keys restored")
	end)
end)
