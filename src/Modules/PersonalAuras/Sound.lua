---@type string, Addon
local _, addon = ...
local sounds = addon.Core.Sounds
local changeStamp = addon.Utils.ChangeStamp

-- The engine plays the sound, because the addon is never told an aura landed. Registrations bake
-- in the file, so any change means handing them all back.
--
-- The change check in Apply reads the resolved path rather than the saved name. A name from a
-- media addon resolves to nothing until that addon has loaded and registered it, so the same name
-- has to be able to read as changed later or the sound would stay wrong for the session.
--
-- They keep firing whether or not anything of ours is on screen, so a disabled group must Clear.

addon.Modules.PersonalAuras = addon.Modules.PersonalAuras or {}

-- Variants times triggers times visible plates reaches the thousands on a careless configuration.
local MAX_REGISTRATIONS = 400
-- Group sound keys to the engine trigger each registers against.
local TRIGGER_ENUM = Enum.UnitAuraSoundTrigger or {}
local TRIGGERS = {
	Applied = TRIGGER_ENUM.Added,
	Stacks = TRIGGER_ENUM.ApplicationsIncreased,
	Removed = TRIGGER_ENUM.Removed,
}

local EMPTY = {}
-- One registration set for the module, so one key.
local REQUESTS_KEY = "PersonalAuraSounds"

---@type number[]
local soundHandles = {}
local requestStamp = changeStamp:New()
local registeredGeneration
local truncated = false
-- Resolved path per request, filled at the top of Apply and read by both the change check and the
-- registration loop, so a request is only resolved once per pass. Parallel to the requests array.
---@type table<number, string?>
local resolvedFiles = {}

---@class PersonalAurasSound
local M = {}

addon.Modules.PersonalAuras.Sound = M

local function ClearAuraSounds()
	for index = #soundHandles, 1, -1 do
		C_UnitAuras.RemoveAuraSound(soundHandles[index])
		soundHandles[index] = nil
	end

	registeredGeneration = nil
	truncated = false
end

---@param requests PersonalAuraSoundRequest[]
---@return number
local function RequestsGeneration(requests)
	requestStamp:Begin(REQUESTS_KEY)

	for index, request in ipairs(requests) do
		requestStamp:Add(request.Unit)
		requestStamp:Add(request.Trigger)
		-- The path rather than the name, so a sound that could not be resolved on an earlier pass
		-- re-registers once its media addon shows up.
		requestStamp:Add(resolvedFiles[index] or false)
		requestStamp:Add(request.Channel)

		local spellIds = request.SpellIds

		requestStamp:Add(#spellIds)

		for i = 1, #spellIds do
			requestStamp:Add(spellIds[i])
		end
	end

	return requestStamp:Commit()
end

---Reconciles the engine-side registrations against what the groups want. One request is one
---(unit, sound) pairing over however many spell ids that group tracks.
---@param requests PersonalAuraSoundRequest[]
function M:Apply(requests)
	wipe(resolvedFiles)

	for index, request in ipairs(requests) do
		resolvedFiles[index] = sounds:ResolveStrict(request.File)
	end

	local generation = RequestsGeneration(requests)

	if generation == registeredGeneration then
		return
	end

	ClearAuraSounds()

	local info = {}

	for index, request in ipairs(requests) do
		local trigger = TRIGGERS[request.Trigger]
		-- Nothing has registered this name yet, so the group stays silent rather than taking the
		-- fallback sound. The retry picks it up as soon as the media addon lands.
		local file = resolvedFiles[index]

		info.unitToken = request.Unit
		info.soundFileName = file
		info.outputChannel = request.Channel

		for _, spellId in ipairs(file and trigger and request.SpellIds or EMPTY) do
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

	registeredGeneration = generation
end

---True when the last Apply hit the cap, so the silence can be explained.
---@return boolean
function M:WasTruncated()
	return truncated
end

---Plays a file directly for the options preview, while the live sound is engine-side.
---@param file string
---@param channel string?
function M:PlayPreview(file, channel)
	PlaySoundFile(sounds:Resolve(file), channel or "Master")
end

function M:Clear()
	ClearAuraSounds()
end

---@class PersonalAuraSoundRequest
---@field Unit string
---@field SpellIds number[]
---@field Trigger string A key of the group's Sound table: "Applied"|"Stacks"|"Removed".
---@field File string
---@field Channel string
