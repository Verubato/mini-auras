---@type string, Addon
local _, addon = ...
local sounds = addon.Core.Sounds

-- The engine plays the sound, because the addon is never told an aura landed. Registrations bake
-- in the file, so any change means handing them all back; hence the signature check in Apply.
--
-- They keep firing whether or not anything of ours is on screen, so a disabled group must Clear.

addon.Modules.CustomAuras = addon.Modules.CustomAuras or {}

-- Variants times triggers times visible plates reaches the thousands on a careless configuration.
local MAX_REGISTRATIONS = 400
-- Group sound keys to the engine trigger each registers against. Read through a fallback because
-- this file is loaded on 12.0.7 too, where the module never starts.
local TRIGGER_ENUM = Enum.UnitAuraSoundTrigger or {}
local TRIGGERS = {
	Applied = TRIGGER_ENUM.Added,
	Stacks = TRIGGER_ENUM.ApplicationsIncreased,
	Removed = TRIGGER_ENUM.Removed,
}

local EMPTY = {}

---@type number[]
local soundHandles = {}
local registeredSignature
local signatureParts = {}
local truncated = false

---@class CustomAurasSound
local M = {}

addon.Modules.CustomAuras.Sound = M

local function ClearAuraSounds()
	for index = #soundHandles, 1, -1 do
		C_UnitAuras.RemoveAuraSound(soundHandles[index])
		soundHandles[index] = nil
	end

	registeredSignature = nil
	truncated = false
end

---@param requests CustomAuraSoundRequest[]
---@return string
local function Signature(requests)
	wipe(signatureParts)

	for _, request in ipairs(requests) do
		signatureParts[#signatureParts + 1] = request.Unit
		signatureParts[#signatureParts + 1] = request.Trigger
		signatureParts[#signatureParts + 1] = request.File
		signatureParts[#signatureParts + 1] = request.Channel
		signatureParts[#signatureParts + 1] = table.concat(request.SpellIds, ",")
	end

	return table.concat(signatureParts, "|")
end

---Reconciles the engine-side registrations against what the groups want. One request is one
---(unit, sound) pairing over however many spell ids that group tracks.
---@param requests CustomAuraSoundRequest[]
function M:Apply(requests)
	local signature = Signature(requests)

	if signature == registeredSignature then
		return
	end

	ClearAuraSounds()

	local info = {}

	for _, request in ipairs(requests) do
		local trigger = TRIGGERS[request.Trigger]

		info.unitToken = request.Unit
		info.soundFileName = sounds:Resolve(request.File)
		info.outputChannel = request.Channel

		for _, spellId in ipairs(trigger and request.SpellIds or EMPTY) do
			if #soundHandles >= MAX_REGISTRATIONS then
				truncated = true
				break
			end

			info.spellID = spellId

			local handle = C_UnitAuras.AddAuraSound(trigger, info)

			if handle then
				soundHandles[#soundHandles + 1] = handle
			end
		end
	end

	registeredSignature = signature
end

---True when the last Apply hit the cap, so the silence can be explained.
---@return boolean
function M:WasTruncated()
	return truncated
end

---Plays a file directly for the options preview; the live sound is engine-side.
---@param file string
---@param channel string?
function M:PlayPreview(file, channel)
	PlaySoundFile(sounds:Resolve(file), channel or "Master")
end

function M:Clear()
	ClearAuraSounds()
end

---@class CustomAuraSoundRequest
---@field Unit string
---@field SpellIds number[]
---@field Trigger string A key of the group's Sound table: "Applied"|"Stacks"|"Removed".
---@field File string
---@field Channel string
