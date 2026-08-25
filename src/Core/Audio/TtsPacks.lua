---@type string, Addon
local addonName, addon = ...

-- Voice packs for the baked TTS clips: the ones shipped under Sounds/TTS plus any another addon
-- registers through the public API. One owner for names, paths and validation.

-- Shipped packs live one folder per pack under here; an external pack brings its own path.
local BASE_PATH = "Interface\\AddOns\\" .. addonName .. "\\Sounds\\TTS\\"
-- Pack name -> base path (with its trailing backslash) for packs other addons registered.
local externalPaths = {}
-- Pack name -> locale lookup for external packs that only make sense on some clients. A pack with
-- no entry here is offered everywhere.
local externalLocales = {}
-- The same names as an array, kept sorted so the dropdown order doesn't depend on load order.
local externalNames = {}
-- Shipped names then external ones. Refilled in place rather than replaced: the config dropdown
-- holds this table and re-reads its contents.
local mergedNames = {}
local mergedNamesValid = false
-- Stands in for the generated list before it exists, so the tests can load this file alone.
local EMPTY = {}

---@class TtsPacks
local M = {}

addon.Core.TtsPacks = M

-- Read lazily: the generated file loads after this one, and the module tests skip it entirely.
---@return string[]
local function ShippedPacks()
	local data = addon.Core.AuraTtsSounds

	return data and data.Packs or EMPTY
end

---@param name string?
---@return boolean
local function IsShipped(name)
	local shipped = ShippedPacks()

	for i = 1, #shipped do
		if shipped[i] == name then
			return true
		end
	end

	return false
end

---A pack that names locales is only worth offering where its clips can be understood. A voice in
---another language ships as its own addon, so only an external pack names locales.
---@param name string?
---@return boolean
local function IsAvailable(name)
	local lookup = externalLocales[name]

	if not lookup then
		return true
	end

	return lookup[GetLocale()] == true
end

---Every pack name for the dropdown: shipped first, in the order they were generated, then the
---external ones by name.
---@return string[]
function M:Names()
	if mergedNamesValid then
		return mergedNames
	end

	wipe(mergedNames)

	local shipped = ShippedPacks()

	for i = 1, #shipped do
		if IsAvailable(shipped[i]) then
			mergedNames[#mergedNames + 1] = shipped[i]
		end
	end

	for i = 1, #externalNames do
		if IsAvailable(externalNames[i]) then
			mergedNames[#mergedNames + 1] = externalNames[i]
		end
	end

	mergedNamesValid = true

	return mergedNames
end

---Adds a voice pack owned by another addon. Returns false rather than erroring when the spec is
---unusable or the name is taken, so a caller can react without wrapping the call.
---@param name string
---@param basePath string folder holding the pack's clips
---@param locales string[]? client locales the pack is for; nil offers it everywhere
---@return boolean registered
function M:Register(name, basePath, locales)
	if type(name) ~= "string" or name == "" then
		return false
	end

	if type(basePath) ~= "string" or basePath == "" then
		return false
	end

	local lookup

	if locales ~= nil then
		if type(locales) ~= "table" then
			return false
		end

		lookup = {}

		for i = 1, #locales do
			if type(locales[i]) ~= "string" then
				return false
			end

			lookup[locales[i]] = true
		end
	end

	-- A name is reserved by every pack, including the ones this locale never sees, so the same
	-- saved value always means the same pack whichever client reads it.
	if IsShipped(name) or externalPaths[name] then
		return false
	end

	if basePath:sub(-1) ~= "\\" then
		basePath = basePath .. "\\"
	end

	externalPaths[name] = basePath
	externalLocales[name] = lookup
	externalNames[#externalNames + 1] = name
	table.sort(externalNames)

	mergedNamesValid = false

	-- Refill straight away once the list has been handed out: whoever holds it re-reads its
	-- contents rather than asking again, so an invalidated cache alone would leave them stale.
	if #mergedNames > 0 then
		self:Names()
	end

	return true
end

---Maps a saved pack name onto one that exists here, so a pack whose addon was uninstalled or that
---this locale never offers falls back to a shipped voice instead of playing nothing.
---@param name string?
---@return string
function M:Resolve(name)
	if (externalPaths[name] or IsShipped(name)) and IsAvailable(name) then
		return name
	end

	local shipped = ShippedPacks()

	for i = 1, #shipped do
		if IsAvailable(shipped[i]) then
			return shipped[i]
		end
	end

	-- Nothing is offered here, which the shipped list should never allow; hand back a name anyway
	-- so callers still get a path string.
	return shipped[1]
end

---Base path of a resolved pack, ending in a backslash.
---@param name string a name Resolve returned
---@return string
function M:Path(name)
	return externalPaths[name] or (BASE_PATH .. name .. "\\")
end
