---@type string, Addon
local addonName, addon = ...

-- Where MiniAuras's own sound files live. Kept here rather than read from Config because Core loads
-- first, and the built-ins are registered with LibSharedMedia at load so they are in the list
-- before any panel asks for it.
local SOUND_LOCATION = "Interface\\AddOns\\" .. addonName .. "\\Sounds\\Effects\\"
-- MiniAuras's own sounds, by the name they are offered under. The file name without its extension,
-- so the dropdown reads as a name rather than a path. Registered with LibSharedMedia, which folds
-- them into one list with everything else registered there and lets other addons use them too.
local BUILT_IN = {
	["AirHorn"] = "AirHorn.ogg",
	["AlertToastWarm"] = "AlertToastWarm.ogg",
	["BubblePop"] = "BubblePop.ogg",
	["CheerfulHarp"] = "CheerfulHarp.ogg",
	["CinematicHit"] = "CinematicHit.ogg",
	["ElectricalSpark"] = "ElectricalSpark.ogg",
	["Error"] = "Error.ogg",
	["NewNotification09"] = "NewNotification09.ogg",
	["Notification18"] = "Notification18.ogg",
	["Notification38"] = "Notification38.ogg",
	["Sonar"] = "Sonar.ogg",
	["SuddenShock"] = "SuddenShock.ogg",
	["WatchOut"] = "WatchOut.ogg",
	["WhooshSwing"] = "WhooshSwing.ogg",
}
-- Only meaningful to Chinese clients, so it is offered only where it can be understood.
local LOCALE_ONLY = {
	["XiaYike"] = { File = "XiaYike.ogg", Locales = { zhCN = true, zhTW = true } },
}

local DEFAULT_NAME = "Sonar"
-- One table, refilled in place. Consumers hold onto it and re-ask for the contents rather than
-- the table, because media addons register their sounds whenever they happen to load, which is
-- routinely after a dropdown has already been built.
local nameScratch = {}
-- Fired when the media list gains entries, so anything showing it can catch up.
---@type fun()[]
local changeCallbacks = {}
local subscribedToMedia = false
local registeredBuiltIns = false

---@class Sounds
local M = {}
addon.Core.Sounds = M

---@return table? library
local function SharedMedia()
	return LibStub and LibStub("LibSharedMedia-3.0", true)
end

---Hands MiniAuras's own files to the media library, once. Doing it lazily rather than at file scope
---keeps the order robust: LibStub is loaded before Core, but a failed library is not worth an
---error at load when the addon works fine without one.
local function EnsureBuiltInsRegistered()
	if registeredBuiltIns then
		return
	end

	local media = SharedMedia()

	if not media or not media.Register then
		return
	end

	registeredBuiltIns = true

	for name, file in pairs(BUILT_IN) do
		media:Register("sound", name, SOUND_LOCATION .. file)
	end

	local locale = GetLocale()

	for name, entry in pairs(LOCALE_ONLY) do
		if entry.Locales[locale] then
			media:Register("sound", name, SOUND_LOCATION .. entry.File)
		end
	end
end

local function OnMediaRegistered()
	for _, fn in ipairs(changeCallbacks) do
		fn()
	end
end

---Subscribes to the media library the first time anyone asks to hear about changes. Sounds keep
---arriving for as long as addons keep loading, so a list built once is a list that is missing
---whatever loaded after it.
local function EnsureMediaSubscription()
	if subscribedToMedia then
		return
	end

	local media = SharedMedia()

	if not media or not media.RegisterCallback then
		return
	end

	subscribedToMedia = true
	media.RegisterCallback(M, "LibSharedMedia_Registered", OnMediaRegistered)
	media.RegisterCallback(M, "LibSharedMedia_SetGlobal", OnMediaRegistered)
end

---The file a built-in name maps to, taking the locale-gated ones into account.
---@param name string
---@return string? file
local function BuiltInFile(name)
	if BUILT_IN[name] then
		return BUILT_IN[name]
	end

	local entry = LOCALE_ONLY[name]

	if entry and entry.Locales[GetLocale()] then
		return entry.File
	end

	return nil
end

-- Public

---The sound names to offer, sorted, with MiniAuras's own always present.
---@return string[]
function M:GetNames()
	EnsureBuiltInsRegistered()
	wipe(nameScratch)

	local seen = {}
	local media = SharedMedia()

	if media then
		for _, name in ipairs(media:List("sound") or {}) do
			seen[name] = true
			nameScratch[#nameScratch + 1] = name
		end
	end

	-- Only reached when the library failed to load, in which case its list is empty and ours is
	-- the whole dropdown.
	for name in pairs(BUILT_IN) do
		if not seen[name] then
			seen[name] = true
			nameScratch[#nameScratch + 1] = name
		end
	end

	table.sort(nameScratch)

	return nameScratch
end

---The name a saved value should be shown and matched under. Options used to store a bare file
---name, so anything still holding one is folded onto the media name for the same sound rather
---than showing up as a selection that matches nothing in the list.
---@param name string?
---@return string
function M:Normalise(name)
	if not name then
		return DEFAULT_NAME
	end

	local stripped = name:match("^(.+)%.ogg$")

	if stripped and BuiltInFile(stripped) then
		return stripped
	end

	return name
end

---Resolves a saved sound name to a file path, falling back to the default whenever the name came
---from a media addon that is no longer installed.
---@param name string?
---@return string
function M:Resolve(name)
	EnsureBuiltInsRegistered()

	local resolved = self:Normalise(name)
	local media = SharedMedia()

	if media and media:IsValid("sound", resolved) then
		return media:Fetch("sound", resolved)
	end

	local file = BuiltInFile(resolved)

	if file then
		return SOUND_LOCATION .. file
	end

	return SOUND_LOCATION .. BUILT_IN[DEFAULT_NAME]
end

---@return string
function M:GetDefaultName()
	return DEFAULT_NAME
end

---Registers a function to call when the media list changes, i.e. when GetNames would now return
---something different.
---@param fn fun()
function M:OnChanged(fn)
	changeCallbacks[#changeCallbacks + 1] = fn
	EnsureMediaSubscription()
end
