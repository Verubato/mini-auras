---@type string, Addon
local _, addon = ...

-- The font face every module's text is drawn in. LibSharedMedia owns the list: its own faces plus
-- everything other addons have registered with it. FontUtil draws with what Resolve hands back.

-- The preview rows are menu rows, so their text matches the menu's own size.
local PREVIEW_FONT_SIZE = 13

-- One table, refilled in place. Consumers hold onto it and re-ask for the contents rather than
-- the table, because media addons register their fonts whenever they happen to load, which is
-- routinely after a dropdown has already been built.
local nameScratch = {}
-- Fired when the media list gains entries, so anything showing or drawing it can catch up.
---@type fun()[]
local changeCallbacks = {}
local subscribedToMedia = false
local queueNotify

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

	local queue = function()
		M:QueueChanged()
	end

	media.RegisterCallback(M, "LibSharedMedia_Registered", queue)
	media.RegisterCallback(M, "LibSharedMedia_SetGlobal", queue)
end

---Runs the change fan-out at the end of the frame, once however many times it is asked for in one.
---The media callbacks come through here, and so does FontUtil when a font file the client was still
---loading finally lands. The same consumers need the same catch-up either way.
function M:QueueChanged()
	queueNotify = queueNotify or addon.Utils.ModuleUtil:Coalesced(NotifyChanged)

	queueNotify()
end

---The font names to offer, sorted. Empty only if the library failed to load, which leaves the
---dropdown with the game's own font as its one entry.
---
---The library gates faces by client locale: a face has to declare Korean, Russian or Chinese
---support to be offered on those clients, so the list carries no face that would draw the game's
---own text as boxes.
---@return string[]
function M:GetNames()
	wipe(nameScratch)

	local media = SharedMedia()

	if media then
		-- Every registered name is offered. SetFont's answer is not a per-file verdict, since it
		-- answers false for a file it has merely not loaded yet, and believing one cut the dropdown
		-- from fifty entries to four for the session.
		for _, name in ipairs(media:List("font") or {}) do
			if media:Fetch("font", name) then
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
		return media:Fetch("font", name)
	end

	return nil
end

---A font object wearing this name's own file, for a dropdown row that previews the font it
---names. Nil when the name resolves to nothing, which leaves that row in the menu's face.
---FontUtil owns the object cache, so a previewed font and a picked one share their objects.
---@param name string?
---@return table? object
function M:GetPreviewFontObject(name)
	local file = M:Resolve(name)

	if not file then
		return nil
	end

	return addon.Utils.FontUtil:FileFontObject(file, PREVIEW_FONT_SIZE)
end

---Registers a function to call when the media list changes, i.e. when GetNames would now return
---something different, or a name that resolved to nothing now resolves.
---@param fn fun()
function M:OnChanged(fn)
	changeCallbacks[#changeCallbacks + 1] = fn
	EnsureMediaSubscription()
end
