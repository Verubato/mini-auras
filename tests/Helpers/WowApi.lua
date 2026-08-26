-- Stubs for the WoW global APIs the tests need.
-- Must be required before loading any addon module.

local M = {}

-- Module-level state reset on each M.reset() call.
local _time          = 0
local _buildNumber   = 120005  -- 12.0.5
local _instanceType  = "none"  -- not in any instance
local _unitClasses   = {}   -- unit -> { name, token }
local _feignDeath    = {}   -- unit -> bool
local _pvpUnits      = {}   -- unit -> bool (pvp-flagged, e.g. War Mode in open world)
local _auraFiltered  = {}   -- "unit:id:filter" -> bool  (true = filtered out = absent)
local _secretValues  = {}   -- value -> bool (treated as secret)
local _unitExists    = {}   -- unit -> bool
local _unitGuids     = {}   -- unit -> guid string override
local _roles         = {}   -- unit -> "TANK" | "HEALER" | "DAMAGER"
local _inRaid        = false
local _locale        = "enUS"

function M.setup()
	-- Blizzard's own deep copy, which addons rely on.
	_G.CopyTable = function(source)
		local out = {}

		for key, value in pairs(source) do
			out[key] = type(value) == "table" and _G.CopyTable(value) or value
		end

		return out
	end

	-- The build number is the 4th return value, tested as select(4, GetBuildInfo()) >= 120005.
	_G.GetBuildInfo = function()
		return "0.0.0", "0", "Jan 1 2020", _buildNumber
	end

	-- instanceType is "none", "party", "raid", "scenario", "arena", or "pvp".
	_G.IsInInstance = function()
		return _instanceType ~= "none", _instanceType
	end

	_G.GetTime = function() return _time end

	_G.GetLocale = function() return _locale end

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

	_G.UnitIsPVP = function(unit)
		return _pvpUnits[unit] == true
	end

	-- Units are friendly unless a test overrides this.
	_G.UnitCanAttack = function(a, b) return false end

	_G.UnitIsUnit = function(a, b) return a == b end

	-- Group and roles. A unit counts as grouped once it has been given a role, which is the
	-- only thing anything here asks about a roster.
	_G.IsInGroup = function()
		return next(_roles) ~= nil
	end

	_G.IsInRaid = function()
		return _inRaid
	end

	_G.UnitGroupRolesAssigned = function(unit)
		return _roles[unit] or "NONE"
	end

	-- Each unit gets a unique GUID unless setUnitGUID aliases two of them to one player.
	_G.UnitGUID = function(unit)
		return _unitGuids[unit] or unit
	end

	_G.UnitIsConnected = function(unit) return true end

	-- Returns true when the aura is absent under that filter.
	_G.C_UnitAuras = {
		IsAuraFilteredOutByInstanceID = function(unit, id, filter)
			local key = unit .. ":" .. tostring(id) .. ":" .. filter
			local v = _auraFiltered[key]
			if v ~= nil then return v == true end
			-- Both CC filter variants default to filtered out, so setAuraFiltered(..., false) is what
			-- marks an aura as CC.
			-- HARMFUL|CROWD_CONTROL: hostile self-CCs (e.g. Dispersion).
			-- HELPFUL|CROWD_CONTROL: friendly CCs applied to an ally (e.g. Time Stop).
			if filter == "HARMFUL|CROWD_CONTROL" or filter == "HELPFUL|CROWD_CONTROL" then return true end
			return false
		end,
	}

	-- In a test environment all values are non-secret unless explicitly marked.
	_G.issecretvalue = function(v)
		return _secretValues[v] == true
	end

	-- WoW's global for emptying a table in place.
	_G.wipe = function(t)
		for k in next, t do t[k] = nil end
		return t
	end

	-- Deferred callbacks run straight away.
	_G.C_Timer = {
		After = function(delay, fn) fn() end,
	}

	-- The clock the background sweep bounds a tick against. Frozen, so no tick runs out of budget.
	_G.debugprofilestop = function() return 0 end

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
		f.GetLeft             = function() end
		f.GetRight            = function() end
		f.GetCenter           = function() end
		return f
	end
end

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

---Mark aura `id` on `unit` as absent for the given filter string.
---Passing filtered=false or omitting it makes the aura present.
function M.setAuraFiltered(unit, id, filter, filtered)
	local key = unit .. ":" .. tostring(id) .. ":" .. filter
	_auraFiltered[key] = filtered ~= false and filtered ~= nil
end

---Mark a Lua value as secret and hand it back, so it can be marked inline where it is used.
function M.markSecret(v)
	_secretValues[v] = true
	return v
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

---Pass the same guid to two unit strings to simulate one player under several unit IDs.
function M.setUnitGUID(unit, guid)
	_unitGuids[unit] = guid
end

---Puts a unit in the group with a role. The unit is made to exist too, since a roster entry
---that UnitExists denies is not a state the client can be in.
---@param unit string
---@param role string? "TANK", "HEALER", "DAMAGER", or nil to remove them.
function M.setRole(unit, role)
	_roles[unit] = role

	M.setUnitExists(unit, role ~= nil)
end

---@param inRaid boolean
function M.setInRaid(inRaid)
	_inRaid = inRaid
end

---@param locale string
function M.setLocale(locale)
	_locale = locale
end

function M.clearRoles()
	for unit in pairs(_roles) do
		M.setUnitExists(unit, false)
	end

	_roles = {}
	_inRaid = false
end

function M.setUnitPvp(unit, state)
	_pvpUnits[unit] = state == true or nil
end

function M.setInstanceType(t)
	_instanceType = t
	_G.IsInInstance = function()
		return t ~= "none", t
	end
end

function M.reset()
	_time          = 0
	_buildNumber   = 110000
	_instanceType  = "none"
	_unitClasses   = {}
	_feignDeath    = {}
	_pvpUnits      = {}
	_auraFiltered  = {}
	_secretValues  = {}
	_unitExists    = {}
	_unitGuids     = {}
	_locale        = "enUS"
	M.setup()
end

return M
