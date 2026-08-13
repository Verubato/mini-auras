---@type string, Addon
local _, addon = ...
local auraCategoryIds = addon.Core.AuraCategoryIds

-- Every spell id the picker can offer, indexed by name so it can be searched on.
-- Deduped by NAME: the generated data carries every id variant of an ability, and four identical
-- rows help nobody. GetVariants hands the dropped ones back.
--
-- Two sources feed it. The curated category lists are the abilities MiniAuras knows something about,
-- and SpellNameIndex is a generated list of every aura id a player can reach, grouped by the ids
-- that share a name. The index is what bridges a cast id to the aura id it applies, which is the
-- only id a filter ever matches.
--
-- The generated groups carry no names: the client knows what it calls each id in its own language,
-- so GetNameIndex asks it and keys the groups on the answer. Everything below therefore works in
-- whatever language the player is running.

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
-- Built on first use: naming ~1,200 spells is pointless if the picker is never opened.
---@type SpellSearchEntry[]?
local entries
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

---The generated id groups, keyed by the name this client gives them. Built once and kept: the
---file ships ids only, and the client is what turns them into the names a player would type.
---@return table<string, string>
local function GetNameIndex()
	if nameIndex then
		return nameIndex
	end

	nameIndex = {}

	for _, raw in ipairs(addon.Core.SpellNameIndex or EMPTY) do
		-- Every id in a group answers with the same name, so the first the client knows is enough.
		-- Walked rather than assumed, because a group can lead with an id this build has dropped.
		for id in raw:gmatch("%d+") do
			local name = C_Spell.GetSpellName(tonumber(id))

			if name and name ~= "" then
				local existing = nameIndex[name]

				-- Two names that are distinct in English can collide in another language, so the
				-- groups merge rather than the second replacing the first.
				nameIndex[name] = existing and (existing .. " " .. raw) or raw
				break
			end
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

local function BuildIndex()
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
		local name = C_Spell.GetSpellName(spellId)

		if name and name ~= "" then
			local lower = name:lower()
			local variants = idsByName[lower]

			nameById[spellId] = lower

			if variants then
				variants[#variants + 1] = spellId
			else
				local entry = {
					Id = spellId,
					Name = name,
					Lower = lower,
					Class = auraCategoryIds.Classes[spellId],
				}

				idsByName[lower] = { spellId }
				-- Only the curated entries, matching what GetEntry could ever reach: the
				-- generated names below never land in nameById, so no id resolves to one.
				entryByName[lower] = entry
				entries[#entries + 1] = entry
			end
		end
	end

	-- Every aura name a player can reach that the curated lists do not already carry. Its id is
	-- the lowest of the name's variants, so a suggestion picked twice adds the same one.
	for name, raw in pairs(GetNameIndex()) do
		local lower = name:lower()

		if not idsByName[lower] then
			local first = tonumber(raw:match("%d+"))

			if first then
				entries[#entries + 1] = { Id = first, Name = name, Lower = lower }
			end
		end
	end

	table.sort(entries, function(a, b)
		return a.Lower < b.Lower
	end)
end

local function EnsureIndex()
	if not entries then
		BuildIndex()
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

---The suggestions for a partially typed spell name or id, best match first.
---Returns a shared table that the next call refills; copy anything you need to keep.
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

	local numeric = tonumber(query)

	-- A fully typed id is an answer, not a search, so it leads even if the index lacks it.
	if numeric and numeric == math.floor(numeric) and numeric > 0 then
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
	EnsureIndex()

	local name = nameById[spellId]
	local entry = name and entryByName[name]

	if entry then
		-- The canonical entry carries a different id when the caller asked for a variant;
		-- answer with the id they asked about so the row they see matches their list.
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
	EnsureIndex()

	local cached = variantCache[spellId]

	if cached then
		return cached
	end

	local name = nameById[spellId]
	local curated = name and idsByName[name]
	local scanned = IndexVariants(spellId)

	-- The common case by far: nothing to merge, so hand back the list already built.
	if curated and not scanned then
		variantCache[spellId] = curated
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

	return merged
end

---@class SpellSearchEntry
---@field Id number
---@field Name string
---@field Lower string
---@field Class string? Class token the generated data attributes the spell to.
