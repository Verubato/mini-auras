-- Stubs for WoW global APIs needed by Brain.lua and Observer.lua.
-- Must be required before loading any addon module.

local M = {}

-- Module-level state reset on each M.reset() call.
local _time          = 0
local _buildNumber   = 110000  -- default: pre-12.0.5 (TOC 110000)
local _unitClasses   = {}   -- unit -> { name, token }
local _feignDeath    = {}   -- unit -> bool
local _auraFiltered  = {}   -- "unit:id:filter" -> bool  (true = filtered out = absent)
local _secretValues  = {}   -- value -> bool (treated as secret)
local _unitExists    = {}   -- unit -> bool

function M.setup()
	-- Build info
	-- Returns the current fake build number as the 4th return value (the one
	-- Brain.lua reads via  select(4, GetBuildInfo()) >= 120005).
	_G.GetBuildInfo = function()
		return "0.0.0", "0", "Jan 1 2020", _buildNumber
	end

	-- Time
	_G.GetTime = function() return _time end

	-- Unit queries
	_G.UnitExists = function(unit)
		return _unitExists[unit] == true
	end

	_G.UnitClass = function(unit)
		local c = _unitClasses[unit]
		return c and c.name or nil, c and c.token or nil
	end

	_G.UnitIsFeignDeath = function(unit)
		return _feignDeath[unit] == true
	end

	-- UnitCanAttack: default false (units are friendly) unless overridden per test.
	_G.UnitCanAttack = function(a, b) return false end

	-- UnitIsUnit: simple string equality (sufficient for tests).
	_G.UnitIsUnit = function(a, b) return a == b end

	-- Aura filter
	-- Returns true when the aura is NOT present under that filter (i.e. filtered out).
	-- Default: nothing is filtered out (every aura passes every filter).
	_G.C_UnitAuras = {
		IsAuraFilteredOutByInstanceID = function(unit, id, filter)
			local key = unit .. ":" .. tostring(id) .. ":" .. filter
			local v = _auraFiltered[key]
			return v == true   -- nil -> false (not filtered = visible)
		end,
	}

	-- Secret values
	-- In a test environment all values are non-secret unless explicitly marked.
	_G.issecretvalue = function(v)
		return _secretValues[v] == true
	end

	-- Timer: execute deferred callbacks synchronously
	_G.C_Timer = {
		After = function(delay, fn) fn() end,
	}

	-- Frame stub
	_G.CreateFrame = function(frameType, name, parent)
		local f = {}
		local _events = {}
		f.SetScript = function(self, event, fn)
			_events[event] = fn
		end
		f.TriggerEvent = function(self, event, ...)   -- test helper
			if _events[event] then _events[event](self, event, ...) end
		end
		f.RegisterUnitEvent   = function() end
		f.RegisterEvent       = function() end
		f.UnregisterAllEvents = function() end
		f.IsVisible           = function() return true end
		f.GetFrameStrata      = function() return "MEDIUM" end
		f.GetFrameLevel       = function() return 1 end
		f.SetFrameStrata      = function() end
		f.SetFrameLevel       = function() end
		f.ClearAllPoints      = function() end
		f.SetPoint            = function() end
		f.SetAlpha            = function() end
		return f
	end
end

-- Control helpers

function M.setTime(t)          _time = t          end
function M.advanceTime(dt)     _time = _time + dt end
function M.getTime()           return _time       end

function M.setUnitClass(unit, classToken)
	local names = {
		PALADIN = "Paladin", WARRIOR = "Warrior", MAGE = "Mage",
		HUNTER = "Hunter",   PRIEST  = "Priest",  ROGUE = "Rogue",
		DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman", WARLOCK = "Warlock",
		MONK = "Monk", DEMONHUNTER = "Demon Hunter",
		DRUID = "Druid", EVOKER = "Evoker",
	}
	_unitClasses[unit] = { name = names[classToken] or classToken, token = classToken }
end

function M.clearUnitClass(unit)
	_unitClasses[unit] = nil
end

function M.setFeignDeath(unit, state)
	_feignDeath[unit] = state == true
end

---Mark aura `id` on `unit` as filtered out (= absent) for the given filter string.
---Passing filtered=false (or omitting) makes it visible (= present).
function M.setAuraFiltered(unit, id, filter, filtered)
	local key = unit .. ":" .. tostring(id) .. ":" .. filter
	_auraFiltered[key] = filtered ~= false and filtered ~= nil
end

---Mark a Lua value as a secret (issecretvalue returns true for it).
function M.markSecret(v)
	_secretValues[v] = true
end

---Set the TOC build number returned by GetBuildInfo (4th return value).
---Call before loading any module that reads GetBuildInfo() at module scope.
function M.setBuildNumber(n)
	_buildNumber = n
	_G.GetBuildInfo = function()
		return "0.0.0", "0", "Jan 1 2020", n
	end
end

function M.setUnitExists(unit, exists)
	_unitExists[unit] = exists ~= false
end

-- Reset

function M.reset()
	_time         = 0
	_buildNumber  = 110000
	_unitClasses  = {}
	_feignDeath   = {}
	_auraFiltered = {}
	_secretValues = {}
	_unitExists   = {}
	M.setup()
end

return M
