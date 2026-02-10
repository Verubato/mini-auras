---@type string, Addon
local _, addon = ...
local capabilities = addon.Capabilities

local maxAuras = 40
local ccFilter = capabilities:HasNewFilters() and "HARMFUL|CROWD_CONTROL" or "HARMFUL|INCLUDE_NAME_PLATE_ONLY"
local importantHelpfulFilter = capabilities:HasNewFilters() and "HELPFUL|IMPORTANT" or "HELPFUL|INCLUDE_NAME_PLATE_ONLY"
local importantHarmfulFilter = capabilities:HasNewFilters() and "HARMFUL|IMPORTANT" or "HARMFUL|INCLUDE_NAME_PLATE_ONLY"

---@class UnitAuraWatcher
local M = {}
addon.Core.UnitAuraWatcher = M

---@param watcher Watcher
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
---@return boolean
local function MightAffectOurFilters(updateInfo)
	if not updateInfo then
		return true
	end

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

local function WatcherFrameOnEvent(frame, event, ...)
	local watcher = frame.Watcher
	if not watcher then
		return
	end
	watcher:OnEvent(event, ...)
end

local Watcher = {}
Watcher.__index = Watcher

function Watcher:GetUnit()
	return self.State.Unit
end

---@param callback fun(self: Watcher)
function Watcher:RegisterCallback(callback)
	if not callback then
		return
	end
	self.State.Callbacks[#self.State.Callbacks + 1] = callback
end

function Watcher:IsEnabled()
	return self.State.Enabled
end

function Watcher:Enable()
	if self.State.Enabled then
		return
	end

	local frame = self.Frame
	if not frame then
		return
	end

	frame:RegisterUnitEvent("UNIT_AURA", self.State.Unit)

	if self.State.Events then
		for _, event in ipairs(self.State.Events) do
			frame:RegisterEvent(event)
		end
	end

	self.State.Enabled = true
end

function Watcher:Disable()
	if not self.State.Enabled then
		return
	end

	local frame = self.Frame
	if frame then
		frame:UnregisterAllEvents()
	end

	self.State.Enabled = false
end

---@param notify boolean?
function Watcher:ClearState(notify)
	local state = self.State
	state.CcAuraState = {}
	state.ImportantAuraState = {}
	state.DefensiveState = {}

	if notify then
		NotifyCallbacks(self)
	end
end

function Watcher:ForceFullUpdate()
	-- force a rebuild immediately
	self:OnEvent("UNIT_AURA", self.State.Unit, { isFullUpdate = true })
end

function Watcher:Dispose()
	local frame = self.Frame
	if frame then
		frame:UnregisterAllEvents()
		frame:SetScript("OnEvent", nil)
		frame.Watcher = nil
	end
	self.Frame = nil

	-- ensure we don't keep references alive
	self.State.Callbacks = {}
	self:ClearState(false)
end

---@return AuraInfo[]
function Watcher:GetCcState()
	return self.State.CcAuraState
end

---@return AuraInfo[]
function Watcher:GetImportantState()
	return self.State.ImportantAuraState
end

---@return AuraInfo[]
function Watcher:GetDefensiveState()
	return self.State.DefensiveState
end

function Watcher:RebuildStates()
	local unit = self.State.Unit

	if not unit then
		return
	end

	local interestedIn = self.State.InterestedIn
	local interestedInDefensives = not interestedIn or (interestedIn and interestedIn.Defensives)
	local interestedInCC = not interestedIn or (interestedIn and interestedIn.CC)
	local interestedInImportant = not interestedIn or (interestedIn and interestedIn.Important)

	---@type AuraInfo[]
	local ccSpellData = {}
	---@type AuraInfo[]
	local importantSpellData = {}
	---@type AuraInfo[]
	local defensivesSpellData = {}
	local seenDefensives = {}

	-- process big defensives first so we can exclude duplicates from important
	if interestedInDefensives and capabilities:HasNewFilters() then
		for i = 1, maxAuras do
			local defensivesData =
				C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL|BIG_DEFENSIVE|INCLUDE_NAME_PLATE_ONLY")

			if defensivesData then
				local durationInfo = C_UnitAuras.GetAuraDuration(unit, defensivesData.auraInstanceID)
				local start = durationInfo and durationInfo:GetStartTime()
				local duration = durationInfo and durationInfo:GetTotalDuration()

				if start and duration then
					defensivesSpellData[#defensivesSpellData + 1] = {
						IsDefensive = true,
						SpellId = defensivesData.spellId,
						SpellIcon = defensivesData.icon,
						StartTime = start,
						TotalDuration = duration,
					}
				end

				seenDefensives[defensivesData.auraInstanceID] = true
			end
		end
	end

	if interestedInCC or interestedInImportant then
		for i = 1, maxAuras do
			local ccData = interestedInCC and C_UnitAuras.GetAuraDataByIndex(unit, i, ccFilter)

			if ccData then
				local durationInfo = C_UnitAuras.GetAuraDuration(unit, ccData.auraInstanceID)
				local start = durationInfo and durationInfo:GetStartTime()
				local duration = durationInfo and durationInfo:GetTotalDuration()

				if start and duration then
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
			end

			local importantHelpfulData = interestedInImportant
				and C_UnitAuras.GetAuraDataByIndex(unit, i, importantHelpfulFilter)
			if importantHelpfulData and not seenDefensives[importantHelpfulData.auraInstanceID] then
				local isImportant = C_Spell.IsSpellImportant(importantHelpfulData.spellId)
				local durationInfo = C_UnitAuras.GetAuraDuration(unit, importantHelpfulData.auraInstanceID)
				local start = durationInfo and durationInfo:GetStartTime()
				local duration = durationInfo and durationInfo:GetTotalDuration()

				if start and duration then
					importantSpellData[#importantSpellData + 1] = {
						IsImportant = capabilities:HasNewFilters() or isImportant,
						SpellId = importantHelpfulData.spellId,
						SpellIcon = importantHelpfulData.icon,
						StartTime = start,
						TotalDuration = duration,
					}
				end
			end

			-- avoid doubling up with cc data, as both CC and HARMFUL return the same thing sometimes
			local importantHarmfulData = interestedInImportant
				and not ccData
				and C_UnitAuras.GetAuraDataByIndex(unit, i, importantHarmfulFilter)
			if importantHarmfulData and not seenDefensives[importantHarmfulData.auraInstanceID] then
				local isImportant = C_Spell.IsSpellImportant(importantHarmfulData.spellId)
				local durationInfo = C_UnitAuras.GetAuraDuration(unit, importantHarmfulData.auraInstanceID)
				local start = durationInfo and durationInfo:GetStartTime()
				local duration = durationInfo and durationInfo:GetTotalDuration()

				if start and duration then
					importantSpellData[#importantSpellData + 1] = {
						IsImportant = capabilities:HasNewFilters() or isImportant,
						SpellId = importantHarmfulData.spellId,
						SpellIcon = importantHarmfulData.icon,
						StartTime = start,
						TotalDuration = duration,
					}
				end
			end
		end
	end

	local state = self.State
	state.CcAuraState = ccSpellData
	state.ImportantAuraState = importantSpellData
	state.DefensiveState = defensivesSpellData
end

function Watcher:OnEvent(event, ...)
	local state = self.State

	if event == "UNIT_AURA" then
		local unit, updateInfo = ...
		if unit and unit ~= state.Unit then
			return
		end
		if not MightAffectOurFilters(updateInfo) then
			return
		end
	elseif event == "ARENA_OPPONENT_UPDATE" then
		local unit = ...
		if unit ~= state.Unit then
			return
		end
	end

	if not state.Unit then
		return
	end

	self:RebuildStates()
	NotifyCallbacks(self)
end

---@param unit string
---@param events string[]?
---@param interestedIn AuraTypeFilter?
---@return Watcher
function M:New(unit, events, interestedIn)
	if not unit then
		error("unit must not be nil")
	end

	---@type Watcher
	local watcher = setmetatable({
		Frame = nil,
		State = {
			Unit = unit,
			Events = events,
			Enabled = false,
			Callbacks = {},
			CcAuraState = {},
			ImportantAuraState = {},
			DefensiveState = {},
			InterestedIn = interestedIn,
		},
	}, Watcher)

	local frame = CreateFrame("Frame")
	frame.Watcher = watcher
	frame:SetScript("OnEvent", WatcherFrameOnEvent)

	watcher.Frame = frame
	watcher:Enable()

	-- Prime once to get initial state
	watcher:ForceFullUpdate()

	return watcher
end

---@class AuraTypeFilter
---@field CC boolean?
---@field Important boolean?
---@field Defensive boolean?

---@class AuraInfo
---@field IsImportant? boolean
---@field IsCC? boolean
---@field IsDefensive? boolean
---@field SpellId number?
---@field SpellIcon string?
---@field TotalDuration number?
---@field StartTime number?

---@class WatcherState
---@field Unit string
---@field Events string[]?
---@field Enabled boolean
---@field Callbacks (fun(self: Watcher))[]
---@field CcAuraState AuraInfo[]
---@field ImportantAuraState AuraInfo[]
---@field DefensiveState AuraInfo[]
---@field InterestedIn AuraTypeFilter

---@class Watcher
---@field Frame Frame?
---@field State WatcherState
---@field GetCcState fun(self: Watcher): AuraInfo[]
---@field GetImportantState fun(self: Watcher): AuraInfo[]
---@field GetDefensiveState fun(self: Watcher): AuraInfo[]
---@field RegisterCallback fun(self: Watcher, callback: fun(self: Watcher))
---@field GetUnit fun(self: Watcher): string
---@field IsEnabled fun(self: Watcher): boolean
---@field Enable fun(self: Watcher)
---@field Disable fun(self: Watcher)
---@field ClearState fun(self: Watcher, notify: boolean?)
---@field ForceFullUpdate fun(self: Watcher)
---@field Dispose fun(self: Watcher)
