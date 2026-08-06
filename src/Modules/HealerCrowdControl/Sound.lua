---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local auraSounds = addon.Core.AuraSounds
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName

addon.Modules.HealerCrowdControl = addon.Modules.HealerCrowdControl or {}

---@class HealerCrowdControlSound
local M = {}
addon.Modules.HealerCrowdControl.Sound = M

-- 12.1 path: the sound survives via engine-side registrations (Core/AuraSounds) - the ENGINE
-- plays a sound when a known CC aura lands on a registered healer, without the addon ever
-- reading aura state. Registrations are per (unit, spellId), fed from the generated
-- Core/AuraCategoryIds CC list.
-- TEMPORARY dual path: remove the transition-driven branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type Db
local db
local soundFile
-- 12.1 path: sound handles keyed by healer unit, so a healer joining or leaving only
-- re-registers that unit. The CC spell list is ~1k entries, so a full teardown/rebuild of every
-- healer on each roster change was ~1k API calls per healer for no reason.
---@type table<string, number[]>
local registeredAuraSoundsByUnit = {}
-- The sound settings the current registrations were made with; when these change every healer is
-- re-registered (the unit set is handled incrementally).
local auraSoundSignature = nil

local function PlaySound()
	-- 12.1: sounds play engine-side via the AddAuraSound registrations (see RegisterAuraSounds);
	-- this legacy transition-based path must not double up.
	if USE_AURA_CONTAINERS then
		return
	end

	soundFile = addon.Core.Sounds:Resolve(db.Modules.HealerCCModule.Sound.File)
	PlaySoundFile(soundFile, db.Modules.HealerCCModule.Sound.Channel or "Master")
end

---12.1 path: removes one healer's registered aura sounds.
---@param unit string
local function RemoveUnitAuraSounds(unit)
	local ids = registeredAuraSoundsByUnit[unit]
	if not ids then
		return
	end

	registeredAuraSoundsByUnit[unit] = nil
	auraSounds:RemoveSet(ids)
end

---12.1 path: removes every registered aura sound.
local function ClearAuraSounds()
	for unit in pairs(registeredAuraSoundsByUnit) do
		RemoveUnitAuraSounds(unit)
	end
	auraSoundSignature = nil
end

---12.1 path: registers an engine-side sound for every known player CC spell on one healer.
---No-op when the unit is already registered - that is what keeps roster churn cheap.
---@param unit string
---@param soundFilePath string
---@param channel string
local function RegisterUnitAuraSounds(unit, soundFilePath, channel)
	if registeredAuraSoundsByUnit[unit] then
		return
	end

	registeredAuraSoundsByUnit[unit] =
		auraSounds:RegisterSet(nil, unit, addon.Core.AuraCategoryIds.CC, soundFilePath, channel)
end

---12.1 path: reconciles the engine-side CC sounds against the active healer set. The CC list is
---~1k spells, so this is strictly incremental: only healers that joined get registered and only
---those that left get removed. A change to the sound file/channel itself invalidates everything.
local function RegisterAuraSounds(activePool)
	local options = db.Modules.HealerCCModule
	local enabled = options.Sound.Enabled
		and moduleUtil:IsModuleEnabled(ModuleName.HealerCrowdControl)
		and next(activePool) ~= nil

	if not enabled then
		ClearAuraSounds()
		return
	end

	local soundFilePath = addon.Core.Sounds:Resolve(options.Sound.File)
	local channel = options.Sound.Channel or "Master"

	-- The sound itself is baked into each registration, so changing it means re-registering
	-- everyone; the healer set alone never does.
	local signature = auraSounds:Signature(soundFilePath, channel)
	if signature ~= auraSoundSignature then
		ClearAuraSounds()
		auraSoundSignature = signature
	end

	for unit in pairs(registeredAuraSoundsByUnit) do
		if not activePool[unit] then
			RemoveUnitAuraSounds(unit)
		end
	end

	for unit in pairs(activePool) do
		RegisterUnitAuraSounds(unit, soundFilePath, channel)
	end
end

---Legacy path: one sound per no-CC-to-CC transition.
function M:Play()
	PlaySound()
end

---Plays the configured file directly, ignoring the path gating. Used by the config preview,
---which has to demo the file even on 12.1 where the live sound is engine-side.
---@param options HealerCCModuleOptions
function M:PlayPreview(options)
	PlaySoundFile(addon.Core.Sounds:Resolve(options.Sound.File), options.Sound.Channel or "Master")
end

---12.1 path: reconciles the engine-side CC sounds against the active healer set.
---@param activePool table<string, HealerWatchEntry>
function M:Refresh(activePool)
	RegisterAuraSounds(activePool)
end

function M:Clear()
	ClearAuraSounds()
end

function M:Init()
	db = mini:GetSavedVars()
end
