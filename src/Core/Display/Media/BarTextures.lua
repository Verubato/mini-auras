---@type string, Addon
local _, addon = ...

-- Bar fill textures offered to the user, by display name. LibSharedMedia supplies the rest of the
-- list. These four ship with the client and are listed regardless, so the dropdown is never empty
-- when the library fails to load, and they are named exactly as LibSharedMedia names them so the
-- two lists fold into one entry per texture.
local BUILT_IN = {
	["Blizzard"] = "Interface\\TargetingFrame\\UI-StatusBar",
	["Blizzard Character Skills Bar"] = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar",
	["Blizzard Raid Bar"] = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill",
	["Solid"] = "Interface\\Buttons\\WHITE8X8",
}

local DEFAULT_NAME = "Blizzard"
-- Height of the swatch shown beside each name, and how wide a strip of the texture to show. Both
-- are in the font's own pixels, since this is a label rather than the bar itself.
local SWATCH_HEIGHT = 10
local SWATCH_WIDTH = 72
-- One table, refilled in place. Consumers hold onto it and re-ask for the contents rather than
-- the table, because media addons register their textures whenever they happen to load, which is
-- routinely after a dropdown has already been built.
local nameScratch = {}
-- Fired when the media list gains entries, so anything showing it can catch up.
---@type fun()[]
local changeCallbacks = {}
local subscribedToMedia = false

---@class BarTextures
local M = {}
addon.Core.BarTextures = M

---@return table? library
local function SharedMedia()
	return LibStub and LibStub("LibSharedMedia-3.0", true)
end

local function NotifyChanged()
	for _, fn in ipairs(changeCallbacks) do
		fn()
	end
end

---Subscribes to the media library the first time anyone asks to hear about changes. Textures
---keep arriving for as long as addons keep loading, so a list built once is a list that is
---missing whatever loaded after it.
---
---The fan-out is coalesced: LibSharedMedia fires once per entry and a media pack registers its
---whole set inside one frame, so passing the burst straight through costs one full rebuild per
---texture.
local function EnsureMediaSubscription()
	if subscribedToMedia then
		return
	end

	local media = SharedMedia()

	if not media or not media.RegisterCallback then
		return
	end

	subscribedToMedia = true

	local queueNotify = addon.Utils.ModuleUtil:Coalesced(NotifyChanged)

	media.RegisterCallback(M, "LibSharedMedia_Registered", queueNotify)
	media.RegisterCallback(M, "LibSharedMedia_SetGlobal", queueNotify)
end

---The texture names to offer, sorted, with the built-ins always present.
---@return string[]
function M:GetNames()
	wipe(nameScratch)

	local seen = {}

	for name in pairs(BUILT_IN) do
		seen[name] = true
		nameScratch[#nameScratch + 1] = name
	end

	local media = SharedMedia()

	if media then
		for _, name in ipairs(media:List("statusbar") or {}) do
			if not seen[name] then
				seen[name] = true
				nameScratch[#nameScratch + 1] = name
			end
		end
	end

	table.sort(nameScratch)

	return nameScratch
end

---Resolves a saved texture name to a path, falling back to the default whenever the name came
---from a media addon that is no longer installed.
---@param name string?
---@return string
function M:Resolve(name)
	if name then
		local media = SharedMedia()

		if media and media:IsValid("statusbar", name) then
			return media:Fetch("statusbar", name)
		end

		if BUILT_IN[name] then
			return BUILT_IN[name]
		end
	end

	return BUILT_IN[DEFAULT_NAME]
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

---A name with a strip of its texture inline, for use as a dropdown label. The escape renders in
---any font string, so the list previews itself without a bespoke widget behind it.
---@param name string
---@return string
function M:GetLabel(name)
	return "|T" .. self:Resolve(name) .. ":" .. SWATCH_HEIGHT .. ":" .. SWATCH_WIDTH .. "|t " .. name
end
