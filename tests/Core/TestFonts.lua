-- The global font face, and the three properties that carry it. A name belonging to a media addon
-- that has not loaded yet must resolve to nothing, or the addon draws a stand-in face for the rest
-- of the session. The face a fontstring was built with has to survive the override, because
-- putting it back is the only way the option can be turned off. Picked text rides shared font
-- objects rather than per-string SetFont, because the client silently drops a SetFont whose file
-- it has not loaded yet, where strings attached to an object follow every change the object makes.

local fw = require("Framework")

local registered = {}
local callbacks = {}
local media = {
	List = function()
		local list = {}

		for key in pairs(registered) do
			list[#list + 1] = key
		end

		table.sort(list)

		return list
	end,
	IsValid = function(_, _, key)
		return registered[key] ~= nil
	end,
	Fetch = function(_, _, key)
		return registered[key]
	end,
	RegisterCallback = function(_, event, handler)
		callbacks[event] = handler
	end,
}

_G.LibStub = function(name)
	return name == "LibSharedMedia-3.0" and media or nil
end
_G.wipe = _G.wipe or function(t)
	for key in pairs(t) do
		t[key] = nil
	end

	return t
end

-- Coalesced defers through C_Timer.After. Immediate here, because every test asserts straight
-- after the event it fires. The burst test swaps in a holding version of its own.
_G.C_Timer = _G.C_Timer or {}
_G.C_Timer.After = function(_, callback)
	callback()
end

-- The After above runs its callback on the spot, which would collapse the distinction a coalesced
-- fan-out is about. These hold the callbacks so a burst can be counted.
local function withHeldTimers(body)
	local queued = {}
	local realAfter = _G.C_Timer.After

	_G.C_Timer.After = function(_, callback)
		queued[#queued + 1] = callback
	end

	local ok, err = pcall(body, queued)

	_G.C_Timer.After = realAfter

	assert(ok, err)
end

-- FontUtil's shared font families, created with their member definitions in the call the way
-- the client registers declared fonts. That atomicity is the point: there is no separate
-- SetFont step for a still-loading file to refuse.
_G.CreateFontFamily = function(_, members)
	local object = { Members = members }

	function object:GetFont()
		local first = self.Members and self.Members[1]

		if first then
			return first.file, first.height, first.flags
		end
	end

	return object
end

local db = {}
local addon = {
	Core = {},
	Utils = {},
	Framework = {
		GetSavedVars = function()
			return db
		end,
	},
}

assert(loadfile("src/Utils/ModuleUtil.lua"))("MiniAuras", addon)
assert(loadfile("src/Utils/FontUtil.lua"))("MiniAuras", addon)
assert(loadfile("src/Core/Display/Media/Fonts.lua"))("MiniAuras", addon)

local fonts = addon.Core.Fonts
local fontUtil = addon.Utils.FontUtil

local GAME_FACE = "Fonts\\FRIZQT__.TTF"
local PACK_FACE = "Interface/AddOns/SomeMediaPack/expressway.ttf"

---A fontstring with the client's precedence: whichever of SetFont and SetFontObject ran last
---decides what GetFont answers, and an attached object is read through live. Text calls are
---counted, because re-setting the text is what forces the client to redraw a static string in
---a newly attached object's font.
local function NewFontString(face)
	local fontString = { Face = face, Size = 12, Flags = "", Text = "hello", TextSets = 0 }

	function fontString:GetFont()
		if self.FontObject then
			return self.FontObject:GetFont()
		end

		return self.Face, self.Size, self.Flags
	end

	function fontString:SetFont(newFace, newSize, newFlags)
		self.FontObject = nil
		self.Face, self.Size, self.Flags = newFace, newSize, newFlags
	end

	function fontString:SetFontObject(object)
		self.FontObject = object
	end

	function fontString:GetFontObject()
		return self.FontObject
	end

	function fontString:GetText()
		return self.Text
	end

	function fontString:SetText(text)
		self.Text = text
		self.TextSets = self.TextSets + 1
	end

	return fontString
end

---The face a fontstring is drawing in right now, however it got it.
local function Worn(fontString)
	return (fontString:GetFont())
end

fw.describe("Fonts", function()
	fw.before_each(function()
		wipe(registered)
		wipe(db)
	end)

	fw.it("lists what the library has, and nothing when it has nothing", function()
		assert(#fonts:GetNames() == 0, "no fonts registered yet")

		registered["Expressway"] = PACK_FACE

		local names = fonts:GetNames()

		assert(#names == 1 and names[1] == "Expressway", "the registered face is listed")
	end)

	fw.it("picks up a font registered after the list was first read", function()
		local names = fonts:GetNames()

		registered["Expressway"] = PACK_FACE

		-- The same table, refilled: this is what the dropdown is holding.
		local refilled = fonts:GetNames()

		assert(refilled == names, "the table identity has to survive, or the dropdown loses it")
		assert(#refilled == 1, "the late font is listed, got " .. #refilled)
	end)

	fw.it("resolves a name to nothing until something registers it", function()
		assert(fonts:Resolve("Expressway") == nil, "an unregistered name has no file yet")
		assert(fonts:Resolve(nil) == nil, "nor has no name at all")

		registered["Expressway"] = PACK_FACE

		assert(fonts:Resolve("Expressway") == PACK_FACE, "and the file once it lands")
	end)

	fw.it("hands out one preview object per file, wearing that file", function()
		registered["Expressway"] = PACK_FACE

		local object = fonts:GetPreviewFontObject("Expressway")

		assert(object, "a resolvable name gets a preview object")

		local face, size = object:GetFont()

		assert(face == PACK_FACE, "wearing the font it previews")
		assert(size and size > 0, "at a real size")
		assert(fonts:GetPreviewFontObject("Expressway") == object,
			"the same file shares one object; menu rows churn and objects are for the session")
		assert(fonts:GetPreviewFontObject("Unregistered") == nil,
			"a name that resolves to nothing previews nothing")
	end)

	fw.it("tells its subscribers when the library gains a font", function()
		local told = 0

		fonts:OnChanged(function()
			told = told + 1
		end)

		assert(callbacks.LibSharedMedia_Registered, "subscribed to the library on first interest")

		callbacks.LibSharedMedia_Registered()

		assert(told == 1, "a registration is passed on")
	end)

	fw.it("tells them once for a burst, not once per registration", function()
		local told = 0

		fonts:OnChanged(function()
			told = told + 1
		end)

		withHeldTimers(function(queued)
			for _ = 1, 50 do
				callbacks.LibSharedMedia_Registered()
			end

			assert(told == 0, "nothing has run yet, the frame has not ended")
			assert(#queued == 1, "a burst queues one run, got " .. #queued)

			queued[1]()
		end)

		-- Every subscriber re-reads the whole list and the addon-wide one refreshes every module,
		-- so a font pack's set has to cost one pass rather than one per face.
		assert(told == 1, "a media pack's whole set costs one fan-out, not one per entry")
	end)
end)

fw.describe("FontUtil:Apply", function()
	fw.before_each(function()
		wipe(registered)
		wipe(db)
		-- FontUtil memoises the resolved file until the media list moves. Without this a name
		-- registered by an earlier test would keep resolving after the wipe above.
		if callbacks.LibSharedMedia_Registered then
			callbacks.LibSharedMedia_Registered()
		end
	end)

	fw.it("leaves the face alone when no font is configured", function()
		local text = NewFontString(GAME_FACE)

		fontUtil:Apply(text)

		assert(Worn(text) == GAME_FACE, "the string keeps what it was built with")
	end)

	fw.it("keeps the built face up while the pick is unresolved, then swaps", function()
		local text = NewFontString(GAME_FACE)

		db.Font = "Expressway"

		fontUtil:Apply(text)

		assert(Worn(text) == GAME_FACE,
			"an unregistered pick leaves the game face up rather than swapping to a stand-in")

		registered["Expressway"] = PACK_FACE
		callbacks.LibSharedMedia_Registered()

		fontUtil:Apply(text)

		assert(Worn(text) == PACK_FACE, "and swaps once the media addon registers it")
	end)

	fw.it("hands a re-applied string a different object when the pick changes", function()
		local text = NewFontString(GAME_FACE)
		local other = "Interface/AddOns/SomeMediaPack/other.ttf"

		registered["Expressway"] = PACK_FACE
		registered["Other"] = other
		db.Font = "Expressway"

		fontUtil:Apply(text)

		local firstObject = text.FontObject

		assert(Worn(text) == PACK_FACE, "fixture: wearing the first pick")

		db.Font = "Other"

		-- The refresh that accompanies a pick re-applies every string. A different object each
		-- time is the point. Editing the object a string already holds only repainted text that
		-- was about to redraw anyway, which left static text on the old face.
		fontUtil:Apply(text)

		assert(Worn(text) == other, "the re-apply lands the new pick")
		assert(text.FontObject ~= firstObject, "via a fresh object, never an edit to the old one")
	end)

	fw.it("re-sets a string's text when its object changes, and only then", function()
		local text = NewFontString(GAME_FACE)
		local other = "Interface/AddOns/SomeMediaPack/other.ttf"

		registered["Expressway"] = PACK_FACE
		registered["Other"] = other
		db.Font = "Expressway"

		-- The client keeps drawing a static string's old glyphs after SetFontObject until
		-- something dirties it. Rewriting its text is that something, cleared first because a
		-- SetText that changes nothing is dropped. This is what kept a once-written warning on
		-- its old face while every rewritten text followed the change.
		fontUtil:Apply(text)

		assert(text.TextSets == 2, "attaching clears and rewrites, got " .. text.TextSets)
		assert(text.Text == "hello", "ending on the text it already had")

		fontUtil:Apply(text)

		assert(text.TextSets == 2, "an unchanged attachment does not churn the text")

		db.Font = "Other"

		fontUtil:Apply(text)

		assert(text.TextSets == 4, "a new object rewrites again, got " .. text.TextSets)
	end)

	fw.it("builds a family whose own-locale member carries the file, at the asked size", function()
		registered["Expressway"] = PACK_FACE
		db.Font = "Expressway"

		local text = NewFontString(GAME_FACE)

		fontUtil:Apply(text, 26, "OUTLINE")

		local members = text.FontObject.Members

		assert(members and #members == 5, "one member per alphabet the client distinguishes")
		assert(members[1].alphabet == "roman" and members[1].file == PACK_FACE,
			"this locale's member wears the picked file")
		assert(members[1].height == 26 and members[1].flags == "OUTLINE",
			"at the size and flags asked for")
	end)

	fw.it("never re-fonts an object it has already handed out", function()
		local text = NewFontString(GAME_FACE)

		registered["Expressway"] = PACK_FACE
		db.Font = "Expressway"

		fontUtil:Apply(text)

		local object = text.FontObject
		local face, size, flags = object:GetFont()

		db.Font = false
		fontUtil:Apply(text)
		db.Font = "Expressway"
		fontUtil:Apply(text)

		assert(text.FontObject == object, "the same file at the same size reuses the object")

		local face2, size2, flags2 = object:GetFont()

		assert(face == face2 and size == size2 and flags == flags2,
			"and nothing has edited it in between")
	end)

	fw.it("puts the original face back when the option is cleared", function()
		local text = NewFontString(GAME_FACE)

		registered["Expressway"] = PACK_FACE
		db.Font = "Expressway"

		fontUtil:Apply(text)
		fontUtil:Apply(text)

		assert(Worn(text) == PACK_FACE, "fixture: wearing the override")

		db.Font = false

		fontUtil:Apply(text)

		assert(Worn(text) == GAME_FACE,
			"the face it was built with comes back, not the override it was wearing")
	end)

	fw.it("restores the base even when first touched with a font already picked", function()
		local text = NewFontString(GAME_FACE)

		registered["Expressway"] = PACK_FACE
		db.Font = "Expressway"

		-- First-ever pass with the pick active: attaching must not read the pick back as the
		-- face the game gave the string.
		fontUtil:Apply(text)

		db.Font = false

		fontUtil:Apply(text)

		assert(Worn(text) == GAME_FACE, "the game face comes back, not the override")
	end)

	fw.it("mirrors another string's own face, not the one it is wearing", function()
		local source = NewFontString(GAME_FACE)
		local mirror = NewFontString("Fonts\\ARIALN.TTF")

		registered["Expressway"] = PACK_FACE
		db.Font = "Expressway"

		fontUtil:Apply(source)
		-- A countdown's duration text takes the cooldown's own face so the two match. Taking the
		-- face it is wearing would bake the pick in as the mirror's.
		fontUtil:Apply(mirror, nil, nil, fontUtil:BaseFace(source))

		assert(Worn(mirror) == PACK_FACE, "fixture: both wearing the override")

		db.Font = false

		fontUtil:Apply(source)
		fontUtil:Apply(mirror, nil, nil, fontUtil:BaseFace(source))

		assert(Worn(source) == GAME_FACE, "the source goes back to its own face")
		assert(Worn(mirror) == GAME_FACE, "and so does the one mirroring it")
	end)

	fw.it("sizes picked text through the shared object", function()
		local text = NewFontString(GAME_FACE)

		registered["Expressway"] = PACK_FACE
		db.Font = "Expressway"

		fontUtil:UpdateFontSize(text, 30)

		local face, size = text:GetFont()

		assert(face == PACK_FACE, "the pick is on")
		assert(size == 12, "at the countdown ratio of the icon size, got " .. tostring(size))
	end)

	fw.it("sizes a stack count off the shared ratio", function()
		local text = NewFontString(GAME_FACE)

		fontUtil:UpdateStackFontSize(text, 40)

		local _, size = text:GetFont()

		assert(size == 15, "38% of the icon, got " .. tostring(size))
	end)

	fw.it("takes a caller's own stack ratio, for a row the shared one leaves unreadable", function()
		local text = NewFontString(GAME_FACE)

		fontUtil:UpdateStackFontSize(text, 18, 0.55)

		local _, size = text:GetFont()

		-- The shared ratio would give six points on an icon this small.
		assert(size == 9, "55% of the icon, got " .. tostring(size))
	end)
end)
