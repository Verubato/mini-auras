-- The spell picker's index. Two things matter: a user typing part of an ability name has to find
-- it, and an ability whose id list carries several variants must be offered ONCE while still
-- expanding back to every variant when it is tracked (aura filters match the id the game applied,
-- which is frequently not the one in the spellbook).

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

-- A stand-in for the generated index. Rake is the case the whole thing exists for: 1822 is the
-- cast, 155722 is the bleed it leaves behind, and only the shared name links them.
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

	fw.it("offers a repeated ability once", function()
		local results = search:Search("arcane torrent")

		assert(CountNamed(results, "Arcane Torrent") == 1,
			"the four Arcane Torrent ids collapse into one suggestion")
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

	fw.it("answers with the id that was asked about, not the canonical variant", function()
		local entry = search:GetEntry(TORRENT_IDS[3])

		assert(entry and entry.Id == TORRENT_IDS[3], "the requested variant is echoed back")
		assert(entry.Name == "Arcane Torrent", "with the shared name")
	end)
end)

fw.describe("SpellSearch - sources", function()
	fw.it("covers a defensive the generated scan misses", function()
		-- Fortifying Brew is not in the aura category lists; the picker carries it itself rather
		-- than reaching into the cooldown tracker, which is 12.0-only.
		local fortifyingBrew = 115203

		assert(not categoryIds.CC[fortifyingBrew] and not categoryIds.Defensive[fortifyingBrew],
			"fixture must be one the generated data lacks")
		assert(search:GetEntry(fortifyingBrew), "the picker knows it anyway")
	end)

	fw.it("needs nothing from the cooldown module", function()
		assert(addon.Core.Cooldowns == nil, "the search index loaded without it")
	end)
end)

fw.describe("SpellSearch - the generated name index", function()
	fw.it("expands a cast id to the aura id that shares its name", function()
		local variants = search:GetVariants(RAKE_CAST)
		local seen = {}

		for _, spellId in ipairs(variants) do
			seen[spellId] = true
		end

		assert(seen[RAKE_CAST], "the id that was asked about is included")
		assert(seen[RAKE_BLEED], "so is the aura id, which no curated list carries")
	end)

	fw.it("expands from the aura id as well as the cast id", function()
		assert(#search:GetVariants(RAKE_BLEED) == #search:GetVariants(RAKE_CAST),
			"either end of the pair reaches the same set")
	end)

	fw.it("offers a name the curated lists have never heard of", function()
		assert(Contains(search:Search("sudden doom"), INVENTED), "the index feeds the suggestions")
	end)

	fw.it("still offers a curated ability once, not twice", function()
		assert(CountNamed(search:Search("arcane torrent"), "Arcane Torrent") == 1,
			"a name in both sources is one suggestion")
	end)
end)

fw.describe("SpellSearch - variants", function()
	fw.it("expands an ability to every id that shares its name", function()
		local variants = search:GetVariants(TORRENT_IDS[1])
		local seen = {}

		for _, spellId in ipairs(variants) do
			seen[spellId] = true
		end

		for _, spellId in ipairs(TORRENT_IDS) do
			assert(seen[spellId], "variant " .. spellId .. " is included")
		end
	end)

	fw.it("expands from any variant, not just the canonical one", function()
		assert(#search:GetVariants(TORRENT_IDS[4]) == #search:GetVariants(TORRENT_IDS[1]),
			"every variant expands to the same set")
	end)

	fw.it("hands an unknown id straight back", function()
		local variants = search:GetVariants(999002)

		assert(#variants == 1 and variants[1] == 999002, "an untracked id is its own only variant")
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

	fw.it("still expands a cast id to its aura id there", function()
		WithClientNames({ [RAKE_CAST] = "Harken", [RAKE_BLEED] = "Harken" }, function(localised)
			local seen = {}

			for _, spellId in ipairs(localised:GetVariants(RAKE_CAST)) do
				seen[spellId] = true
			end

			assert(seen[RAKE_BLEED],
				"the id bridge is the shared name, so it has to work in any language")
		end)
	end)

	fw.it("merges two groups the client gives the same name", function()
		-- Distinct in English, identical in another language. Neither group may swallow the other,
		-- or one ability's ids would vanish from every filter built on that name.
		WithClientNames({ [RAKE_CAST] = "Hieb", [RAKE_BLEED] = "Hieb", [OTHER] = "Hieb" },
			function(localised)
				local seen = {}

				for _, spellId in ipairs(localised:GetVariants(RAKE_CAST)) do
					seen[spellId] = true
				end

				assert(seen[RAKE_CAST] and seen[RAKE_BLEED], "the group's own ids survive")
				assert(seen[OTHER], "and so do the colliding group's")
			end)
	end)
end)
