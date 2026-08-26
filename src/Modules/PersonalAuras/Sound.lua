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
-- Consecutive short passes before a key is left alone until what it wants changes. Without it a
-- registration the engine will never accept costs a call on every nameplate coming and going.
local MAX_ATTEMPTS = 3
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
-- Keys holding fewer handles than they asked for because the cap ran out.
local cappedKeys = 0
-- The keys this pass wants, so the sweep below can tell a gone key from an unchanged one.
---@type table<string, boolean>
local wantedKeys = {}
-- The keys still owing registrations, with the spell ids each wants and how far through them it
-- is. Parallel, drained a lap at a time, and empty between passes.
---@type PersonalAuraSoundKey[]
local pendingKeys = {}
---@type number[][]
local pendingSpells = {}
---@type number[]
local pendingCursor = {}
-- This pass's key per request, so the sweep can run ahead of the registrations without working
-- every key out twice.
---@type (string|false)[]
local requestKeys = {}
-- Retired key records, each with its handle list already emptied, reused by the next new key.
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

---Hands back everything one key holds, leaving it empty and ready to register again.
---@param entry PersonalAuraSoundKey
local function ReleaseHandles(entry)
	local handles = entry.Handles

	liveHandles = liveHandles - #handles

	for index = #handles, 1, -1 do
		C_UnitAuras.RemoveAuraSound(handles[index])
		handles[index] = nil
	end

	if entry.Capped then
		entry.Capped = false
		cappedKeys = cappedKeys - 1
	end

	entry.Stamp = nil
end

---@param key string
local function Forget(key)
	local entry = registered[key]

	ReleaseHandles(entry)

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

---Records a key that has run out of spell ids, so a full set counts as done and a short one
---leaves the stamp unrecorded for the next pass to try again.
---@param entry PersonalAuraSoundKey
---@param asked number
local function Settle(entry, asked)
	-- It reached the end of its list, so the budget is not cutting this one short any more.
	if entry.Capped then
		entry.Capped = false
		cappedKeys = cappedKeys - 1
	end

	if #entry.Handles == asked then
		entry.Stamp = entry.TriedStamp
		entry.Attempts = 0
	else
		entry.Attempts = entry.Attempts + 1
	end
end

---Registers the pending keys a spell id apiece per lap, so a group with a long spell list cannot
---eat the whole budget before the groups behind it have had any.
---@param pending number
---@return number remaining keys the budget could not reach
local function DrainPending(pending)
	local remaining = pending

	while remaining > 0 and liveHandles < MAX_REGISTRATIONS do
		local kept = 0

		for index = 1, remaining do
			local entry = pendingKeys[index]
			local spells = pendingSpells[index]
			local cursor = pendingCursor[index]

			if cursor <= #spells and liveHandles < MAX_REGISTRATIONS then
				local info = infoScratch

				info.unitToken = entry.Unit
				info.soundFileName = entry.File
				info.outputChannel = entry.Channel
				info.spellID = spells[cursor]

				local handle = C_UnitAuras.AddAuraSound(entry.Trigger, info)

				if handle then
					entry.Handles[#entry.Handles + 1] = handle
					liveHandles = liveHandles + 1
				end

				cursor = cursor + 1
			end

			if cursor > #spells then
				Settle(entry, #spells)
			else
				kept = kept + 1
				pendingKeys[kept] = entry
				pendingSpells[kept] = spells
				pendingCursor[kept] = cursor
			end
		end

		for index = kept + 1, remaining do
			pendingKeys[index] = nil
			pendingSpells[index] = nil
			pendingCursor[index] = nil
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

	-- Room has opened up since the pass that ran out of it, so let the keys it cut off ask for
	-- the rest of what they wanted.
	if cappedKeys > 0 and liveHandles < MAX_REGISTRATIONS then
		for _, entry in pairs(registered) do
			if entry.Capped then
				entry.Stamp = nil
			end
		end
	end

	local pending = 0

	for index, request in ipairs(requests) do
		local key = requestKeys[index]

		if key then
			-- Nothing has registered this name yet, so the key stays silent rather than taking
			-- the fallback sound. The stamp carries the path, so it registers once the media
			-- addon lands.
			local file = sounds:ResolveStrict(request.File)
			local stamp = StampFor(key, file, request)
			local entry = registered[key]

			if not entry then
				entry = table.remove(keyPool) or { Handles = {} }
				entry.Stamp = nil
				entry.TriedStamp = nil
				entry.Attempts = 0
				entry.Capped = false
				entry.Cursor = 1
				registered[key] = entry
			end

			if entry.Stamp ~= stamp then
				local moved = entry.TriedStamp ~= stamp

				if moved then
					entry.TriedStamp = stamp
					entry.Attempts = 0
				end

				if entry.Attempts < MAX_ATTEMPTS then
					local trigger = TRIGGERS[request.Trigger]
					local spells = file and trigger and request.SpellIds or EMPTY
					-- A key the budget cut off keeps what it holds and picks up where it stopped.
					-- A refused one starts again, because the ids the engine turned down are
					-- scattered through the list.
					local resume = not moved and entry.Capped and entry.Cursor <= #spells

					if not resume then
						ReleaseHandles(entry)
					end

					entry.Unit = request.Unit
					entry.Trigger = trigger
					entry.File = file
					entry.Channel = request.Channel

					pending = pending + 1
					pendingKeys[pending] = entry
					pendingSpells[pending] = spells
					pendingCursor[pending] = resume and entry.Cursor or 1
				end
			end
		end
	end

	local remaining = DrainPending(pending)

	for index = 1, remaining do
		local entry = pendingKeys[index]

		-- Cut off by the budget rather than refused, so it does not count against the attempts.
		if not entry.Capped then
			entry.Capped = true
			cappedKeys = cappedKeys + 1
		end

		entry.Cursor = pendingCursor[index]
		entry.Stamp = entry.TriedStamp
		pendingKeys[index] = nil
		pendingSpells[index] = nil
		pendingCursor[index] = nil
	end
end

---True while some key holds fewer registrations than it asked for because of the cap, so the
---silence can be explained.
---@return boolean
function M:WasTruncated()
	return cappedKeys > 0
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
---@field Stamp number? The stamp the handles satisfy, nil while the key still owes registrations.
---@field TriedStamp number? The stamp Attempts is counted against.
---@field Attempts number Consecutive passes that came up short of what the key asked for.
---@field Capped boolean Whether the budget, rather than a refusal, is what cut it short.
---@field Cursor number How far through its spell list it got, so a key the budget cut off can
---pick up from there rather than start again.
---@field Unit string
---@field Trigger number?
---@field File string?
---@field Channel string
