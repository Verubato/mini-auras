---@type string, Addon
local addonName, addon = ...
local auraCategoryIds = addon.Core.AuraCategoryIds

-- Every spell id the picker can offer, indexed by name so it can be searched on. Deduped by name,
-- since four identical rows help nobody, and GetVariants hands the dropped ones back.

local MAX_RESULTS = 12
local EMPTY = {}
-- Defensives the generated scan misses.
local EXTRA_IDS = {
	[86659] = true, -- Guardian of Ancient Kings
	[109304] = true, -- Exhilaration
	[115203] = true, -- Fortifying Brew
	[122470] = true, -- Touch of Karma
	[198589] = true, -- Blur
	[204021] = true, -- Fiery Brand
	[342245] = true, -- Alter Time
	[342247] = true, -- Alter Time
	[414659] = true, -- Ice Cold
}
-- Built on first use, because naming ~1,200 spells is pointless if the picker is never opened.
---@type SpellSearchEntry[]?
local entries
-- Whether the generated half is in as well. See BuildSearchIndex.
local searchIndexBuilt = false
-- Lowercased name -> the ids that share it, so an added id can be expanded to its variants.
---@type table<string, number[]>
local idsByName = {}
-- Lowercased name -> its canonical entry, so a lookup does not walk all ~8,000 of them.
---@type table<string, SpellSearchEntry>
local entryByName = {}
-- spellId -> lowercased name, for the same expansion from the other direction.
---@type table<number, string>
local nameById = {}
-- The generated id groups keyed by the name this client gives them, built on first use.
---@type table<string, string>?
local nameIndex
-- Groups whose ids the client could not name yet. Allocated only when one actually fails.
---@type string[]?
local pendingGroups
-- The same for curated ids, which the client can be just as slow to load.
---@type number[]?
local pendingIds
-- When the pending sets last got a retry. One pass per frame at most, because GetVariants runs per
-- tracked spell per refresh and an id this build has dropped would otherwise be re-asked on every
-- one of those calls forever.
local lastRetryTime
-- Index names already split out of their stored string, and the union GetVariants last handed
-- back for an id. Both are pure caches of work that never changes within a session.
---@type table<string, number[]>
local indexVariants = {}
---@type table<number, number[]>
local variantCache = {}
local results = {}

---@class SpellSearch
local M = {}

addon.Core.SpellSearch = M

---@param ids table<number, any>
---@param out table<number, boolean>
local function CollectKeys(ids, out)
	if type(ids) ~= "table" then
		return
	end

	for spellId in pairs(ids) do
		if type(spellId) == "number" then
			out[spellId] = true
		end
	end
end

---Whether the client could still come to name this id. Spell data loads lazily, so an id that
---answers nothing right now may answer later, while one this build has dropped never will.
---The saved cache stays shut for as long as one of those is waiting. See StoreVariants.
---A group held back costs one session's cache, while one discarded in error costs an aura that
---never matches.
---@param spellId number
---@return boolean
local function MayYetName(spellId)
	if not C_Spell.DoesSpellExist then
		return true
	end

	return C_Spell.DoesSpellExist(spellId) and true or false
end

---The same for a group, which is named by whichever of its ids answers first.
---@param raw string
---@return boolean
local function GroupMayYetName(raw)
	if not C_Spell.DoesSpellExist then
		return true
	end

	for id in raw:gmatch("%d+") do
		if C_Spell.DoesSpellExist(tonumber(id)) then
			return true
		end
	end

	return false
end

---What this client calls a group of ids, or nil while it can name none of them.
---@param raw string
---@return string?
local function ResolveGroup(raw)
	-- Every id in a group answers with the same name, so the first the client knows is enough. The
	-- whole group is walked, because it can lead with an id this build has dropped.
	for id in raw:gmatch("%d+") do
		local name = C_Spell.GetSpellName(tonumber(id))

		if name and name ~= "" then
			return name
		end
	end

	return nil
end

---@param name string
---@param raw string
local function AddGroup(name, raw)
	local existing = nameIndex[name]

	if existing then
		-- Two names that are distinct in English can collide in another language, so the groups
		-- merge.
		nameIndex[name] = existing .. " " .. raw
		-- The merge changes the id list, so a split already taken from it is out of date.
		indexVariants[name] = nil
	else
		nameIndex[name] = raw
	end
end

---The generated id groups, keyed by the name this client gives them. The file ships ids only, and
---the client is what turns them into the names a player would type.
---@return table<string, string>
local function GetNameIndex()
	if nameIndex then
		return nameIndex
	end

	nameIndex = {}

	for _, raw in ipairs(addon.Core.SpellNameIndex or EMPTY) do
		local name = ResolveGroup(raw)

		if name then
			AddGroup(name, raw)
		elseif GroupMayYetName(raw) then
			pendingGroups = pendingGroups or {}
			pendingGroups[#pendingGroups + 1] = raw
		end
	end

	return nameIndex
end

---The ids the generated index has under a spell's name, or nil when it has none.
---@param spellId number
---@return number[]?
local function IndexVariants(spellId)
	local name = C_Spell.GetSpellName(spellId)
	local raw = name and GetNameIndex()[name]

	if not raw then
		return nil
	end

	local split = indexVariants[name]

	if not split then
		split = {}

		for id in raw:gmatch("%d+") do
			split[#split + 1] = tonumber(id)
		end

		indexVariants[name] = split
	end

	return split
end

---The suggestion row a generated name needs, or nil when the curated pass already covers it. Its
---id is the lowest of the name's variants, so a suggestion picked twice adds the same one.
---@param name string
---@return SpellSearchEntry?
local function GeneratedEntry(name)
	local lower = name:lower()

	if idsByName[lower] then
		return nil
	end

	local first = tonumber(nameIndex[name]:match("%d+"))

	if not first then
		return nil
	end

	return { Id = first, Name = name, Lower = lower }
end

---Puts a curated id into the lookups. The row it needs comes back separately, because the build
---appends rows and sorts once while a late id has to land in an already sorted list.
---@param spellId number
---@return boolean named Whether the client could name the id at all.
---@return SpellSearchEntry? entry A row for a name nothing else has yet.
local function AddCuratedId(spellId)
	local name = C_Spell.GetSpellName(spellId)

	if not name or name == "" then
		return false
	end

	local lower = name:lower()
	local variants = idsByName[lower]

	nameById[spellId] = lower

	if variants then
		variants[#variants + 1] = spellId
		return true
	end

	local entry = {
		Id = spellId,
		Name = name,
		Lower = lower,
		Class = auraCategoryIds.Classes[spellId],
	}

	idsByName[lower] = { spellId }
	-- Only the curated entries, matching what GetEntry could ever reach. The generated names never
	-- land in nameById, so no id resolves to one.
	entryByName[lower] = entry

	return true, entry
end

---Where a name belongs in the sorted suggestion list.
---@param lower string
---@return number
local function LowerBound(lower)
	local low, high = 1, #entries

	while low <= high do
		local mid = math.floor((low + high) / 2)

		if entries[mid].Lower < lower then
			low = mid + 1
		else
			high = mid - 1
		end
	end

	return low
end

---@param entry SpellSearchEntry
local function InsertSorted(entry)
	table.insert(entries, LowerBound(entry.Lower), entry)
end

---@param entry SpellSearchEntry
local function InsertCurated(entry)
	local at = LowerBound(entry.Lower)
	local existing = entries[at]

	-- A generated row under that name only exists because the curated id was unnamed when the list
	-- was built. The curated pass runs first, so it takes the row over.
	if existing and existing.Lower == entry.Lower then
		entries[at] = entry
	else
		table.insert(entries, at, entry)
	end
end

---What this build of the data, on this client, in this language, calls a cached expansion. The
---groups are what decides which ids share a name, and the client's language is what does the
---sharing, so a change to either makes every stored answer suspect.
---@return string
local function CacheStamp()
	-- The addon's version stands in for the curated lists, which feed the same expansion and ship
	-- with the addon. A release that adds an id to one without regenerating the index above would
	-- otherwise leave every stored answer a version behind.
	local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(addonName, "Version")
	-- The client build too. An answer is only ever as wide as the ids this client knows, and a
	-- patch that brings a dropped one back widens the name it lands on with nothing in the addon
	-- changing to say so.
	local build = GetBuildInfo and select(2, GetBuildInfo())

	return (addon.Core.SpellNameIndexVersion or "?") .. ":" .. (version or "?") .. ":"
		.. (build or "?") .. ":" .. GetLocale()
end

---The saved cache, wiped when it was built from other data than this one carries. Created on first
---use, since the client restores a saved variable before the addon's own ADDON_LOADED and nothing
---asks for an expansion before that.
---@return table<number, number[]>
local function VariantStore()
	local store = _G.MiniAurasSpellCache

	if not store then
		store = {}
		_G.MiniAurasSpellCache = store
	end

	local stamp = CacheStamp()

	if store.Stamp ~= stamp then
		store.Stamp = stamp
		store.Ids = {}
	end

	store.Ids = store.Ids or {}

	return store.Ids
end

---A previous session's answer for this spell, if there is one.
---@param spellId number
---@return number[]?
local function StoredVariants(spellId)
	return VariantStore()[spellId]
end

---Keeps an expansion for the next session, only once the client has answered for everything this
---could have covered. An id whose data has not loaded yet expands to itself alone, so an answer
---built while anything is still pending is short by whatever arrives next.
---Stored, that would outlive the retry that fixes it, because the store is read before the retry
---ever runs.
---@param spellId number
---@param variants number[]
local function StoreVariants(spellId, variants)
	if pendingIds or pendingGroups then
		return
	end

	local name = C_Spell.GetSpellName(spellId)

	if not name or name == "" then
		return
	end

	VariantStore()[spellId] = variants
end

---@return boolean resolved
local function RetryPendingIds()
	local kept = 0
	local resolved = false

	for index = 1, #pendingIds do
		local spellId = pendingIds[index]
		local named, entry = AddCuratedId(spellId)

		pendingIds[index] = nil

		if named then
			resolved = true

			if entry then
				InsertCurated(entry)
			end
		else
			kept = kept + 1
			pendingIds[kept] = spellId
		end
	end

	if kept == 0 then
		pendingIds = nil
	end

	return resolved
end

---@return boolean resolved
local function RetryPendingGroups()
	local kept = 0
	local resolved = false

	for index = 1, #pendingGroups do
		local raw = pendingGroups[index]
		local name = ResolveGroup(raw)

		pendingGroups[index] = nil

		if name then
			local isNewName = nameIndex[name] == nil

			AddGroup(name, raw)
			resolved = true

			if isNewName then
				local entry = GeneratedEntry(name)

				if entry then
					InsertSorted(entry)
				end
			end
		else
			kept = kept + 1
			pendingGroups[kept] = raw
		end
	end

	if kept == 0 then
		pendingGroups = nil
	end

	return resolved
end

---Whatever the client could not name gets another try whenever the index is touched. Spell data
---loads lazily, so an id that answered nothing at login can resolve later in the session.
local function RetryPending()
	if not pendingIds and not pendingGroups then
		return
	end

	local now = GetTime()

	if now == lastRetryTime then
		return
	end

	lastRetryTime = now

	-- Curated first, as at build time. A name a curated id claims is one the generated pass skips.
	local resolved = pendingIds and RetryPendingIds()

	if pendingGroups and RetryPendingGroups() then
		resolved = true
	end

	if resolved then
		-- A late id widens the name it landed on, so every expansion taken from the old one has
		-- to be worked out again.
		-- This also reopens the store. An answer refused while this id was pending is no longer in
		-- hand, so the call that wants it next works it out again and keeps it.
		wipe(variantCache)
	end
end

local function ByLower(a, b)
	return a.Lower < b.Lower
end

---The curated half: which ids share a name, and a row for each curated spell. This is all an
---aura filter needs, and it is the half that costs a name lookup per curated id.
local function BuildCuratedIndex()
	local ids = {}

	CollectKeys(auraCategoryIds.CC, ids)
	CollectKeys(auraCategoryIds.Defensive, ids)
	CollectKeys(auraCategoryIds.Important, ids)
	CollectKeys(auraCategoryIds.Unflagged, ids)
	CollectKeys(auraCategoryIds.Classes, ids)
	CollectKeys(EXTRA_IDS, ids)

	entries = {}

	-- Sorted so an ability always offers the same id across sessions.
	local sorted = {}

	for spellId in pairs(ids) do
		sorted[#sorted + 1] = spellId
	end

	table.sort(sorted)

	for _, spellId in ipairs(sorted) do
		local named, entry = AddCuratedId(spellId)

		if entry then
			entries[#entries + 1] = entry
		elseif not named and MayYetName(spellId) then
			pendingIds = pendingIds or {}
			pendingIds[#pendingIds + 1] = spellId
		end
	end

	-- By name from here on, because that is the order the list is read in and the order the
	-- late-arriving ids are inserted against.
	table.sort(entries, ByLower)

	-- The generated groups are named here rather than on first use: an id the client cannot name
	-- yet has to be on the pending list from the start, or the retry that names it never runs and
	-- the expansions taken before it are never worked out again.
	GetNameIndex()
end

---The other half: a row for every aura name a player can reach that the curated lists do not
---already carry. Thousands of them, so it is built only for the one thing that needs it, the
---search box in the options.
local function BuildSearchIndex()
	searchIndexBuilt = true

	for name in pairs(GetNameIndex()) do
		local entry = GeneratedEntry(name)

		if entry then
			entries[#entries + 1] = entry
		end
	end

	table.sort(entries, ByLower)
end

---Enough of the index to answer which ids share a spell's name, which is what an aura filter
---asks. Not the search list, because a personal aura group with a spell in it would otherwise build
---every generated row at login for a list nobody is looking at.
local function EnsureVariants()
	if entries then
		RetryPending()
	else
		BuildCuratedIndex()
	end
end

local function EnsureIndex()
	EnsureVariants()

	if not searchIndexBuilt then
		BuildSearchIndex()
	end
end

---An entry for an id that is not in the index, so a hand-typed spell still shows its name and
---icon. Returns nil for ids the client has never heard of.
---@param spellId number
---@return SpellSearchEntry?
local function UnknownEntry(spellId)
	local name = C_Spell.GetSpellName(spellId)

	if not name or name == "" then
		return nil
	end

	return { Id = spellId, Name = name, Lower = name:lower() }
end

---The spell id a query spells out, nil when it is a name or a fragment of one.
---Digits only, because tonumber reads "0x10" as 16 and "1e3" as 1000, and nobody typing a spell
---id means either.
---@param query string
---@return number?
function M:QueryId(query)
	if not query:match("^%s*%d+%s*$") then
		return nil
	end

	local spellId = tonumber(query)

	return spellId ~= 0 and spellId or nil
end

---The suggestions for a partially typed spell name or id, best match first.
---Returns a shared table that the next call refills, so copy anything you need to keep.
---@param query string
---@param limit number?
---@return SpellSearchEntry[]
function M:Search(query, limit)
	wipe(results)

	query = (query or ""):match("^%s*(.-)%s*$")

	if query == "" then
		return results
	end

	EnsureIndex()

	limit = limit or MAX_RESULTS

	local numeric = self:QueryId(query)

	-- A fully typed id is an answer, not a search, so it leads even if the index lacks it.
	if numeric then
		local entry = self:GetEntry(numeric)

		if entry then
			results[#results + 1] = entry
		end
	end

	local lower = query:lower()
	local prefixes = {}
	local contains = {}

	for _, entry in ipairs(entries) do
		if entry.Id ~= numeric then
			local at = entry.Lower:find(lower, 1, true)

			if at == 1 then
				prefixes[#prefixes + 1] = entry
			elseif at then
				contains[#contains + 1] = entry
			elseif numeric and tostring(entry.Id):find(query, 1, true) == 1 then
				contains[#contains + 1] = entry
			end
		end
	end

	for _, list in ipairs({ prefixes, contains }) do
		for _, entry in ipairs(list) do
			if #results >= limit then
				return results
			end

			results[#results + 1] = entry
		end
	end

	return results
end

---@param spellId number
---@return SpellSearchEntry?
function M:GetEntry(spellId)
	EnsureVariants()

	local name = nameById[spellId]
	local entry = name and entryByName[name]

	if entry then
		-- The canonical entry carries a different id when the caller asked for a variant. Answer
		-- with the id they asked about so the row they see matches their list.
		if entry.Id == spellId then
			return entry
		end

		return { Id = spellId, Name = entry.Name, Lower = entry.Lower, Class = entry.Class }
	end

	return UnknownEntry(spellId)
end

---Every id sharing a spell's name, including the one passed in. Aura filters match the id the
---game applied, which is often not the spellbook one, so a tracked ability must cover them all.
---@param spellId number
---@return number[]
function M:GetVariants(spellId)
	-- Only once something has been built. The retry is there to fold in ids the client could not
	-- name yet, and nothing can be waiting on that while nothing has read the client at all.
	if entries then
		RetryPending()
	end

	local cached = variantCache[spellId]

	if cached then
		return cached
	end

	-- Before anything is built, what a previous session worked out is the whole answer, and reading
	-- it back is what keeps the naming pass below off the login path entirely.
	local stored = StoredVariants(spellId)

	if stored then
		variantCache[spellId] = stored

		return stored
	end

	EnsureVariants()

	local name = nameById[spellId]
	local curated = name and idsByName[name]
	local scanned = IndexVariants(spellId)

	-- The common case by far. Nothing to merge, so hand back the list already built.
	if curated and not scanned then
		variantCache[spellId] = curated
		StoreVariants(spellId, curated)

		return curated
	end

	local seen = {}
	local merged = {}

	for _, list in ipairs({ curated or EMPTY, scanned or EMPTY, { spellId } }) do
		for _, id in ipairs(list) do
			if not seen[id] then
				seen[id] = true
				merged[#merged + 1] = id
			end
		end
	end

	table.sort(merged)
	variantCache[spellId] = merged
	StoreVariants(spellId, merged)

	return merged
end

---@class SpellSearchEntry
---@field Id number
---@field Name string
---@field Lower string
---@field Class string? Class token the generated data attributes the spell to.
