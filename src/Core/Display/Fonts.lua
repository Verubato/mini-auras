---@type string, Addon
local _, addon = ...

-- The font face every module's text is drawn in. LibSharedMedia owns the list: its own faces plus
-- everything other addons have registered with it, which is where people's preferred fonts live.
-- It also gates fonts by client locale - a face has to declare Korean, Russian or Chinese support
-- to be offered on those clients - so the list is already free of the faces that would draw the
-- game's own text as boxes.
--
-- Nothing is registered here. The client's own faces arrive through the library, and a name that
-- resolves to nothing is left resolving to nothing on purpose: see Resolve.

-- One table, refilled in place. Consumers hold onto it and re-ask for the contents rather than
-- the table, because media addons register their fonts whenever they happen to load, which is
-- routinely after a dropdown has already been built.
local nameScratch = {}
-- Whether a file actually loads, by path. SetFont answers false for one the client cannot use -
-- a missing file, or a face it will not accept - and a refused SetFont leaves the string wearing
-- whatever it had. Offering such a name would swap the text the addon happens to redraw and
-- leave the rest, which reads as the setting working for some of the text and not the rest.
local usableFiles = {}
-- Hidden fontstring the check above is run against. Built on first use; a config page that never
-- opens and a profile with no font picked never build one.
local probeFontString
-- Fired when the media list gains entries, so anything showing or drawing it can catch up.
---@type fun()[]
local changeCallbacks = {}
local subscribedToMedia = false

---@class Fonts
local M = {}
addon.Core.Fonts = M

---@return table? library
local function SharedMedia()
	return LibStub and LibStub("LibSharedMedia-3.0", true)
end

local function NotifyChanged()
	for _, fn in ipairs(changeCallbacks) do
		fn()
	end
end

---Whether the client will actually draw with this file. Asked once per path.
---@param file string
---@return boolean
local function IsUsable(file)
	local known = usableFiles[file]

	if known ~= nil then
		return known
	end

	if not probeFontString then
		local frame = CreateFrame("Frame")

		frame:Hide()
		probeFontString = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end

	-- A client that answers nothing rather than a boolean is taken at its word that the file is
	-- fine: refusing every font on an unexpected return would be far worse than trusting one.
	usableFiles[file] = probeFontString:SetFont(file, 12, "") ~= false

	return usableFiles[file]
end

---Subscribes to the media library the first time anyone asks to hear about changes. Fonts keep
---arriving for as long as addons keep loading, so a list built once is a list that is missing
---whatever loaded after it.
---
---The fan-out is coalesced: LibSharedMedia fires once per entry and a media pack registers its
---whole set inside one frame, while every consumer here re-reads the sorted list.
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

---The font names to offer, sorted. Empty only if the library failed to load, which leaves the
---dropdown with the game's own font as its one entry.
---@return string[]
function M:GetNames()
	wipe(nameScratch)

	local media = SharedMedia()

	if media then
		for _, name in ipairs(media:List("font") or {}) do
			-- Left out rather than offered and quietly ignored: a name the client refuses would
			-- change nothing on screen, which reads as the whole setting being broken.
			local file = media:Fetch("font", name)

			if file and IsUsable(file) then
				nameScratch[#nameScratch + 1] = name
			end
		end
	end

	table.sort(nameScratch)

	return nameScratch
end

---The file a saved name maps to right now, or nil when nothing has registered it yet.
---
---Nil is the answer callers want rather than a fallback face: a media addon registers its fonts
---whenever it happens to load, routinely after our first pass, and a caller told "the game's own
---font" then would keep drawing that for the rest of the session. Nil means "leave the face
---alone", and the OnChanged refresh comes back once the name resolves.
---@param name string?
---@return string? file
function M:Resolve(name)
	if not name then
		return nil
	end

	local media = SharedMedia()

	if media and media:IsValid("font", name) then
		local file = media:Fetch("font", name)

		if file and IsUsable(file) then
			return file
		end
	end

	return nil
end

---Registers a function to call when the media list changes, i.e. when GetNames would now return
---something different, or a name that resolved to nothing now resolves.
---@param fn fun()
function M:OnChanged(fn)
	changeCallbacks[#changeCallbacks + 1] = fn
	EnsureMediaSubscription()
end
