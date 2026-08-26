---@type string, Addon
local _, addon = ...
local sounds = addon.Core.Sounds
local changeStamp = addon.Utils.ChangeStamp

-- The engine plays the sound, because the addon is never told an aura landed. Registrations bake
-- in the file, so a key whose file, channel or spell list moved has to be handed back and taken
-- out again.
--
-- The change check reads the resolved path rather than the saved name. A name from a media addon
-- resolves to nothing until that addon has loaded and registered it, so the same name has to be
-- able to read as changed later or the sound would stay wrong for the session.
--
-- They keep firing whether or not anything of ours is on screen, so a disabled group must Clear.

addon.Modules.PersonalAuras = addon.Modules.PersonalAuras or {}

-- Variants times triggers times visible plates reaches the thousands on a careless configuration.
local MAX_REGISTRATIONS = 1500
-- Group sound keys to the engine trigger each registers against.
local TRIGGER_ENUM = Enum.UnitAuraSoundTrigger or {}
local TRIGGERS = {
	Applied = TRIGGER_ENUM.Added,
	Stacks = TRIGGER_ENUM.ApplicationsIncreased,
	Removed = TRIGGER_ENUM.Removed,
}

local EMPTY = {}

---What the engine holds right now, by group, unit and trigger.
---@type table<string, PersonalAuraSoundKey>
local registered = {}
local requestStamp = changeStamp:New()
-- Handles across every key, compared against the cap.
local liveHandles = 0
-- Whether the last pass ran out of budget with keys still wanting ids.
local truncated = false
-- The keys this pass wants, so the sweep below can tell a gone key from an unchanged one.
---@type table<string, boolean>
local wantedKeys = {}
-- The keys still wanting ids, with how far this pass has read into each one's list and where an
-- id it could not place goes back. Parallel, drained a lap at a time, and empty between passes.
---@type PersonalAuraSoundKey[]
local pendingKeys = {}
---@type number[]
local pendingRead = {}
---@type number[]
local pendingWrite = {}
-- This pass's key per request, so the sweep can run ahead of the registrations without working
-- every key out twice.
---@type (string|false)[]
local requestKeys = {}
-- The path each sound name resolved to, wiped every pass so a media addon landing between two of
-- them can still change the answer.
---@type table<string|boolean, string|false>
local resolvedFiles = {}
-- Retired key records, each with both its lists already emptied, reused by the next new key.
---@type PersonalAuraSoundKey[]
local keyPool = {}
-- Reused UnitAuraSoundInfo; AddAuraSound reads it synchronously.
local infoScratch = { unitToken = nil, spellID = nil, soundFileName = nil, outputChannel = nil }

---@class PersonalAurasSound
local M = {}

addon.Modules.PersonalAuras.Sound = M

---@param request PersonalAuraSoundRequest
---@return string
local function KeyFor(request)
	return request.GroupId .. "|" .. request.Unit .. "|" .. request.Trigger
end

---The path a sound name maps to, worked out once per pass. Every request a group makes carries
---the same name, and resolving one runs a media lookup.
---@param name string?
---@return string?
local function ResolveOnce(name)
	-- False, because nil cannot be a table key.
	local key = name or false
	local resolved = resolvedFiles[key]

	if resolved == nil then
		-- False rather than nil, so a name nothing has registered memoises as a miss.
		resolved = sounds:ResolveStrict(name) or false
		resolvedFiles[key] = resolved
	end

	return resolved or nil
end

---Hands back everything one key holds, leaving it empty and ready to register again.
---@param entry PersonalAuraSoundKey
local function ReleaseHandles(entry)
	local handles = entry.Handles

	liveHandles = liveHandles - #handles

	-- Wrapped like the add is. A throw part way would strand the rest of the list registered with
	-- the count already saying they are gone.
	for index = #handles, 1, -1 do
		pcall(C_UnitAuras.RemoveAuraSound, handles[index])
		handles[index] = nil
	end
end

---@param key string
local function Forget(key)
	local entry = registered[key]

	ReleaseHandles(entry)
	wipe(entry.Wanted)

	registered[key] = nil
	requestStamp:Forget(key)
	keyPool[#keyPool + 1] = entry
end

---@param key string
---@param file string? the resolved path, nil while the media addon that owns it is missing
---@param request PersonalAuraSoundRequest
---@return number
local function StampFor(key, file, request)
	requestStamp:Begin(key)
	requestStamp:Add(file or false)
	requestStamp:Add(request.Channel)

	local spellIds = request.SpellIds

	requestStamp:Add(#spellIds)

	for index = 1, #spellIds do
		requestStamp:Add(spellIds[index])
	end

	return requestStamp:Commit()
end

---Points a key at a fresh spell list, every id of it still wanting a handle.
---@param entry PersonalAuraSoundKey
---@param spellIds number[]
local function RefillWanted(entry, spellIds)
	local wanted = entry.Wanted

	for index = 1, #spellIds do
		wanted[index] = spellIds[index]
	end

	for index = #wanted, #spellIds + 1, -1 do
		wanted[index] = nil
	end
end

---Closes a pass's walk of one key's list, leaving the ids it still has no handle for. The tail it
---never reached moves down to join the ones it was refused.
---@param wanted number[]
---@param read number the first id the pass did not reach
---@param write number where the next id it keeps goes
local function TrimWanted(wanted, read, write)
	for index = read, #wanted do
		wanted[write] = wanted[index]
		write = write + 1
	end

	for index = #wanted, write, -1 do
		wanted[index] = nil
	end
end

---Offers the pending keys a spell id apiece per lap, so a key with a long list cannot eat the
---whole budget before the keys behind it have had any.
---@param pending number
---@return number remaining keys the budget could not reach
local function DrainPending(pending)
	local remaining = pending

	while remaining > 0 and liveHandles < MAX_REGISTRATIONS do
		local kept = 0

		for index = 1, remaining do
			local entry = pendingKeys[index]
			local wanted = entry.Wanted
			local read = pendingRead[index]

			if read <= #wanted and liveHandles < MAX_REGISTRATIONS then
				local info = infoScratch

				info.unitToken = entry.Unit
				info.soundFileName = entry.File
				info.outputChannel = entry.Channel
				info.spellID = wanted[read]

				-- Reported throwing now and again, with no cause found. Combat lockdown is not it,
				-- since this call is allowed there.
				local ok, handle = pcall(C_UnitAuras.AddAuraSound, entry.Trigger, info)

				if ok and handle then
					entry.Handles[#entry.Handles + 1] = handle
					liveHandles = liveHandles + 1
				else
					-- Kept, so the next pass offers this id again and nothing else.
					local write = pendingWrite[index]

					wanted[write] = wanted[read]
					pendingWrite[index] = write + 1
				end

				read = read + 1
				pendingRead[index] = read
			end

			if read > #wanted then
				TrimWanted(wanted, read, pendingWrite[index])
			else
				kept = kept + 1
				pendingKeys[kept] = entry
				pendingRead[kept] = read
				pendingWrite[kept] = pendingWrite[index]
			end
		end

		for index = kept + 1, remaining do
			pendingKeys[index] = nil
			pendingRead[index] = nil
			pendingWrite[index] = nil
		end

		remaining = kept
	end

	return remaining
end

---Reconciles the engine-side registrations against what the groups want. One request is one
---(group, unit, trigger) pairing over however many spell ids that group tracks, and a key whose
---request reads the same as last time keeps the handles it already has.
---@param requests PersonalAuraSoundRequest[]
function M:Apply(requests)
	wipe(wantedKeys)
	wipe(requestKeys)
	wipe(resolvedFiles)

	for index, request in ipairs(requests) do
		local key = KeyFor(request)

		-- One key named twice would queue its entry twice and register everything it wants twice
		-- over, so the aura would sound twice.
		requestKeys[index] = not wantedKeys[key] and key or false
		wantedKeys[key] = true
	end

	-- Ahead of the registrations, so a key that has gone gives its room to the ones that stay.
	for key in pairs(registered) do
		if not wantedKeys[key] then
			Forget(key)
		end
	end

	local pending = 0

	for index, request in ipairs(requests) do
		local key = requestKeys[index]

		if key then
			-- Nothing has registered this name yet, so the key stays silent rather than taking
			-- the fallback sound.
			local file = ResolveOnce(request.File)
			local stamp = StampFor(key, file, request)
			local entry = registered[key]

			if not entry then
				entry = table.remove(keyPool) or { Handles = {}, Wanted = {} }
				entry.Stamp = nil
				registered[key] = entry
			end

			if entry.Stamp ~= stamp then
				local trigger = TRIGGERS[request.Trigger]

				-- The file is baked into every handle, so nothing this one holds is any use once
				-- the request behind it has moved.
				ReleaseHandles(entry)

				entry.Stamp = stamp
				entry.Unit = request.Unit
				entry.Trigger = trigger
				entry.File = file
				entry.Channel = request.Channel

				RefillWanted(entry, file and trigger and request.SpellIds or EMPTY)
			end

			if #entry.Wanted > 0 then
				pending = pending + 1
				pendingKeys[pending] = entry
				pendingRead[pending] = 1
				pendingWrite[pending] = 1
			end
		end
	end

	local remaining = DrainPending(pending)

	truncated = remaining > 0

	for index = 1, remaining do
		TrimWanted(pendingKeys[index].Wanted, pendingRead[index], pendingWrite[index])

		pendingKeys[index] = nil
		pendingRead[index] = nil
		pendingWrite[index] = nil
	end
end

---True while the cap is what stands between a key and everything it asked for, so the silence
---can be explained.
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
	for key in pairs(registered) do
		Forget(key)
	end

	truncated = false
end

---@class PersonalAuraSoundRequest
---@field GroupId string Part of the key, so two groups wanting the same sound on the same unit
---keep their own registrations.
---@field Unit string
---@field SpellIds number[]
---@field Trigger string A key of the group's Sound table: "Applied"|"Stacks"|"Removed".
---@field File string
---@field Channel string

---@class PersonalAuraSoundKey
---@field Handles number[] What the engine gave back, one per spell id it accepted.
---@field Wanted number[] The spell ids it has no handle for yet, whether the engine refused them
---or the budget never reached them.
---@field Stamp number? The stamp of the request Handles and Wanted were built from.
---@field Unit string
---@field Trigger number?
---@field File string?
---@field Channel string
