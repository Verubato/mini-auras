-- Loads Brain.lua and Rules.lua with all WoW and addon dependencies mocked.
-- Returns a singleton: call loader.get() from any test file to access the loaded modules.
--
-- Returned table fields:
--   .brain    CooldownBrain  (addon.Modules.Cooldowns.Brain)
--   .observer mock Observer with ._fire* helpers
--   .talents  mock Talents with ._set* helpers
--   .rules    loaded CooldownRules table

local wow = require("wow_api")
wow.setup()   -- initialise WoW globals before any module is loaded

local M = {}

-- Mock Talents

local function makeTalents()
	local talentData = {}   -- unit -> { [talentId] = true/false }
	local specIds    = {}   -- unit -> specId

	local t = {}

	function t:UnitHasTalent(unit, talentId, callerSpecId)
		local d = talentData[unit]
		return d ~= nil and d[talentId] == true
	end

	function t:GetUnitSpecId(unit)
		return specIds[unit]
	end

	-- Default: return the base value unchanged (no talent modifiers).
	function t:GetUnitBuffDuration(unit, specId, classToken, abilityId, baseDuration)
		return baseDuration
	end

	function t:GetUnitCooldown(unit, specId, classToken, abilityId, baseCooldown, measuredDuration)
		return baseCooldown
	end

	function t:RegisterTalentCallback(fn) end

	-- Test helpers

	function t._setTalent(unit, talentId, has)
		talentData[unit] = talentData[unit] or {}
		talentData[unit][talentId] = has ~= false
	end

	function t._setSpec(unit, specId)
		specIds[unit] = specId
	end

	function t._reset()
		talentData = {}
		specIds    = {}
	end

	return t
end

-- Mock Observer

local function makeObserver()
	local cbs = {
		auraChanged    = {},
		cast           = {},
		shield         = {},
		unitFlags      = {},
		debuffEvidence = {},
	}

	local o = {}

	function o:RegisterAuraChangedCallback(fn)
		cbs.auraChanged[#cbs.auraChanged + 1] = fn
	end
	function o:RegisterCastCallback(fn)
		cbs.cast[#cbs.cast + 1] = fn
	end
	function o:RegisterShieldCallback(fn)
		cbs.shield[#cbs.shield + 1] = fn
	end
	function o:RegisterUnitFlagsCallback(fn)
		cbs.unitFlags[#cbs.unitFlags + 1] = fn
	end
	function o:RegisterDebuffEvidenceCallback(fn)
		cbs.debuffEvidence[#cbs.debuffEvidence + 1] = fn
	end

	-- Fire helpers (called from tests to simulate events)

	function o:_fireCast(unit, spellId)
		for _, fn in ipairs(cbs.cast) do fn(unit, spellId) end
	end

	function o:_fireShield(unit)
		for _, fn in ipairs(cbs.shield) do fn(unit) end
	end

	function o:_fireUnitFlags(unit)
		for _, fn in ipairs(cbs.unitFlags) do fn(unit) end
	end

	function o:_fireDebuffEvidence(unit, updateInfo)
		for _, fn in ipairs(cbs.debuffEvidence) do fn(unit, updateInfo) end
	end

	function o:_fireAuraChanged(entry, watcher, candidateUnits)
		for _, fn in ipairs(cbs.auraChanged) do fn(entry, watcher, candidateUnits) end
	end

	return o
end

-- Module loader

local function loadModule(path, addonTable)
	local fn, err = loadfile(path)
	if not fn then
		error("loader: failed to open " .. path .. ": " .. tostring(err))
	end
	fn("MiniCC", addonTable)
end

local _cache = nil

---Returns the loaded module set, loading everything on first call.
function M.get()
	if _cache then return _cache end

	local addon = {
		Modules = { Cooldowns = {} },
		Core = {
			UnitAuraWatcher = {
				New = function(self, unit, filter, types)
					return {
						RegisterCallback    = function() end,
						Dispose             = function() end,
						Disable             = function() end,
						Enable              = function() end,
						ForceFullUpdate     = function() end,
						GetDefensiveState   = function() return {} end,
						GetImportantState   = function() return {} end,
					}
				end,
			},
		},
		Utils = {},
	}

	local talents  = makeTalents()
	local observer = makeObserver()
	addon.Modules.Cooldowns.Talents  = talents
	addon.Modules.Cooldowns.Observer = observer

	-- Rules is a pure data file — load it for real.
	loadModule("src/Modules/Cooldowns/Rules.lua", addon)

	-- Brain registers its observer callbacks via RegisterWithObserver.
	loadModule("src/Modules/Cooldowns/Brain.lua", addon)

	local brain = addon.Modules.Cooldowns.Brain
	local rules = addon.Modules.Cooldowns.Rules

	brain:RegisterWithObserver(observer)

	_cache = {
		brain    = brain,
		observer = observer,
		talents  = talents,
		rules    = rules,
	}
	return _cache
end

-- Helpers shared by test files

---Creates a minimal FcdWatchEntry for use in tests.
---@param unit string
---@param activeCooldowns table?
function M.makeEntry(unit, activeCooldowns)
	return {
		Unit              = unit,
		TrackedAuras      = {},
		ActiveCooldowns   = activeCooldowns or {},
		PredictedGlows    = {},
		PredictedGlowDurations = {},
		IsExcludedSelf    = false,
		Container         = {
			Frame = { IsVisible = function() return true end },
		},
	}
end

---Creates a minimal FcdTrackedAura for use in tests.
---@param startTime number
---@param auraTypes table<string,boolean>
---@param evidence table?
---@param castSnapshot table?
---@param castSpellIdSnapshot table?
function M.makeTracked(startTime, auraTypes, evidence, castSnapshot, castSpellIdSnapshot)
	return {
		StartTime            = startTime,
		AuraTypes            = auraTypes,
		Evidence             = evidence,
		CastSnapshot         = castSnapshot         or {},
		CastSpellIdSnapshot  = castSpellIdSnapshot  or {},
	}
end

---Creates a mock watcher whose GetDefensiveState and GetImportantState return the given lists.
---Each aura is a table with at least AuraInstanceID (and optionally DurationObject).
function M.makeWatcher(defensiveAuras, importantAuras)
	return {
		GetDefensiveState = function(self) return defensiveAuras or {} end,
		GetImportantState = function(self) return importantAuras or {} end,
	}
end

return M
