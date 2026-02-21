---@type string, Addon
local addonName, addon = ...

---@class Localization
local L = {}
addon.L = L

local locale = GetLocale()
local strings = {}

-- Default locale (English)
local defaultStrings = {}

-- Set a localized string
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

-- Return current locale
function L:GetLocale()
	return locale
end
