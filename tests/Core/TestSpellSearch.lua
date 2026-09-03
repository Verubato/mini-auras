-- A user typing part of an ability name has to find it, and an ability with several ids is
-- offered once per id, so the id is what tells otherwise-identical rows apart.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local addon = env.addon
local categoryIds = addon.Core.AuraCategoryIds

-- Three ids that really do share a name in the generated data, and one that does not.
local TORRENT_IDS = { 33390, 36022, 47779, 222783 }
local KIDNEY_SHOT = 408

env.spellNames[KIDNEY_SHOT] = "Kidney Shot"
for _, spellId in ipairs(TORRENT_IDS) do
	env.spellNames[spellId] = "Arcane Torrent"
end

-- The real generated lists are loaded, so assert the fixtures are actually in them rather than
-- silently testing an empty index.
assert(categoryIds.CC[KIDNEY_SHOT], "fixture must be part of the shipped CC list")
for _, spellId in ipairs(TORRENT_IDS) do
	assert(categoryIds.CC[spellId], "every Arcane Torrent variant must be in the CC list")
end

-- A stand-in for the generated index. Rake's cast and the bleed it leaves behind share a name
-- but not an id, and configured ids are matched exactly, so both need their own row.
local RAKE_CAST = 1822
local RAKE_BLEED = 155722
local INVENTED = 999003

env.spellNames[RAKE_CAST] = "Rake"
env.spellNames[RAKE_BLEED] = "Rake"
env.spellNames[INVENTED] = "Sudden Doom"

-- Id groups only, exactly as the generated file ships them. The names come from the client, which
-- is what makes the picker work in any language.
addon.Core.SpellNameIndex = {
	("%d %d"):format(RAKE_CAST, RAKE_BLEED),
	tostring(INVENTED),
}

env.loadModule("src/Core/Auras/SpellSearch.lua")

local search = addon.Core.SpellSearch

---@param results table
---@param spellId number
---@return boolean
local function Contains(results, spellId)
	for _, entry in ipairs(results) do
		if entry.Id == spellId then
			return true
		end
	end

	return false
end

---@param results table
---@param name string
---@return number
local function CountNamed(results, name)
	local count = 0

	for _, entry in ipairs(results) do
		if entry.Name == name then
			count = count + 1
		end
	end

	return count
end

fw.describe("SpellSearch - suggestions", function()
	fw.it("finds a spell from part of its name", function()
		local results = search:Search("kidney")

		assert(Contains(results, KIDNEY_SHOT), "Kidney Shot is suggested for 'kidney'")
	end)

	fw.it("ignores case", function()
		assert(Contains(search:Search("KIDNEY"), KIDNEY_SHOT), "upper case matches")
		assert(Contains(search:Search("KiDnEy ShOt"), KIDNEY_SHOT), "mixed case matches")
	end)

	fw.it("matches inside a name, not only at the start", function()
		assert(Contains(search:Search("shot"), KIDNEY_SHOT), "'shot' finds Kidney Shot")
	end)

	fw.it("offers a repeated ability once per id, not collapsed to one row", function()
		local results = search:Search("arcane torrent")

		assert(CountNamed(results, "Arcane Torrent") == #TORRENT_IDS,
			"every Arcane Torrent id gets its own row")

		for _, spellId in ipairs(TORRENT_IDS) do
			assert(Contains(results, spellId), "id " .. spellId .. " has its own row")
		end
	end)

	fw.it("puts prefix matches before substring matches", function()
		local results = search:Search("kid")
		local firstPrefix

		for index, entry in ipairs(results) do
			if entry.Lower:find("kid", 1, true) == 1 then
				firstPrefix = firstPrefix or index
			elseif firstPrefix then
				-- A substring match after a prefix match is the expected order.
				assert(index > firstPrefix, "prefix matches come first")
			end
		end

		assert(firstPrefix, "at least one prefix match was returned")
	end)

	fw.it("returns nothing for an empty query", function()
		assert(#search:Search("") == 0, "empty query has no suggestions")
		assert(#search:Search("   ") == 0, "whitespace is not a query")
	end)

	fw.it("respects the result limit", function()
		local results = search:Search("a", 3)

		assert(#results <= 3, "no more results than asked for")
	end)

	fw.it("offers a fully typed id first, even one it has never tracked", function()
		local unknown = 999001
		env.spellNames[unknown] = "Invented Ability"

		local results = search:Search(tostring(unknown))

		assert(results[1] and results[1].Id == unknown, "the typed id leads the list")
	end)

	fw.it("hands back a spell's name for the picker to show", function()
		local entry = search:GetEntry(KIDNEY_SHOT)

		assert(entry and entry.Name == "Kidney Shot", "the entry carries the name")
	end)

	fw.it("answers each variant with its own row", function()
		local entry = search:GetEntry(TORRENT_IDS[3])

		assert(entry and entry.Id == TORRENT_IDS[3], "the id asked about is the id returned")
		assert(entry.Name == "Arcane Torrent", "with the name it shares with the other variants")
	end)
end)

fw.describe("SpellSearch - a name with several ids", function()
	fw.it("returns a row for every id, not just the one the name resolves to first", function()
		local results = search:Search("rake")

		assert(Contains(results, RAKE_CAST), "the cast has its own row")
		assert(Contains(results, RAKE_BLEED), "the bleed it leaves behind has its own row too")
	end)
end)

fw.describe("SpellSearch - ranking ties", function()
	-- A curated id the client cannot name at build time joins the arrays after every generated
	-- row, so index order alone would put the generated row first.
	local CURATED = 999010
	local GENERATED = 999009
	local frameTime = 0

	fw.it("puts a curated id above a generated one at equal match quality", function()
		local names = {}
		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = { tostring(GENERATED) },
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		env.spellNames[GENERATED] = "Tiebreak"
		categoryIds.Unflagged[CURATED] = true

		local realGetSpellName = _G.C_Spell.GetSpellName
		_G.C_Spell.GetSpellName = function(spellId)
			if spellId == CURATED then
				return names[spellId]
			end

			return realGetSpellName(spellId)
		end

		local realGetTime = _G.GetTime
		_G.GetTime = function()
			return frameTime
		end

		local ok, err = pcall(function()
			assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)

			local lateSearch = target.Core.SpellSearch

			assert(not Contains(lateSearch:Search("tiebreak"), CURATED),
				"the curated id has no name to show while the build runs")

			names[CURATED] = "Tiebreak"
			frameTime = frameTime + 1

			local results = lateSearch:Search("tiebreak")

			assert(results[1] and results[1].Id == CURATED,
				"the curated id leads though it joined the arrays last")
			assert(Contains(results, GENERATED), "the generated id is still offered")
		end)

		_G.C_Spell.GetSpellName = realGetSpellName
		_G.GetTime = realGetTime
		categoryIds.Unflagged[CURATED] = nil

		assert(ok, err)
	end)
end)

fw.describe("SpellSearch - order within a generated group", function()
	-- The generator emits a name's spellbook id first, then the ids it triggers, and the picker
	-- shows only the first few, so file order is what decides which ids a player is offered.
	local ORDERED = { 999205, 999201, 999203 }

	for _, spellId in ipairs(ORDERED) do
		env.spellNames[spellId] = "Ordered Ability"
	end

	fw.it("offers a group's ids in file order, not by ascending id", function()
		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = { table.concat({ 999205, 999201, 999203 }, " ") },
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)

		local results = target.Core.SpellSearch:Search("ordered ability")

		assert(results[1] and results[1].Id == ORDERED[1],
			"the id the file leads with is the id the picker leads with")
	end)
end)

fw.describe("SpellSearch - sources", function()
	fw.it("covers a defensive the generated scan misses", function()
		-- Fortifying Brew is not in the aura category lists. The picker carries it itself rather
		-- than reaching into the cooldown tracker, which is 12.0-only.
		local fortifyingBrew = 115203
		local name = C_Spell.GetSpellName(fortifyingBrew)

		assert(not categoryIds.CC[fortifyingBrew] and not categoryIds.Defensive[fortifyingBrew],
			"fixture must be one the generated data lacks")
		-- Searched by name rather than asked for by id, since GetEntry answers for any id the
		-- client can name whether the index carries a row for it or not.
		assert(Contains(search:Search(name), fortifyingBrew), "the picker offers it anyway")
	end)

	fw.it("needs nothing from the cooldown module", function()
		assert(addon.Core.Cooldowns == nil, "the search index loaded without it")
	end)
end)

fw.describe("SpellSearch - the generated name index", function()
	fw.it("offers a name the curated lists have never heard of", function()
		assert(Contains(search:Search("sudden doom"), INVENTED), "the index feeds the suggestions")
	end)

	fw.it("still offers every curated id under a name the generated pass also carries", function()
		local results = search:Search("arcane torrent")

		assert(CountNamed(results, "Arcane Torrent") == #TORRENT_IDS,
			"the generated pass does not swallow any of the curated ids")
	end)
end)

fw.describe("SpellSearch - copies of a spell the current data covers", function()
	-- The curated lists carry a legacy or NPC id for nearly every ability, all sharing one name.
	-- The picker offers a row per id, so those copies would bury the id a player actually wants.

	---Runs `body` against a fresh SpellSearch whose generated index is exactly `index`.
	---@param index string[]
	---@param body fun(trimmed: SpellSearch)
	local function WithGeneratedIndex(index, body)
		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = index,
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)
		body(target.Core.SpellSearch)
	end

	fw.it("drops the ids under a name the generated index vouches for", function()
		WithGeneratedIndex({ tostring(TORRENT_IDS[1]) }, function(trimmed)
			local results = trimmed:Search("arcane torrent")

			assert(CountNamed(results, "Arcane Torrent") == 1, "the copies lose their rows")
			assert(Contains(results, TORRENT_IDS[1]), "the vouched id is the one left")
		end)
	end)

	fw.it("keeps every id of a name nothing vouches for", function()
		WithGeneratedIndex({}, function(trimmed)
			local results = trimmed:Search("arcane torrent")

			assert(CountNamed(results, "Arcane Torrent") == #TORRENT_IDS,
				"a name the curated list is the only source of keeps all of it")

			for _, spellId in ipairs(TORRENT_IDS) do
				assert(Contains(results, spellId), "id " .. spellId .. " still has its row")
			end
		end)
	end)
end)

fw.describe("SpellSearch - one name with more ids than the picker can show", function()
	-- Every id under a name draws the identical string, so a dozen of them would fill the list
	-- with rows a player has no way to tell apart.
	local FLOOD_IDS = { 999101, 999102, 999103, 999104, 999105, 999106, 999107 }
	local CAP = 5

	for _, spellId in ipairs(FLOOD_IDS) do
		env.spellNames[spellId] = "Floodlight"
	end

	---Runs `body` against a fresh SpellSearch whose generated index is one oversized group.
	---@param body fun(flooded: SpellSearch)
	local function WithFlood(body)
		local raw = {}

		for index, spellId in ipairs(FLOOD_IDS) do
			raw[index] = tostring(spellId)
		end

		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = { table.concat(raw, " ") },
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)
		body(target.Core.SpellSearch)
	end

	fw.it("offers no more rows for one name than the cap allows", function()
		WithFlood(function(flooded)
			local results = flooded:Search("floodlight")

			assert(#FLOOD_IDS > CAP, "the fixture must have more ids than the cap")
			assert(CountNamed(results, "Floodlight") == CAP, "the suggestions stop at the cap")
		end)
	end)

	fw.it("still answers for an id the cap left out", function()
		WithFlood(function(flooded)
			local excluded = FLOOD_IDS[#FLOOD_IDS]

			assert(not Contains(flooded:Search("floodlight"), excluded),
				"the fixture id must be one the cap leaves out")

			local entry = flooded:GetEntry(excluded)

			assert(entry and entry.Id == excluded, "the picker still answers for it by id")

			local typed = flooded:Search(tostring(excluded))

			assert(typed[1] and typed[1].Id == excluded, "and a fully typed id still leads the list")
		end)
	end)
end)

fw.describe("SpellSearch - a copy the client names late", function()
	-- The trim groups ids by name, so an id the client cannot name yet is no id it can judge.
	-- Those stay pending, and the name they land under is trimmed when they arrive.
	local frameTime = 0

	---Runs `body` against a fresh SpellSearch that cannot name `silentId`, with TORRENT_IDS[1] the
	---only id the generated index vouches for.
	---@param silentId number
	---@param body fun(late: SpellSearch, names: table<number, string>, nextFrame: fun())
	local function WithSilentId(silentId, body)
		local names = {}
		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = { tostring(TORRENT_IDS[1]) },
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		local realGetSpellName = _G.C_Spell.GetSpellName
		_G.C_Spell.GetSpellName = function(spellId)
			if spellId == silentId then
				return names[spellId]
			end

			return realGetSpellName(spellId)
		end

		local realGetTime = _G.GetTime
		_G.GetTime = function()
			return frameTime
		end

		assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)

		local ok, err = pcall(body, target.Core.SpellSearch, names, function()
			frameTime = frameTime + 1
		end)

		_G.C_Spell.GetSpellName = realGetSpellName
		_G.GetTime = realGetTime
		assert(ok, err)
	end

	fw.it("keeps the copies until the vouched id it cannot name yet arrives", function()
		WithSilentId(TORRENT_IDS[1], function(late, names, nextFrame)
			local before = late:Search("arcane torrent")

			assert(CountNamed(before, "Arcane Torrent") == #TORRENT_IDS - 1,
				"the copies stand in while nothing vouched can be named")
			assert(not Contains(before, TORRENT_IDS[1]), "the vouched id has no name to show yet")

			names[TORRENT_IDS[1]] = "Arcane Torrent"
			nextFrame()

			local results = late:Search("arcane torrent")

			assert(CountNamed(results, "Arcane Torrent") == 1, "naming it drops the copies")
			assert(Contains(results, TORRENT_IDS[1]), "and leaves it in their place")
		end)
	end)

	fw.it("drops a copy the client names after the trim already ran", function()
		WithSilentId(TORRENT_IDS[2], function(late, names, nextFrame)
			assert(CountNamed(late:Search("arcane torrent"), "Arcane Torrent") == 1,
				"the vouched id is the only row the build leaves")

			names[TORRENT_IDS[2]] = "Arcane Torrent"
			nextFrame()

			local results = late:Search("arcane torrent")

			assert(not Contains(results, TORRENT_IDS[2]), "a copy arriving late gets no row")
			assert(CountNamed(results, "Arcane Torrent") == 1, "the vouched id still stands alone")
		end)
	end)
end)

fw.describe("SpellSearch - the client's own language", function()
	-- The shipped index carries ids and no names, so whatever the client calls a spell is what the
	-- picker offers. That is the whole reason the names were dropped: a deDE player types German.
	local OTHER = 999004

	---Runs `body` against a fresh SpellSearch whose client answers with the given names. The names
	---stay installed for the whole body: the lookups read them too, not just the index build.
	---@param names table<number, string> Spell id -> what this client calls it.
	---@param body fun(localised: SpellSearch)
	local function WithClientNames(names, body)
		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = {
					("%d %d"):format(RAKE_CAST, RAKE_BLEED),
					tostring(OTHER),
				},
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		local realGetSpellName = _G.C_Spell.GetSpellName
		_G.C_Spell.GetSpellName = function(spellId)
			return names[spellId] or realGetSpellName(spellId)
		end

		assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)

		local ok, err = pcall(body, target.Core.SpellSearch)

		_G.C_Spell.GetSpellName = realGetSpellName
		assert(ok, err)
	end

	fw.it("offers a generated spell under its German name", function()
		WithClientNames({ [RAKE_CAST] = "Harken", [RAKE_BLEED] = "Harken" }, function(localised)
			assert(Contains(localised:Search("harken"), RAKE_CAST),
				"a deDE client must find the spell by the name it shows")
			assert(not Contains(localised:Search("rake"), RAKE_CAST),
				"and the English name is not what that client has")
		end)
	end)

	fw.it("gives every id a row when two groups collide under the same name", function()
		-- Distinct in English, identical in another language. Neither group's ids are lost to
		-- the merge, since a name collision no longer costs a row.
		WithClientNames({ [RAKE_CAST] = "Hieb", [RAKE_BLEED] = "Hieb", [OTHER] = "Hieb" },
			function(localised)
				local results = localised:Search("hieb")

				assert(CountNamed(results, "Hieb") == 3, "one row per id under the shared name")
				assert(Contains(results, RAKE_CAST), "the first group's cast survives the merge")
				assert(Contains(results, RAKE_BLEED), "the first group's bleed survives the merge")
				assert(Contains(results, OTHER), "the second group's id survives the merge")
			end)
	end)
end)

fw.describe("SpellSearch - spell data that arrives late", function()
	-- The index is built as early as login, and the client answers nothing for a spell whose data
	-- it has not loaded yet. Those ids have to join the index when it does load, or the spell is
	-- missing from the picker for the whole session.
	local LATE_CAST = 999005
	local LATE_AURA = 999006
	local GROUP_A = 999007
	local GROUP_B = 999008
	-- LATE_CURATED is a curated id whose name nothing else shares. LATE_TORRENT only keeps a
	-- real curated id silent alongside it; no test asserts on it directly.
	local LATE_CURATED = KIDNEY_SHOT
	local LATE_TORRENT = TORRENT_IDS[1]
	local SILENT = { LATE_CAST, LATE_AURA, GROUP_A, GROUP_B, LATE_CURATED, LATE_TORRENT }

	---Runs `body` against a fresh SpellSearch whose client cannot name any of SILENT. Filling
	---`names` from inside the body is what makes that spell's data arrive. Doing it before the
	---first lookup is data that was there all along, which is what the assertions compare to.
	---@param body fun(late: SpellSearch, names: table<number, string>)
	local frameTime = 0

	local function WithLateSpellData(body)
		local names = {}
		local silent = {}
		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = {
					("%d %d"):format(LATE_CAST, LATE_AURA),
					("%d %d"):format(GROUP_A, GROUP_B),
				},
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		for _, spellId in ipairs(SILENT) do
			silent[spellId] = true
		end

		local realGetSpellName = _G.C_Spell.GetSpellName
		_G.C_Spell.GetSpellName = function(spellId)
			if silent[spellId] then
				return names[spellId]
			end

			return realGetSpellName(spellId)
		end

		-- The retry throttle keys on the clock moving between frames, so the clock is the
		-- test's to move. The shared mock's needs an install this file never does.
		local realGetTime = _G.GetTime
		_G.GetTime = function()
			return frameTime
		end

		assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)

		local ok, err = pcall(body, target.Core.SpellSearch, names)

		_G.C_Spell.GetSpellName = realGetSpellName
		_G.GetTime = realGetTime
		assert(ok, err)
	end

	-- Pending retries run once per frame, so data that arrives late lands on a new frame here
	-- just as it does in the client.
	local function NextFrame()
		frameTime = frameTime + 1
	end

	fw.it("offers a group the client could not name at first", function()
		WithLateSpellData(function(late, names)
			assert(not Contains(late:Search("lightwell"), LATE_CAST),
				"a group with no name yet is nothing the picker can show")

			names[LATE_CAST] = "Lightwell"
			names[LATE_AURA] = "Lightwell"
			NextFrame()

			assert(Contains(late:Search("lightwell"), LATE_CAST),
				"once the client can name it, the picker offers it")
		end)
	end)

	fw.it("offers a curated spell the client could not name at first", function()
		WithLateSpellData(function(late, names)
			assert(not Contains(late:Search("latecomer"), LATE_CURATED),
				"a curated id with no name yet is nothing the picker can show")

			names[LATE_CURATED] = "Latecomer"
			NextFrame()

			local entry = late:GetEntry(LATE_CURATED)

			assert(Contains(late:Search("latecomer"), LATE_CURATED),
				"once the client can name it, the picker offers it")
			assert(entry and entry.Name == "Latecomer", "and its row carries the name")
		end)
	end)

	fw.it("gives a late curated spell its own row alongside a generated group under the same name", function()
		WithLateSpellData(function(late, names)
			-- Naming GROUP_A resolves the whole raw group, so both of its ids get a row even
			-- though GROUP_B is still individually unnamed. The curated id joins them rather
			-- than replacing anything, since a shared name is no longer a reason to collapse.
			names[GROUP_A] = "Wisplight"
			NextFrame()

			assert(CountNamed(late:Search("wisplight"), "Wisplight") == 2,
				"the generated group's two ids are the only rows while the curated id is unnamed")

			names[LATE_CURATED] = "Wisplight"
			NextFrame()

			local results = late:Search("wisplight")

			assert(CountNamed(results, "Wisplight") == 3,
				"the curated id gets its own row alongside the generated group's two ids")
			assert(Contains(results, GROUP_A), "the first generated id keeps its row")
			assert(Contains(results, GROUP_B), "the second generated id keeps its row too")
			assert(Contains(results, LATE_CURATED), "the curated id gets its own row")
		end)
	end)
end)

fw.describe("SpellSearch - ids this build has dropped", function()
	-- Unlike spell data that has not loaded, an id the client denies exists never will, so it
	-- must not join pendingIds or a keystroke would retry it for the rest of the session.
	local DROPPED_CURATED = KIDNEY_SHOT

	local function WithDroppedId(body)
		local names = {}
		local frameTime = 0
		local realGetSpellName = _G.C_Spell.GetSpellName
		local realDoesSpellExist = _G.C_Spell.DoesSpellExist

		_G.C_Spell.GetSpellName = function(spellId)
			if spellId == DROPPED_CURATED then
				return names[spellId]
			end

			return realGetSpellName(spellId)
		end

		_G.C_Spell.DoesSpellExist = function(spellId)
			if spellId == DROPPED_CURATED then
				return false
			end

			return realDoesSpellExist(spellId)
		end

		local realGetTime = _G.GetTime
		_G.GetTime = function()
			return frameTime
		end

		local target = {
			Core = {
				AuraCategoryIds = categoryIds,
				SpellNameIndex = {},
			},
			Utils = {},
			Modules = {},
			Config = {},
		}

		assert(loadfile("src/Core/Auras/SpellSearch.lua"))("MiniAuras", target)

		local ok, err = pcall(body, target.Core.SpellSearch, names, function()
			frameTime = frameTime + 1
		end)

		_G.C_Spell.GetSpellName = realGetSpellName
		_G.C_Spell.DoesSpellExist = realDoesSpellExist
		_G.GetTime = realGetTime
		assert(ok, err)
	end

	fw.it("never retries a curated id the client denies exists", function()
		WithDroppedId(function(dropped, names, nextFrame)
			assert(not Contains(dropped:Search("kidney shot"), DROPPED_CURATED),
				"an unnamed id is nothing the picker can show yet")

			-- Named after the index was already built, to prove the id never went on pendingIds
			-- rather than merely being unnamed so far.
			names[DROPPED_CURATED] = "Kidney Shot"
			nextFrame()

			assert(not Contains(dropped:Search("kidney shot"), DROPPED_CURATED),
				"an id DoesSpellExist refused is never retried, however it later answers")
		end)
	end)
end)
