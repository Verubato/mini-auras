---@type string, Addon
local _, addon = ...
local maxAuras = 40

-- Dispel type color mapping
local dispelColours = {
	-- https://wago.tools/db2/SpellDispelType
	[0] = DEBUFF_TYPE_NONE_COLOR,
	[1] = DEBUFF_TYPE_MAGIC_COLOR,
	[2] = DEBUFF_TYPE_CURSE_COLOR,
	[3] = DEBUFF_TYPE_DISEASE_COLOR,
	[4] = DEBUFF_TYPE_POISON_COLOR,
	[11] = DEBUFF_TYPE_BLEED_COLOR,
}
local dispelColorCurve

local function InitColourCurve()
	if dispelColorCurve then
		return
	end

	dispelColorCurve = C_CurveUtil.CreateColorCurve()
	dispelColorCurve:SetType(Enum.LuaCurveType.Step)

	for type, colour in pairs(dispelColours) do
		dispelColorCurve:AddPoint(type, colour)
	end
end

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

---@param unit string
---@param filter string
---@param callback fun(auraData: table, start: number, duration: number, dispelColor: table)
local function IterateAuras(unit, filter, callback)
	for i = 1, maxAuras do
		local auraData = C_UnitAuras.GetAuraDataByIndex(unit, i, filter)

		if not auraData then
			break
		end

		local durationInfo = C_UnitAuras.GetAuraDuration(unit, auraData.auraInstanceID)
		local start = durationInfo and durationInfo:GetStartTime()
		local duration = durationInfo and durationInfo:GetTotalDuration()

		if start and duration then
			local dispelColor = C_UnitAuras.GetAuraDispelTypeColor(unit, auraData.auraInstanceID, dispelColorCurve)
			callback(auraData, start, duration, dispelColor)
		end
	end
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
	local seen = {}

	-- process big defensives first so we can exclude duplicates from important
	if interestedInDefensives then
		IterateAuras(unit, "HELPFUL|BIG_DEFENSIVE", function(auraData, start, duration, dispelColor)
			-- units out of range produce garbage data, so double check
			local isDefensive = C_UnitAuras.AuraIsBigDefensive(auraData.spellId)

			if issecretvalue(isDefensive) or isDefensive then
				defensivesSpellData[#defensivesSpellData + 1] = {
					IsDefensive = isDefensive,
					SpellId = auraData.spellId,
					SpellName = auraData.name,
					SpellIcon = auraData.icon,
					StartTime = start,
					TotalDuration = duration,
					DispelColor = dispelColor,
					AuraInstanceID = auraData.auraInstanceID,
				}
			end

			seen[auraData.auraInstanceID] = true
		end)

		IterateAuras(unit, "HELPFUL|EXTERNAL_DEFENSIVE", function(auraData, start, duration, dispelColor)
			if not seen[auraData.auraInstanceID] then
				defensivesSpellData[#defensivesSpellData + 1] = {
					IsDefensive = true,
					SpellId = auraData.spellId,
					SpellName = auraData.name,
					SpellIcon = auraData.icon,
					StartTime = start,
					TotalDuration = duration,
					DispelColor = dispelColor,
					AuraInstanceID = auraData.auraInstanceID,
				}

				seen[auraData.auraInstanceID] = true
			end
		end)
	end

	if interestedInCC then
		IterateAuras(unit, "HARMFUL|CROWD_CONTROL", function(auraData, start, duration, dispelColor)
			seen[auraData.auraInstanceID] = true

			ccSpellData[#ccSpellData + 1] = {
				IsCC = true,
				SpellId = auraData.spellId,
				SpellName = auraData.name,
				SpellIcon = auraData.icon,
				StartTime = start,
				TotalDuration = duration,
				DispelColor = dispelColor,
				AuraInstanceID = auraData.auraInstanceID,
			}
		end)
	end

	if interestedInImportant then
		IterateAuras(unit, "HELPFUL|IMPORTANT", function(auraData, start, duration, dispelColor)
			if not seen[auraData.auraInstanceID] then
				local isImportant = C_Spell.IsSpellImportant(auraData.spellId)

				importantSpellData[#importantSpellData + 1] = {
					IsImportant = isImportant,
					SpellId = auraData.spellId,
					SpellName = auraData.name,
					SpellIcon = auraData.icon,
					StartTime = start,
					TotalDuration = duration,
					DispelColor = dispelColor,
					AuraInstanceID = auraData.auraInstanceID,
				}

				seen[auraData.auraInstanceID] = true
			end
		end)
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

InitColourCurve()

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
---@field SpellName string?
---@field TotalDuration number?
---@field StartTime number?
---@field DispelColor table?
---@field AuraInstanceID number?

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
---@field Frame table?
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
