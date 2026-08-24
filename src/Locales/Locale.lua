---@type string, Addon
local _, addon = ...

---@class Localization
local L = {} -- luaconv: L is the idiomatic locale-table name, read as addon.L
addon.L = L

local locale = GetLocale()
local strings = {}

-- Default locale (English)
local defaultStrings = {}

-- Locale code -> a function returning that locale's strings. Functions rather than the tables
-- themselves, because only one of them is ever read: a client is on one language at a time, and
-- changing it asks for a reload. Until a builder is called its strings are constants inside it
-- and cost nothing beyond the chunk they were compiled in, and ReleaseUnused then drops the ones
-- that will never be called so the strings go with them.
local registry = {}

local localeDisplayNames = {
	["enUS"] = "English",
	["enGB"] = "English",
	["deDE"] = "Deutsch",
	["esES"] = "Español",
	["esMX"] = "Español (México)",
	["frFR"] = "Français",
	["itIT"] = "Italiano",
	["ptBR"] = "Português",
	["koKR"] = "한국어",
	["ruRU"] = "Русский",
	["zhCN"] = "简体中文",
	["zhTW"] = "繁體中文",
}

---Register a locale's strings for later activation. Takes a function returning the table rather
---than the table, so a language nobody is using is never built.
---@param localeKey string
---@param builder fun(): table<string, string>
function L:RegisterLocale(localeKey, builder)
	registry[localeKey] = builder
end

-- Apply a registered locale as the active strings
function L:ApplyLocale(localeKey)
	wipe(strings)
	locale = localeKey

	local builder = registry[localeKey]
	if builder then
		for key, value in pairs(builder()) do
			strings[key] = value
		end
	end
end

---Forgets every locale but the active one. Their strings live inside the builders, so dropping
---the last reference to one makes its share of the eleven translations collectable, which is
---most of what the locale files weigh. Safe because switching language asks for a reload, and
---the reload keeps whichever one the user landed on.
---
---Separate from ApplyLocale so that applying a locale stays a plain, repeatable operation; this
---is the one-way step, and the addon takes it once the language is settled.
function L:ReleaseUnused()
	for key in pairs(registry) do
		if key ~= locale then
			registry[key] = nil
		end
	end
end

---Every locale the addon ships, whether or not its strings are still in memory. Driven by the
---display names rather than the registry, which ReleaseUnused empties out.
---@return { Key: string, Name: string }[]
function L:GetAvailableLocales()
	local result = {}
	for key, name in pairs(localeDisplayNames) do
		table.insert(result, { Key = key, Name = name })
	end
	-- By key as well as name, so the two English entries keep a stable order between sessions.
	table.sort(result, function(a, b)
		if a.Name == b.Name then
			return a.Key < b.Key
		end
		return a.Name < b.Name
	end)
	return result
end

function L:SetString(key, value)
	strings[key] = value
end

-- Set multiple localized strings at once
function L:SetStrings(stringTable)
	for key, value in pairs(stringTable) do
		strings[key] = value
	end
end

-- Set default strings (English)
function L:SetDefaultStrings(stringTable)
	for key, value in pairs(stringTable) do
		defaultStrings[key] = value
	end
end

-- Get a localized string, falling back to English if not found
function L:Get(key)
	return strings[key] or defaultStrings[key] or key
end

-- Convenience metatable for easier access: L["key"] instead of L:Get("key")
setmetatable(L, {
	__index = function(t, key)
		if type(key) == "string" then
			return strings[key] or defaultStrings[key] or key
		end
		return rawget(t, key)
	end,
})

function L:GetLocale()
	return locale
end

function L:GetDisplayName(localeKey)
	return localeDisplayNames[localeKey] or localeKey
end
