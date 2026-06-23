-- Simulated aura store + WoW aura-API mocks for testing the REAL UnitAuraWatcher.
--
-- The watcher's aura pipeline (full rebuild + the incremental delta path) is otherwise untestable:
-- the regular test loader stubs the whole watcher. This harness backs C_UnitAuras / C_Spell with a
-- per-unit aura table so the real watcher can be driven with UNIT_AURA deltas and its state verified
-- against a full rebuild (the oracle) via M.assertConsistent.
--
-- Aura shape (passed to M.addAura):
--   { id=<number>, spellId=<number>, name=<string?>, icon=<any?>, duration=<any?>,
--     helpful=bool, harmful=bool, bigDefensive=bool, externalDefensive=bool, crowdControl=bool }

local fw  = require("framework")
local wow = require("wow_api")

local M = {}

-- store[unit][auraInstanceID] = aura
local store = {}
local deadUnits = {}
local absentUnits = {}
local seqCounter = 0

-- Counts full-unit re-queries so tests can assert the incremental path avoids them.
M.getUnitAurasCalls = 0

-- Does an aura match a watcher filter string? (Only the filters the watcher queries.)
local function matches(aura, filter)
	if filter == "HELPFUL" then
		return aura.helpful == true
	elseif filter == "HELPFUL|BIG_DEFENSIVE" then
		return aura.helpful == true and aura.bigDefensive == true
	elseif filter == "HELPFUL|EXTERNAL_DEFENSIVE" then
		return aura.helpful == true and aura.externalDefensive == true
	elseif filter == "HARMFUL|CROWD_CONTROL" then
		return aura.harmful == true and aura.crowdControl == true
	end
	return false
end

-- Returns matching auras ordered the way the API would. The watcher re-sorts Unsorted results by
-- AuraInstanceID itself, so the only order that must be reproduced incrementally is the "applied
-- sequence" order used for Default; we key that on `seq` (assignment order), independent of `id`.
local function sortedAuras(unit, filter, sortDir)
	local list = {}
	local u = store[unit]
	if u then
		for _, aura in pairs(u) do
			if matches(aura, filter) then
				list[#list + 1] = aura
			end
		end
	end
	local reverse = sortDir == 1 -- Enum.UnitAuraSortDirection.Reverse
	table.sort(list, function(a, b)
		if reverse then
			return a.seq > b.seq
		end
		return a.seq < b.seq
	end)
	return list
end

local constDispelColor = { r = 0, g = 0, b = 0, a = 1 }

local function installGlobals()
	_G.DEBUFF_TYPE_NONE_COLOR    = { r = 0.8, g = 0.8, b = 0.8 }
	_G.DEBUFF_TYPE_MAGIC_COLOR   = { r = 0.2, g = 0.6, b = 1.0 }
	_G.DEBUFF_TYPE_CURSE_COLOR   = { r = 0.6, g = 0.0, b = 1.0 }
	_G.DEBUFF_TYPE_DISEASE_COLOR = { r = 0.6, g = 0.4, b = 0.0 }
	_G.DEBUFF_TYPE_POISON_COLOR  = { r = 0.0, g = 0.6, b = 0.0 }
	_G.DEBUFF_TYPE_BLEED_COLOR   = { r = 1.0, g = 0.2, b = 0.2 }

	_G.Enum = _G.Enum or {}
	_G.Enum.UnitAuraSortRule      = { Default = 0, Unsorted = 1 }
	_G.Enum.UnitAuraSortDirection = { Normal = 0, Reverse = 1 }
	_G.Enum.LuaCurveType          = { Step = 0 }

	_G.C_CurveUtil = {
		CreateColorCurve = function()
			return { SetType = function() end, AddPoint = function() end }
		end,
	}

	_G.C_Spell = _G.C_Spell or {}
	_G.C_Spell.IsSpellCrowdControl = function(spellId)
		-- Reflects the same fact the CROWD_CONTROL filter encodes: any aura with this spellId is CC.
		for _, u in pairs(store) do
			for _, aura in pairs(u) do
				if aura.spellId == spellId then return aura.crowdControl == true end
			end
		end
		return false
	end

	_G.UnitExists = function(unit) return not absentUnits[unit] end
	_G.UnitIsDeadOrGhost = function(unit) return deadUnits[unit] == true end

	_G.C_UnitAuras = {
		GetUnitAuras = function(unit, filter, _max, _sortRule, sortDir)
			M.getUnitAurasCalls = M.getUnitAurasCalls + 1
			return sortedAuras(unit, filter, sortDir)
		end,
		GetUnitAuraInstanceIDs = function(unit, filter, _max, _sortRule, sortDir)
			local auras = sortedAuras(unit, filter, sortDir)
			local ids = {}
			for i, aura in ipairs(auras) do
				ids[i] = aura.id
			end
			return ids
		end,
		GetAuraDataByAuraInstanceID = function(unit, id)
			return store[unit] and store[unit][id] or nil
		end,
		GetAuraDuration = function(unit, id)
			local aura = store[unit] and store[unit][id]
			return aura and aura.duration
		end,
		GetAuraDispelTypeColor = function()
			return constDispelColor
		end,
		AuraIsBigDefensive = function(spellId)
			for _, u in pairs(store) do
				for _, aura in pairs(u) do
					if aura.spellId == spellId then return aura.bigDefensive == true end
				end
			end
			return false
		end,
		IsAuraFilteredOutByInstanceID = function(unit, id, filter)
			local aura = store[unit] and store[unit][id]
			if not aura then return true end
			return not matches(aura, filter)
		end,
	}
end

-- Set up base + aura globals, then load the REAL watcher (once).
wow.setup()
installGlobals()

local addon = { Core = {} }
assert(loadfile("src/Core/UnitAuraWatcher.lua"))("MiniCC", addon)
M.watcher = addon.Core.UnitAuraWatcher

function M.reset()
	store = {}
	deadUnits = {}
	absentUnits = {}
	seqCounter = 0
	M.getUnitAurasCalls = 0
	wow.reset()      -- clears base mock state (resets C_UnitAuras to the partial stub)
	installGlobals() -- re-install the full aura mocks the watcher needs
end

-- Store control --------------------------------------------------------------

---@param aura table aura with at least .id and .spellId; sets defaults for the rest.
function M.addAura(unit, aura)
	assert(aura.id, "aura needs id")
	aura.auraInstanceID = aura.id
	aura.name = aura.name or ("spell" .. tostring(aura.spellId))
	aura.icon = aura.icon or aura.spellId
	if aura.duration == nil then
		aura.duration = { remaining = 10 } -- opaque non-nil so the watcher keeps it
	end
	seqCounter = seqCounter + 1
	aura.seq = seqCounter
	store[unit] = store[unit] or {}
	store[unit][aura.id] = aura
	return aura
end

function M.removeAura(unit, id)
	if store[unit] then store[unit][id] = nil end
end

function M.updateAura(unit, id, changes)
	local aura = store[unit] and store[unit][id]
	if aura then
		for k, v in pairs(changes) do aura[k] = v end
	end
end

function M.setDead(unit, dead) deadUnits[unit] = dead ~= false end
function M.setAbsent(unit, absent) absentUnits[unit] = absent ~= false end
M.markSecret = wow.markSecret

-- Watcher driving ------------------------------------------------------------

function M.newWatcher(unit, events, interestedIn, sortRule, sortDir)
	return M.watcher:New(unit, events, interestedIn, sortRule, sortDir)
end

-- Fires a UNIT_AURA with an updateInfo built from a delta spec:
--   { full=true } | { added={id,...}, updated={id,...}, removed={id,...} }
-- `added` ids must already exist in the store; `removed` ids should already be gone.
function M.fire(watcher, unit, delta)
	local info = {}
	if delta.full then
		info.isFullUpdate = true
	end
	if delta.added then
		info.addedAuras = {}
		for _, id in ipairs(delta.added) do
			local aura = assert(store[unit] and store[unit][id], "added aura must exist in store: " .. tostring(id))
			info.addedAuras[#info.addedAuras + 1] = aura
		end
	end
	if delta.updated then info.updatedAuraInstanceIDs = delta.updated end
	if delta.removed then info.removedAuraInstanceIDs = delta.removed end
	watcher:OnEvent("UNIT_AURA", unit, info)
end

-- Verification ---------------------------------------------------------------

local function serialize(list)
	local out = {}
	for i, e in ipairs(list) do
		out[i] = string.format("%s(cc=%s,def=%s)", tostring(e.AuraInstanceID), tostring(e.IsCC), tostring(e.IsDefensive))
	end
	return table.concat(out, ",")
end

function M.snapshot(watcher)
	return {
		cc   = serialize(watcher:GetCcState()),
		def  = serialize(watcher:GetDefensiveState()),
		buff = serialize(watcher:GetBuffState()),
	}
end

-- Asserts the watcher's current (incrementally-built) state equals a full rebuild of the same store.
-- Leaves the watcher resynced to the full-rebuild state.
function M.assertConsistent(watcher, label)
	label = label or ""
	local inc = M.snapshot(watcher)
	watcher:ForceFullUpdate()
	local full = M.snapshot(watcher)
	fw.eq(inc.cc, full.cc, label .. " [cc] incremental == full")
	fw.eq(inc.def, full.def, label .. " [def] incremental == full")
	fw.eq(inc.buff, full.buff, label .. " [buff] incremental == full")
end

return M
