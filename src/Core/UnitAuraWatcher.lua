---@type string, Addon
local _, addon = ...
local capabilities = addon.Capabilities
local maxAuras = 40
local ccFilter = capabilities:HasNewFilters() and "HARMFUL|CROWD_CONTROL" or "HARMFUL|INCLUDE_NAME_PLATE_ONLY"

---@class UnitAuraWatcher
local M = {}
addon.UnitAuraWatcher = M

local function NotifyCallbacks(watcher)
	local callbacks = watcher.State.Callbacks
	if not callbacks or #callbacks == 0 then
		return
	end
	for _, callback in ipairs(callbacks) do
		callback(watcher)
	end
end

---Quick check using updateInfo to avoid scanning every time.
---Return true if updateInfo suggests there might be relevant changes.
local function MightAffectOurFilters(updateInfo)
	if not updateInfo then
		return true
	end

	-- If anything was removed/added/updated we probably care.
	if updateInfo.isFullUpdate then
		return true
	end

	if
		(updateInfo.addedAuras and #updateInfo.addedAuras > 0)
		or (updateInfo.updatedAuras and #updateInfo.updatedAuras > 0)
		or (updateInfo.removedAuraInstanceIDs and #updateInfo.removedAuraInstanceIDs > 0)
	then
		return true
	end

	return false
end

local function RebuildStates(watcher)
	local unit = watcher.State.Unit
	if not unit then
		return
	end

	---@type AuraInfo[]
	local ccSpellData = {}
	---@type AuraInfo[]
	local importantSpellData = {}
	---@type AuraInfo[]
	local defensivesSpellData = {}

	for i = 1, maxAuras do
		local ccData = C_UnitAuras.GetAuraDataByIndex(unit, i, ccFilter)

		if ccData then
			local durationInfo = C_UnitAuras.GetAuraDuration(unit, ccData.auraInstanceID)
			local start = durationInfo and durationInfo:GetStartTime()
			local duration = durationInfo and durationInfo:GetTotalDuration()

			if capabilities:HasNewFilters() then
				ccSpellData[#ccSpellData + 1] = {
					IsCC = true,
					SpellId = ccData.spellId,
					SpellIcon = ccData.icon,
					StartTime = start,
					TotalDuration = duration,
				}
			else
				local isCC = C_Spell.IsSpellCrowdControl(ccData.spellId)
				ccSpellData[#ccSpellData + 1] = {
					IsCC = isCC,
					SpellId = ccData.spellId,
					SpellIcon = ccData.icon,
					StartTime = start,
					TotalDuration = duration,
				}
			end
		end

		if capabilities:HasNewFilters() then
			local defensivesData = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL|BIG_DEFENSIVE")
			if defensivesData then
				local durationInfo = C_UnitAuras.GetAuraDuration(unit, defensivesData.auraInstanceID)
				local start = durationInfo and durationInfo:GetStartTime()
				local duration = durationInfo and durationInfo:GetTotalDuration()

				defensivesSpellData[#defensivesSpellData + 1] = {
					IsDefensive = true,
					SpellId = defensivesData.spellId,
					SpellIcon = defensivesData.icon,
					StartTime = start,
					TotalDuration = duration,
				}
			end
		end

		local importantHelpfulData = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
		if importantHelpfulData then
			local isImportant = C_Spell.IsSpellImportant(importantHelpfulData.spellId)
			local durationInfo = C_UnitAuras.GetAuraDuration(unit, importantHelpfulData.auraInstanceID)
			local start = durationInfo and durationInfo:GetStartTime()
			local duration = durationInfo and durationInfo:GetTotalDuration()

			importantSpellData[#importantSpellData + 1] = {
				IsImportant = isImportant,
				SpellId = importantHelpfulData.spellId,
				SpellIcon = importantHelpfulData.icon,
				StartTime = start,
				TotalDuration = duration,
			}
		end

		-- avoid doubling up with cc data
		local importantHarmfulData = not ccData and C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
		if importantHarmfulData then
			local isImportant = C_Spell.IsSpellImportant(importantHarmfulData.spellId)
			local durationInfo = C_UnitAuras.GetAuraDuration(unit, importantHarmfulData.auraInstanceID)
			local start = durationInfo and durationInfo:GetStartTime()
			local duration = durationInfo and durationInfo:GetTotalDuration()

			importantSpellData[#importantSpellData + 1] = {
				IsImportant = isImportant,
				SpellId = importantHarmfulData.spellId,
				SpellIcon = importantHarmfulData.icon,
				StartTime = start,
				TotalDuration = duration,
			}
		end
	end

	---@type WatcherState
	local state = watcher.State
	state.CcAuraState = ccSpellData
	state.ImportantAuraState = importantSpellData
	state.DefensiveState = defensivesSpellData
end

local function OnEvent(watcher, event, unit, updateInfo)
	local state = watcher.State
	if state.Paused then
		return
	end

	if event == "UNIT_AURA" then
		if unit and unit ~= state.Unit then
			return
		end

		if not MightAffectOurFilters(updateInfo) then
			return
		end
	end

	local u = state.Unit

	if not u then
		return
	end

	RebuildStates(watcher)
	NotifyCallbacks(watcher)
end

---@param unit string
---@param events string[]?
---@return Watcher
function M:New(unit, events)
	if not unit then
		error("unit must not be nil")
	end

	local watcher = {
		---@class WatcherState
		State = {
			Unit = unit,
			Paused = false,
			Callbacks = {},
			CcAuraState = {},
			ImportantAuraState = {},
			DefensiveState = {},
		},
		RegisterCallback = function(watcherSelf, callback)
			if not callback then
				return
			end
			watcherSelf.State.Callbacks[#watcherSelf.State.Callbacks + 1] = callback
		end,
		Pause = function(watcherSelf)
			watcherSelf.State.Paused = true
		end,
		Resume = function(watcherSelf)
			watcherSelf.State.Paused = false
		end,
		IsPaused = function(watcherSelf)
			return watcherSelf.State.Paused
		end,
		GetCcState = function(watcherSelf)
			return watcherSelf.State.CcAuraState
		end,
		GetImportantState = function(watcherSelf)
			return watcherSelf.State.ImportantAuraState
		end,
		GetDefensiveState = function(watcherSelf)
			return watcherSelf.State.DefensiveState
		end,
	}

	local frame = CreateFrame("Frame")
	frame:RegisterUnitEvent("UNIT_AURA", unit)

	if events then
		for _, event in ipairs(events) do
			frame:RegisterEvent(event)
		end
	end

	frame:SetScript("OnEvent", function(_, event, ...)
		OnEvent(watcher, event, ...)
	end)

	-- Prime once we get initial state
	OnEvent(watcher, "UNIT_AURA", unit, { isFullUpdate = true })

	return watcher
end
---@class Watcher
---@field GetCcState fun(self: Watcher): AuraInfo[]
---@field GetImportantState fun(self: Watcher): AuraInfo[]
---@field GetDefensiveState fun(self: Watcher): AuraInfo[]
---@field RegisterCallback fun(self: Watcher, callback: fun(self: Watcher))
---@field IsPaused fun(self: Watcher)
---@field Pause fun(self: Watcher)
---@field Resume fun(self: Watcher)

---@class WatcherState
---@field Unit string
---@field Filter string
---@field Paused boolean
---@field Callbacks fun()[]
---@field CcAuras AuraInfo[]
---@field ImportantAuras AuraInfo[]

---@class AuraInfo
---@field IsImportant? boolean
---@field IsCC? boolean
---@field IsDefensive? boolean
---@field SpellId number?
---@field SpellIcon string?
---@field TotalDuration number?
---@field StartTime number?
