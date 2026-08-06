---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

addon.Modules.Precog = addon.Modules.Precog or {}

-- The engine plays the sound itself when a registered aura lands, which is the only way to hear
-- about precog at all: the addon is never allowed to read that the buff appeared, only to hand
-- secret values to secure setters. Registrations are per (unit, spellId) on the Added trigger.
-- The legacy path has no equivalent, so it stays silent - it cannot tell precog from any other
-- short important self-buff either.
--
-- TEMPORARY: this registration machinery is unreachable on BOTH eras. On 12.1 PrecogModule:Init
-- early-returns (the starter custom aura groups supersede the module), so Init/Refresh never run
-- and db stays nil; on 12.0 the USE_AURA_CONTAINERS guard below blocks it. Deliberately not
-- migrated onto Core/AuraSounds: the whole file dies with the module in the 12.0 removal.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local DEFAULT_SOUND = "ElectricalSpark.ogg"

---@type Db
local db
-- Handles of the live registrations, so they can be taken back down.
---@type number[]
local soundHandles = {}
-- The file and channel the live registrations were made with. Both are baked into each one, so a
-- change to either means tearing them down and registering again.
local registeredSignature

---@class PrecogSound
local M = {}
addon.Modules.Precog.Sound = M

local function ClearAuraSounds()
	for index = #soundHandles, 1, -1 do
		C_UnitAuras.RemoveAuraSound(soundHandles[index])
		soundHandles[index] = nil
	end

	registeredSignature = nil
end

---@param options PrecogModuleOptions
---@return string file
---@return string channel
local function ResolveSound(options)
	return addon.Core.Sounds:Resolve(options.Sound.File or DEFAULT_SOUND),
		options.Sound.Channel or "Master"
end

-- Public

---Reconciles the engine-side registrations against the current options. Cheap to call: it only
---does anything when the enabled state, the file or the channel has actually moved.
---@param spellIds table<number, boolean>  the auras to register, which the module owns
function M:Refresh(spellIds)
	if not USE_AURA_CONTAINERS or not db then
		return
	end

	local options = db.Modules.PrecogModule

	if not options or not options.Sound.Enabled or not moduleUtil:IsModuleEnabled(moduleName.Precog) then
		ClearAuraSounds()
		return
	end

	local soundFile, channel = ResolveSound(options)
	local signature = soundFile .. "|" .. channel

	if signature == registeredSignature then
		return
	end

	ClearAuraSounds()

	local info = {
		unitToken = "player",
		soundFileName = soundFile,
		outputChannel = channel,
	}

	for spellId in pairs(spellIds) do
		info.spellID = spellId

		local handle = C_UnitAuras.AddAuraSound(Enum.UnitAuraSoundTrigger.Added, info)

		if handle then
			soundHandles[#soundHandles + 1] = handle
		end
	end

	registeredSignature = signature
end

---Plays the configured file directly, ignoring the path gating. Used by the config preview, which
---has to demo the file even on 12.1 where the live sound is engine-side.
---@param options PrecogModuleOptions
function M:PlayPreview(options)
	local soundFile, channel = ResolveSound(options)

	PlaySoundFile(soundFile, channel)
end

function M:Clear()
	ClearAuraSounds()
end

function M:Init()
	db = mini:GetSavedVars()
end
