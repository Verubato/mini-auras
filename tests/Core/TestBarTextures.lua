-- Bar texture list. The failure this guards against is a quiet one: media addons register their
-- textures whenever they happen to load, which is routinely after a config page has been built,
-- so a list captured once is a list missing whatever came later. The dropdown holds this module's
-- table and re-reads its contents, so the contents have to be refilled in place.

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

-- The After installed below runs its callback on the spot, which would collapse the distinction
-- a coalesced fan-out is about; these hold the callbacks so a burst can be counted.
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

local libraryPresent = true

_G.LibStub = function(name)
	return (libraryPresent and name == "LibSharedMedia-3.0") and media or nil
end
_G.wipe = _G.wipe or function(t)
	for key in pairs(t) do
		t[key] = nil
	end

	return t
end

-- Coalesced defers its fan-out through C_Timer.After, so this file needs one of its own rather
-- than whichever the test run happens to leave lying around: the shared mock only installs a
-- timer with a client, and running this file on its own leaves none at all. Immediate, because
-- every test below asserts straight after the event it fires; the burst test swaps in a holding
-- version of its own.
_G.C_Timer = _G.C_Timer or {}
_G.C_Timer.After = function(_, callback)
	callback()
end

-- ModuleUtil comes along for Coalesced, which the media subscription defers its fan-out through.
local addon = { Core = {}, Utils = {} }
assert(loadfile("src/Utils/ModuleUtil.lua"))("MiniAuras", addon)
assert(loadfile("src/Core/Display/BarTextures.lua"))("MiniAuras", addon)
local barTextures = addon.Core.BarTextures

local BUILT_IN_COUNT = 4
local CUSTOM_PATH = "Interface/AddOns/SomeMediaPack/sharp"

local function Contains(list, value)
	for _, entry in ipairs(list) do
		if entry == value then
			return true
		end
	end

	return false
end

fw.describe("BarTextures", function()
	fw.before_each(function()
		wipe(registered)
		libraryPresent = true
	end)

	fw.it("lists the client's own textures with no library at all", function()
		libraryPresent = false

		local names = barTextures:GetNames()

		assert(#names == BUILT_IN_COUNT, "four built-ins, got " .. #names)
		assert(Contains(names, "Blizzard Raid Bar"), "including the one shipped as the default")
	end)

	fw.it("picks up a texture registered after the list was first read", function()
		local names = barTextures:GetNames()
		assert(#names == BUILT_IN_COUNT, "nothing registered yet")

		registered["Sharp"] = CUSTOM_PATH

		-- The same table, refilled: this is what the dropdown is holding.
		local refilled = barTextures:GetNames()
		assert(refilled == names, "the table identity has to survive, or the dropdown loses it")
		assert(#refilled == BUILT_IN_COUNT + 1 and Contains(refilled, "Sharp"), "the late texture is listed")
	end)

	fw.it("does not list the same texture twice under two names", function()
		-- The library ships these under exactly these names; the built-in copies must fold in.
		registered["Blizzard"] = "Interface/TargetingFrame/UI-StatusBar"
		registered["Blizzard Raid Bar"] = "Interface/RaidFrame/Raid-Bar-Hp-Fill"

		local names = barTextures:GetNames()
		local seen = {}

		for _, name in ipairs(names) do
			assert(not seen[name], "duplicate entry for " .. name)
			seen[name] = true
		end

		assert(#names == BUILT_IN_COUNT, "the two lists fold together, got " .. #names)
	end)

	fw.it("resolves through the library, then the built-ins, then the default", function()
		registered["Sharp"] = CUSTOM_PATH

		assert(barTextures:Resolve("Sharp") == CUSTOM_PATH, "the library wins where it knows the name")
		assert(barTextures:Resolve("Solid"):find("WHITE8X8"), "built-ins resolve without it")
		assert(barTextures:Resolve("Uninstalled Pack"):find("UI%-StatusBar"),
			"a name from a media pack that is gone falls back rather than blanking the bar")
		assert(barTextures:Resolve(nil):find("UI%-StatusBar"), "so does no name at all")
	end)

	fw.it("labels a texture with a strip of itself", function()
		registered["Sharp"] = CUSTOM_PATH

		local label = barTextures:GetLabel("Sharp")

		assert(label:sub(1, 2) == "|T", "the escape leads, so the strip renders before the name")
		assert(label:find(CUSTOM_PATH, 1, true), "and points at the texture being named")
		assert(label:find("Sharp", 1, true), "with the name still readable")
	end)

	fw.it("tells its subscribers when the library gains a texture", function()
		local told = 0

		barTextures:OnChanged(function()
			told = told + 1
		end)

		assert(callbacks.LibSharedMedia_Registered, "subscribed to the library on first interest")

		callbacks.LibSharedMedia_Registered()
		assert(told == 1, "a registration is passed on")
	end)

	fw.it("tells them once for a burst, not once per registration", function()
		local told = 0

		barTextures:OnChanged(function()
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

		assert(told == 1, "a media pack's whole set costs one rebuild, not one per entry")
	end)
end)
