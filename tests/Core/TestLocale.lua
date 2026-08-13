-- The locale registry. The addon ships eleven translations and reads exactly one of them, so the
-- rest are registered as builders that are never called and then dropped. What matters here is
-- that the right client still gets its own language, that English works with nothing registered
-- at all, and that the language dropdown survives the drop.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

---A fresh Locale.lua against a throwaway addon table, so each test starts from an empty registry.
---@return Localization
local function newLocale()
	local addon = {}

	assert(loadfile("src/Locales/Locale.lua"))("MiniAuras", addon)

	return addon.L
end

---@param L Localization
---@param key string
---@param strings table<string, string>
---@return fun(): number calls Times the builder has been run.
local function register(L, key, strings)
	local calls = 0

	L:RegisterLocale(key, function()
		calls = calls + 1
		return strings
	end)

	return function()
		return calls
	end
end

fw.describe("Locale - reading one language out of eleven", function()
	fw.it("builds only the locale that gets applied", function()
		local L = newLocale()
		local deCalls = register(L, "deDE", { Hello = "Hallo" })
		local ruCalls = register(L, "ruRU", { Hello = "Привет" })

		assert(deCalls() == 0 and ruCalls() == 0, "registering must not build anything")

		L:ApplyLocale("deDE")

		assert(deCalls() == 1, "the applied locale is built")
		assert(ruCalls() == 0, "the others are not")
		assert(L["Hello"] == "Hallo", "and its strings are the live ones")
	end)

	fw.it("falls back to the English defaults for a key a translation lacks", function()
		local L = newLocale()

		L:SetDefaultStrings({ Hello = "Hello", Goodbye = "Goodbye" })
		register(L, "deDE", { Hello = "Hallo" })
		L:ApplyLocale("deDE")

		assert(L["Hello"] == "Hallo", "translated where there is a translation")
		assert(L["Goodbye"] == "Goodbye", "English where there is not")
	end)

	fw.it("leaves an English client on the defaults, with nothing registered", function()
		-- enUS registers no table of its own: the defaults ARE its strings.
		local L = newLocale()

		L:SetDefaultStrings({ Hello = "Hello" })
		register(L, "deDE", { Hello = "Hallo" })
		L:ApplyLocale("enUS")

		assert(L["Hello"] == "Hello", "an unregistered locale reads through to the defaults")
	end)

	fw.it("hands back the key itself for a string nobody has", function()
		local L = newLocale()

		L:ApplyLocale("enUS")

		assert(L["Untranslated"] == "Untranslated", "the key is its own last resort")
	end)
end)

fw.describe("Locale - releasing what will never be read", function()
	fw.it("keeps the active language working after the others are dropped", function()
		local L = newLocale()

		L:SetDefaultStrings({ Hello = "Hello" })
		register(L, "deDE", { Hello = "Hallo" })
		register(L, "ruRU", { Hello = "Привет" })

		L:ApplyLocale("deDE")
		L:ReleaseUnused()

		assert(L["Hello"] == "Hallo", "the applied locale is untouched")
		assert(L:GetLocale() == "deDE", "and still reported as the current one")
	end)

	fw.it("never builds the locales it drops", function()
		local L = newLocale()

		register(L, "deDE", { Hello = "Hallo" })
		local ruCalls = register(L, "ruRU", { Hello = "Привет" })

		L:ApplyLocale("deDE")
		L:ReleaseUnused()

		assert(ruCalls() == 0, "a dropped builder must never have run - that is the whole saving")
	end)

	fw.it("still offers every shipped language to the dropdown", function()
		-- The list comes from the shipped display names, not from what is still registered, or
		-- releasing would leave the user unable to pick anything else.
		local L = newLocale()

		register(L, "deDE", { Hello = "Hallo" })
		L:ApplyLocale("deDE")
		L:ReleaseUnused()

		local available = L:GetAvailableLocales()
		local byKey = {}

		for _, entry in ipairs(available) do
			byKey[entry.Key] = entry.Name
		end

		for _, key in ipairs({ "enUS", "enGB", "deDE", "esES", "esMX", "frFR", "itIT", "ptBR",
			"ruRU", "koKR", "zhCN", "zhTW" }) do
			assert(byKey[key], key .. " must still be offered after the release")
		end

		assert(byKey.ruRU == "Русский", "with its display name, not its code")
	end)

	fw.it("orders the two English entries predictably", function()
		local L = newLocale()
		local available = L:GetAvailableLocales()
		local seen = {}

		for index, entry in ipairs(available) do
			seen[entry.Key] = index
		end

		assert(seen.enGB < seen.enUS,
			"they share a display name, so the code breaks the tie rather than pairs order")
	end)
end)
