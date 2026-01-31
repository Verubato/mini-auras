---@type string, Addon
local _, addon = ...
local capabilities = addon.Capabilities
local maxAuras = 40

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

local function OnEvent(watcher)
	local unit = watcher.State.Unit
	local filter = watcher.State.Filter

	if not unit or not filter then
		return
	end

	local auraInstanceId
	local ccApplied
	local ccSpellId
	local ccSpellIcon
	local ccStartTime
	local ccTotalDuration

	for i = 1, maxAuras do
		local data = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)

		if data then
			local isCC = C_Spell.IsSpellCrowdControl(data.spellId)
			local durationInfo = C_UnitAuras.GetAuraDuration(unit, data.auraInstanceID)
			local start = durationInfo and durationInfo:GetStartTime()
			local duration = durationInfo and durationInfo:GetTotalDuration()

			if capabilities:SupportsCrowdControlFiltering() then
				ccApplied = true
				auraInstanceId = data.auraInstanceID
				ccSpellId = data.spellId
				ccSpellIcon = data.icon
				ccStartTime = start
				ccTotalDuration = duration
				-- don't break here
				-- keep iterating as we might find another more recent CC
			else
				ccApplied = ccApplied or {}
				ccApplied[#ccApplied + 1] = isCC
			end
		end
	end

	---@type WatcherState
	local state = watcher.State

	if capabilities:SupportsCrowdControlFiltering() then
		state.LastAuraInstanceId = auraInstanceId
		state.IsCcApplied = ccApplied
		state.CcSpellId = ccSpellId
		state.CcSpellIcon = ccSpellIcon
		state.CcTotalDuration = ccTotalDuration
		state.CcStartTime = ccStartTime
		NotifyCallbacks(watcher)
	else
		state.IsCcApplied = ccApplied
		NotifyCallbacks(watcher)
	end
end

---@param unit string
---@param filter string?
---@param events string[]?
---@return Watcher
function M:New(unit, filter, events)
	if not unit then
		error("unit must not be nil")
	end

	if not filter then
		if capabilities:SupportsCrowdControlFiltering() then
			filter = "HARMFUL|CROWD_CONTROL"
		else
			filter = "HARMFUL|INCLUDE_NAME_PLATE_ONLY"
		end
	end

	local watcher = {
		---@class WatcherState
		State = {
			Unit = unit,
			Filter = filter,
			Paused = false,
			Callbacks = {},
		},
		RegisterCallback = function(watcherSelf, callback)
			if not callback then
				return
			end

			---@diagnostic disable-next-line: undefined-field
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
			return watcherSelf.State
		end,
	}

	local frame = CreateFrame("Frame")
	frame:RegisterUnitEvent("UNIT_AURA", unit)

	if events then
		for _, event in ipairs(events) do
			frame:RegisterEvent(event)
		end
	end

	frame:SetScript("OnEvent", function()
		OnEvent(watcher)
	end)

	return watcher
end

---@class Watcher
---@field GetCcState fun(self: Watcher): AuraInfo
---@field RegisterCallback fun(self: Watcher, callback: fun(self: Watcher))
---@field IsPaused fun(self: Watcher)
---@field Pause fun(self: Watcher)
---@field Resume fun(self: Watcher)

---@class WatcherState : AuraInfo
---@field Unit string
---@field Filter string
---@field Paused boolean
---@field Callbacks fun()[]
---@field LastAuraInstanceId number?
---@field CcAuras AuraInfo[]

---@class AuraInfo
---@field IsCcApplied? boolean|boolean[]
---@field CcSpellId number?
---@field CcSpellIcon string?
---@field CcTotalDuration number?
---@field CcStartTime number?
