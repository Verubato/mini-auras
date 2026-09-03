---@type string, Addon
local _, addon = ...
local auraCategoryIds = addon.Core.AuraCategoryIds

-- Every spell id the picker can offer, searchable by name. One row per id, since configured ids
-- are matched exactly and the id a player wants is not always the one its name resolves to first.

local MAX_RESULTS = 12
-- Ids under one name all draw the same string, so past a handful they are rows a player has no
-- way to choose between.
local MAX_PER_NAME = 5
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
-- The rows themselves, flat parallel arrays. A search reads 12 rows out of ~10,000, so a table
-- per row is allocation nobody sees.
---@type number[]?
local ids
---@type string[]?
local lowers
---@type string[]?
local names
---@type boolean[]?
local curatedFlags
---@type string[]?
local classes
-- spellId -> its position in the arrays above, so a lookup does not walk all ~10,000 of them.
---@type table<number, number>?
local idIndex
-- Whether the generated half is in as well. See BuildSearchIndex.
local searchIndexBuilt = false
-- The generated id groups keyed by the name this client gives them, built on first use.
---@type table<string, string>?
local nameIndex
-- Every id the generated file carries, flattened out of its groups. What tells a curated id
-- apart from the legacy and NPC copies sharing its name.
---@type table<number, boolean>?
local generatedIds
-- Names that have at least one curated id a current source vouches for, so the copies under
-- that name are dropped.
---@type table<string, boolean>?
local vouchedNames
-- Groups whose ids the client could not name yet. Allocated only when one actually fails.
---@type string[]?
local pendingGroups
-- The same for curated ids, which the client can be just as slow to load.
---@type number[]?
local pendingIds
-- When the pending sets last got a retry. One pass per frame at most, since a keystroke in the
-- options can search more than once.
local lastRetryTime
local results = {}
-- How many rows each name has taken in the search being answered.
local nameCounts = {}
-- The positions a search matched, split so reading the buckets in order gives curated rows
-- ahead of generated ones and prefix matches ahead of substring ones.
local curatedPrefixes = {}
local otherPrefixes = {}
local curatedContains = {}
local otherContains = {}
local buckets = { curatedPrefixes, otherPrefixes, curatedContains, otherContains }

---@class SpellSearch
local M = {}

addon.Core.SpellSearch = M

---@param source table<number, any>
---@param out table<number, boolean>
local function CollectKeys(source, out)
	if type(source) ~= "table" then
		return
	end

	for spellId in pairs(source) do
		if type(spellId) == "number" then
			out[spellId] = true
		end
	end
end

---Whether the client could still come to name this id. Spell data loads lazily, so an id that
---answers nothing right now may answer later, while one this build has dropped never will.
---A group held back costs a retry next frame, while one discarded in error costs a row the
---picker never offers.
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
	generatedIds = {}

	for _, raw in ipairs(addon.Core.SpellNameIndex or EMPTY) do
		for id in raw:gmatch("%d+") do
			generatedIds[tonumber(id)] = true
		end

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

---Whether a current source still vouches for a curated id. The generated file and the class map
---are both current, so an id in neither is a legacy or NPC copy of a spell already listed.
---@param spellId number
---@return boolean
local function IsVouched(spellId)
	return generatedIds[spellId] ~= nil or auraCategoryIds.Classes[spellId] ~= nil
end

---Appends a new row. A position is only good until a row is dropped, which moves the last row
---into the gap.
---@param spellId number
---@param name string
---@param lower string
---@param curated boolean
---@param class string?
local function AppendRow(spellId, name, lower, curated, class)
	local position = #ids + 1

	ids[position] = spellId
	names[position] = name
	lowers[position] = lower
	curatedFlags[position] = curated
	classes[position] = class
	idIndex[spellId] = position
end

---Drops a row, filling the gap with the last one so the arrays stay a plain sequence.
---@param position number
local function RemoveRow(position)
	local last = #ids

	idIndex[ids[position]] = nil

	if position ~= last then
		ids[position] = ids[last]
		names[position] = names[last]
		lowers[position] = lowers[last]
		curatedFlags[position] = curatedFlags[last]
		classes[position] = classes[last]
		idIndex[ids[position]] = position
	end

	ids[last] = nil
	names[last] = nil
	lowers[last] = nil
	curatedFlags[last] = nil
	classes[last] = nil
end

---Adds every id of a generated group that is not already a row. An id already in the index is
---one the curated pass claimed, which outranks the generated one on a tie.
---@param name string
---@param raw string
local function AddGroupIds(name, raw)
	local lower = name:lower()

	for id in raw:gmatch("%d+") do
		local spellId = tonumber(id)

		if not idIndex[spellId] then
			AppendRow(spellId, name, lower, false, nil)
		end
	end
end

---Puts a curated id in the index. An id the generated pass already added gets promoted in place
---rather than duplicated, since a curated row of the same id ranks higher.
---@param spellId number
---@param name string
local function AddCuratedRow(spellId, name)
	local lower = name:lower()
	local position = idIndex[spellId]

	if position then
		names[position] = name
		lowers[position] = lower
		curatedFlags[position] = true
		classes[position] = auraCategoryIds.Classes[spellId]
	else
		AppendRow(spellId, name, lower, true, auraCategoryIds.Classes[spellId])
	end
end

---Drops the copies a name was keeping while nothing vouched for any of its ids.
---@param name string
local function DropUnvouchedRows(name)
	for position = #ids, 1, -1 do
		if curatedFlags[position] and names[position] == name and not IsVouched(ids[position]) then
			RemoveRow(position)
		end
	end
end

---Adds one name's curated ids, the vouched ones alone where there are any. A name nothing vouches
---for keeps every id, since the curated list is then the only place that spell exists.
---@param name string
---@param spellIds number[]
local function AddNameGroup(name, spellIds)
	local vouched = false

	for _, spellId in ipairs(spellIds) do
		if IsVouched(spellId) then
			vouched = true
			break
		end
	end

	if vouched then
		vouchedNames[name] = true
	end

	for _, spellId in ipairs(spellIds) do
		if not vouched or IsVouched(spellId) then
			AddCuratedRow(spellId, name)
		end
	end
end

---Applies the same rule to a curated id the client could not name until now, so a vouched
---latecomer drops the copies its name was keeping in the meantime.
---@param spellId number
---@param name string
local function AddLateCuratedId(spellId, name)
	if IsVouched(spellId) then
		if not vouchedNames[name] then
			vouchedNames[name] = true
			DropUnvouchedRows(name)
		end

		AddCuratedRow(spellId, name)
	elseif not vouchedNames[name] then
		AddCuratedRow(spellId, name)
	end
end

local function RetryPendingIds()
	local kept = 0

	for index = 1, #pendingIds do
		local spellId = pendingIds[index]
		local name = C_Spell.GetSpellName(spellId)

		pendingIds[index] = nil

		if name and name ~= "" then
			AddLateCuratedId(spellId, name)
		else
			kept = kept + 1
			pendingIds[kept] = spellId
		end
	end

	if kept == 0 then
		pendingIds = nil
	end
end

local function RetryPendingGroups()
	local kept = 0

	for index = 1, #pendingGroups do
		local raw = pendingGroups[index]

		pendingGroups[index] = nil

		local name = ResolveGroup(raw)

		if name then
			AddGroup(name, raw)
			AddGroupIds(name, raw)
		else
			kept = kept + 1
			pendingGroups[kept] = raw
		end
	end

	if kept == 0 then
		pendingGroups = nil
	end
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

	-- Curated first, as at build time. An id the curated pass claims is one the generated pass
	-- would otherwise have added under a lower rank.
	if pendingIds then
		RetryPendingIds()
	end

	if pendingGroups then
		RetryPendingGroups()
	end
end

---The curated half: a row for every curated spell id the current data still vouches for, plus
---every id of a name nothing vouches for.
local function BuildCuratedIndex()
	local idSet = {}

	CollectKeys(auraCategoryIds.CC, idSet)
	CollectKeys(auraCategoryIds.Defensive, idSet)
	CollectKeys(auraCategoryIds.Important, idSet)
	CollectKeys(auraCategoryIds.Unflagged, idSet)
	CollectKeys(auraCategoryIds.Classes, idSet)
	CollectKeys(EXTRA_IDS, idSet)

	ids, lowers, names, curatedFlags, classes = {}, {}, {}, {}, {}
	idIndex = {}
	vouchedNames = {}

	-- Ahead of the curated pass, which needs the generated ids to spot a copy.
	GetNameIndex()

	-- Sorted so the rows land in the same order every session, whatever order pairs walks the set.
	local sorted = {}

	for spellId in pairs(idSet) do
		sorted[#sorted + 1] = spellId
	end

	table.sort(sorted)

	-- The trim works a name at a time, so every id the client can name is grouped before any row
	-- is added.
	local byName = {}
	local order = {}

	for _, spellId in ipairs(sorted) do
		local name = C_Spell.GetSpellName(spellId)

		if name and name ~= "" then
			local group = byName[name]

			if group then
				group[#group + 1] = spellId
			else
				byName[name] = { spellId }
				order[#order + 1] = name
			end
		elseif MayYetName(spellId) then
			pendingIds = pendingIds or {}
			pendingIds[#pendingIds + 1] = spellId
		end
	end

	for _, name in ipairs(order) do
		AddNameGroup(name, byName[name])
	end
end

---The other half: a row for every aura id a player can reach that the curated lists do not
---already carry. Thousands of them, so it is built only for the one thing that needs it, the
---search box in the options.
local function BuildSearchIndex()
	searchIndexBuilt = true

	for name, raw in pairs(GetNameIndex()) do
		AddGroupIds(name, raw)
	end
end

local function EnsureIndex()
	if ids then
		RetryPending()
	else
		BuildCuratedIndex()
	end

	if not searchIndexBuilt then
		BuildSearchIndex()
	end
end

---The row at a position, built only when a caller is actually about to see it.
---@param position number
---@return SpellSearchEntry
local function BuildEntry(position)
	return { Id = ids[position], Name = names[position], Lower = lowers[position], Class = classes[position] }
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

---Whether a name has room left in the search being answered, taking the row if it has.
---@param name string
---@return boolean
local function TakeNameSlot(name)
	local taken = nameCounts[name] or 0

	if taken >= MAX_PER_NAME then
		return false
	end

	nameCounts[name] = taken + 1

	return true
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
	wipe(nameCounts)

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

	for _, bucket in ipairs(buckets) do
		wipe(bucket)
	end

	-- Walked low position to high, so each bucket comes out in index order and no sort is needed
	-- to rank the matches.
	for position = 1, #ids do
		if ids[position] ~= numeric then
			local at = lowers[position]:find(lower, 1, true)
			local curated = curatedFlags[position]
			local bucket

			if at == 1 then
				bucket = curated and curatedPrefixes or otherPrefixes
			elseif at or (numeric and tostring(ids[position]):find(query, 1, true) == 1) then
				bucket = curated and curatedContains or otherContains
			end

			if bucket then
				bucket[#bucket + 1] = position
			end
		end
	end

	for _, bucket in ipairs(buckets) do
		for _, position in ipairs(bucket) do
			if #results >= limit then
				return results
			end

			if TakeNameSlot(names[position]) then
				results[#results + 1] = BuildEntry(position)
			end
		end
	end

	return results
end

---@param spellId number
---@return SpellSearchEntry?
function M:GetEntry(spellId)
	EnsureIndex()

	local position = idIndex[spellId]

	if position then
		return BuildEntry(position)
	end

	return UnknownEntry(spellId)
end

---@class SpellSearchEntry
---@field Id number
---@field Name string
---@field Lower string
---@field Class string? Class token the generated data attributes the spell to.
