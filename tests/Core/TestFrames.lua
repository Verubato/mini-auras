-- Frames:GetAll's reuse contract. Its callers hand it a long-lived scratch table, so two
-- properties have to hold: the table handed back is the one passed in, and it is wiped rather
-- than appended to. A caller that held the result across two calls, or a provider that stopped
-- wiping, would otherwise pass the whole suite.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

local db = {}

local addon = {
	Utils = {},
	Core = {},
	Modules = {},
	Config = {},
	Framework = {
		GetSavedVars = function()
			return db
		end,
		NotifyWithPrefix = function() end,
		Append = function(_, src, dst)
			for i = 1, #src do
				dst[#dst + 1] = src[i]
			end
		end,
	},
}

-- No third-party unit-frame addon is present, so every provider but CustomFrames contributes
-- nothing. That is the point: the contract has to hold on the emptiest possible client.
_G.C_AddOns = {
	GetAddOnEnableState = function()
		return 0
	end,
}

local function loadFile(path)
	assert(loadfile(path))("MiniAuras", addon)
end

loadFile("src/Utils/WoWEx.lua")
loadFile("src/Utils/ModuleUtil.lua")
loadFile("src/Core/Frames/Frames.lua")
loadFile("src/Core/Frames/ArenaFrames.lua")
loadFile("src/Core/Frames/TestFrames.lua")
loadFile("src/Core/Frames/ExternalProviders.lua")
for _, provider in ipairs({
	"Blizzard", "DandersFrames", "ElvUI", "Grid2", "ShadowedUF", "Plexus", "VuhDo", "Cell",
	"TPerl", "EnhancedQoL", "Buzzard", "NDui", "GW2UI", "MSUF", "UUF",
}) do
	loadFile("src/Core/Frames/" .. provider .. ".lua")
end

local frames = addon.Core.Frames

-- Init reads the saved variables and builds the stand-in frames. Only the former is wanted here,
-- and the stand-ins need a far richer frame mock than the contract under test does.
frames.CreateTestFrames = function() end
frames:Init()

---A visible global frame the CustomFrames provider will pick up, named so db.AnchorN can reach it.
---@param name string
---@return table
local function NewAnchor(name)
	local frame = _G.CreateFrame("Frame", name)
	_G[name] = frame
	return frame
end

NewAnchor("TestAnchorAlpha")
NewAnchor("TestAnchorBeta")

fw.describe("Frames:GetAll - the reuse contract", function()
	fw.before_each(function()
		for key in pairs(db) do
			db[key] = nil
		end
	end)

	fw.it("hands back the very table it was given", function()
		db.Anchor1 = "TestAnchorAlpha"

		local scratch = {}
		local result = frames:GetAll(true, false, scratch)

		assert(result == scratch, "the caller's table is the result, not a copy")
		assert(#result == 1, "and it holds the one anchor, got " .. #result)
	end)

	fw.it("wipes rather than appends, so a second call does not accumulate", function()
		db.Anchor1 = "TestAnchorAlpha"
		db.Anchor2 = "TestAnchorBeta"

		local scratch = {}
		frames:GetAll(true, false, scratch)
		assert(#scratch == 2, "fixture: two anchors on the first pass")

		frames:GetAll(true, false, scratch)

		assert(#scratch == 2,
			"a reused table must be wiped; got " .. #scratch .. " after a second identical call")
	end)

	fw.it("drops an anchor that has gone away", function()
		db.Anchor1 = "TestAnchorAlpha"
		db.Anchor2 = "TestAnchorBeta"

		local scratch = {}
		frames:GetAll(true, false, scratch)
		assert(#scratch == 2, "fixture: two to begin with")

		db.Anchor2 = nil
		frames:GetAll(true, false, scratch)

		assert(#scratch == 1, "the second anchor must not survive in the scratch, got " .. #scratch)
		assert(scratch[1] == _G.TestAnchorAlpha, "and the survivor is the right one")
	end)

	fw.it("still allocates a fresh table when no scratch is offered", function()
		db.Anchor1 = "TestAnchorAlpha"

		local first = frames:GetAll(true, false)
		local second = frames:GetAll(true, false)

		assert(first ~= second, "callers passing nothing must not share a table by accident")
	end)
end)

-- ForEachAnchor takes that contract off the callers: it owns the list it walks, so the only way to
-- break it is to start a second walk inside the first, which it refuses.
fw.describe("Frames:ForEachAnchor", function()
	local function AlwaysVisible()
		return true
	end

	fw.before_each(function()
		for key in pairs(db) do
			db[key] = nil
		end

		-- A test that hid an anchor must not leave it hidden for the next one.
		_G.TestAnchorAlpha.IsVisible = AlwaysVisible
		_G.TestAnchorBeta.IsVisible = AlwaysVisible
	end)

	fw.it("calls back once per anchor, handing the arg straight through", function()
		db.Anchor1 = "TestAnchorAlpha"
		db.Anchor2 = "TestAnchorBeta"

		local token = {}
		local walked = {}

		frames:ForEachAnchor(true, false, function(anchor, arg)
			assert(arg == token, "the arg must reach the callback untouched")
			walked[#walked + 1] = anchor
		end, token)

		assert(#walked == 2, "both anchors must be walked, got " .. #walked)
		assert(walked[1] == _G.TestAnchorAlpha, "and in the order the providers appended them")
		assert(walked[2] == _G.TestAnchorBeta, "and in the order the providers appended them")
	end)

	fw.it("leaves out a hidden anchor when visibleOnly", function()
		db.Anchor1 = "TestAnchorAlpha"
		db.Anchor2 = "TestAnchorBeta"

		_G.TestAnchorBeta.IsVisible = function()
			return false
		end

		local visible = 0
		frames:ForEachAnchor(true, false, function()
			visible = visible + 1
		end)

		assert(visible == 1, "the hidden anchor must be skipped, got " .. visible)

		local all = 0
		frames:ForEachAnchor(false, false, function()
			all = all + 1
		end)

		assert(all == 2, "and kept when the caller asks for every anchor, got " .. all)
	end)

	fw.it("refuses a walk started inside another", function()
		db.Anchor1 = "TestAnchorAlpha"

		local nestedOk, nestedErr

		frames:ForEachAnchor(true, false, function()
			nestedOk, nestedErr = pcall(function()
				frames:ForEachAnchor(true, false, function() end)
			end)
		end)

		assert(nestedOk == false, "a nested walk must raise rather than share the list")
		assert(tostring(nestedErr):find("ForEachAnchor", 1, true), "and name what refused it")
	end)

	fw.it("clears its guard when the callback throws", function()
		db.Anchor1 = "TestAnchorAlpha"

		local ok = pcall(frames.ForEachAnchor, frames, true, false, function()
			error("callback blew up")
		end)

		assert(not ok, "the callback's error must reach the caller")

		local count = 0
		frames:ForEachAnchor(true, false, function()
			count = count + 1
		end)

		assert(count == 1, "and the next walk must not mistake itself for a nested one, got " .. count)
	end)
end)

-- A provider asking for a refresh must not get one inside its own call stack: the aura sound
-- registrations a refresh reaches are restricted, and the engine refuses them to a foreign
-- addon's execution.
fw.describe("Frames:RegisterProvider - the refresh callback", function()
	fw.it("defers the refresh out of the provider's stack, one pass per burst", function()
		local realAfter = _G.C_Timer.After
		local queue = {}
		local refreshes = 0

		_G.C_Timer.After = function(_, fn)
			queue[#queue + 1] = fn
		end
		addon.Refresh = function()
			refreshes = refreshes + 1
		end

		local notify

		frames:RegisterProvider({
			Name = "TestDeferredProvider",
			GetFrames = function()
				return {}
			end,
			RegisterRefreshFrames = function(callback)
				notify = callback
			end,
		})

		assert(notify, "fixture: the provider is handed a callback")

		notify()
		notify()

		assert(refreshes == 0, "no refresh may run in the provider's stack, ran " .. refreshes)
		assert(#queue == 1, "and a burst queues one pass, got " .. #queue)

		queue[1]()

		assert(refreshes == 1, "which refreshes once it runs on our own frame, ran " .. refreshes)

		_G.C_Timer.After = realAfter
		addon.Refresh = nil
	end)
end)

-- The measurement reads UIParent's scale and the shared stub has no UIParent. Handed back at the
-- bottom of the file, since the later files in the run share these globals.
local realUIParent = _G.UIParent
local uiScale = 1

_G.UIParent = {
	GetEffectiveScale = function()
		return uiScale
	end,
}

---An anchor carrying what the measurement reads off a real frame: its size, and the scale its
---addon draws it at. The shared frame stub has neither.
---@param name string
---@param width number
---@param height number
---@param scale number
local function NewSizedAnchor(name, width, height, scale)
	_G[name] = {
		IsVisible = function()
			return true
		end,
		IsForbidden = function()
			return false
		end,
		GetName = function()
			return name
		end,
		GetWidth = function()
			return width
		end,
		GetHeight = function()
			return height
		end,
		GetEffectiveScale = function()
			return scale
		end,
	}
end

fw.describe("Frames:GetTestFrameSize", function()
	fw.before_each(function()
		for key in pairs(db) do
			db[key] = nil
		end

		uiScale = 1
	end)

	fw.it("copies a real party frame's size", function()
		NewSizedAnchor("TestSizedAnchor", 96, 40, 1)
		db.Anchor1 = "TestSizedAnchor"

		local width, height = frames:GetTestFrameSize()

		assert(width == 96, "the stand-in must be as wide as the frame, got " .. width)
		assert(height == 40, "and as tall, got " .. height)
	end)

	fw.it("converts a frame drawn at another scale into what it covers on screen", function()
		NewSizedAnchor("TestSizedAnchor", 96, 40, 0.5)
		db.Anchor1 = "TestSizedAnchor"

		local width, height = frames:GetTestFrameSize()

		assert(width == 48, "a half-scale frame covers half the width, got " .. width)
		assert(height == 20, "and half the height, got " .. height)
	end)

	fw.it("measures against UIParent rather than the raw scale", function()
		uiScale = 0.64
		NewSizedAnchor("TestSizedAnchor", 96, 40, 0.64)
		db.Anchor1 = "TestSizedAnchor"

		local width, height = frames:GetTestFrameSize()

		assert(width == 96, "a frame at UIParent's own scale is unchanged, got " .. width)
		assert(height == 40, "in both directions, got " .. height)
	end)

	fw.it("falls back to its own size when nothing real has been built", function()
		local width, height = frames:GetTestFrameSize()

		assert(width == 144, "the built-in width stands in, got " .. width)
		assert(height == 72, "and the built-in height, got " .. height)
	end)

	-- Copying Blizzard's leftovers would reproduce the very mismatch the stand-ins are meant to
	-- avoid.
	fw.it("passes over a hidden Blizzard frame for the frame addon's", function()
		NewSizedAnchor("CompactRaidFrameTestStub", 72, 36, 1)
		NewSizedAnchor("TestAddonFrameStub", 120, 50, 1)
		db.Anchor1 = "CompactRaidFrameTestStub"
		db.Anchor2 = "TestAddonFrameStub"

		local width, height = frames:GetTestFrameSize()

		assert(width == 120, "the frame addon's width wins, got " .. width)
		assert(height == 50, "and its height, got " .. height)
	end)

	fw.it("copies a Blizzard frame when that is all there is", function()
		NewSizedAnchor("CompactRaidFrameTestStub", 72, 36, 1)
		db.Anchor1 = "CompactRaidFrameTestStub"

		local width, height = frames:GetTestFrameSize()

		assert(width == 72, "the second pass takes it, got " .. width)
		assert(height == 36, "at its own height, got " .. height)
	end)
end)

---An arena enemy frame, which the measurement reaches by global name rather than through the
---anchor providers.
---@param visible boolean
---@param width number
---@param height number
---@param scale number
---@return table
local function NewArenaFrame(visible, width, height, scale)
	return {
		IsVisible = function()
			return visible
		end,
		GetWidth = function()
			return width
		end,
		GetHeight = function()
			return height
		end,
		GetEffectiveScale = function()
			return scale
		end,
	}
end

-- Outside an arena only addon-built frames carry a real size, and that is exactly when the
-- stand-ins are wanted.
fw.describe("Frames:GetTestArenaFrameSize", function()
	fw.before_each(function()
		for key in pairs(db) do
			db[key] = nil
		end

		uiScale = 1
		_G.sArenaEnemyFrame1 = nil
		_G.CompactArenaFrame = nil
	end)

	fw.it("copies an arena enemy frame that is on screen", function()
		_G.sArenaEnemyFrame1 = NewArenaFrame(true, 200, 60, 0.5)

		local width, height = frames:GetTestArenaFrameSize()

		assert(width == 100, "at what it covers on screen, got " .. width)
		assert(height == 30, "in both directions, got " .. height)
	end)

	fw.it("falls back to the party size outside an arena", function()
		NewSizedAnchor("TestArenaFallbackAnchor", 96, 40, 1)
		db.Anchor1 = "TestArenaFallbackAnchor"

		local width, height = frames:GetTestArenaFrameSize()

		assert(width == 96, "the party stand-in's width, got " .. width)
		assert(height == 40, "and its height, got " .. height)
	end)

	-- The stand-ins are only ever up while no arena frame is on screen, so a hidden one an addon
	-- holds at its real size is the only thing left worth copying.
	fw.it("copies a hidden arena frame an addon built", function()
		_G.sArenaEnemyFrame1 = NewArenaFrame(false, 200, 60, 0.5)
		NewSizedAnchor("TestArenaFallbackAnchor", 96, 40, 1)
		db.Anchor1 = "TestArenaFallbackAnchor"

		local width, height = frames:GetTestArenaFrameSize()

		assert(width == 100, "the addon's frame beats the party size, got " .. width)
		assert(height == 30, "converted for its scale, got " .. height)
	end)

	-- On the default UI in an arena, Blizzard's frames are the real ones and the party column
	-- going up can still ask for this size.
	fw.it("copies a Blizzard arena frame that is on screen", function()
		_G.CompactArenaFrame = { memberUnitFrames = { NewArenaFrame(true, 200, 60, 0.5) } }
		NewSizedAnchor("TestArenaFallbackAnchor", 96, 40, 1)
		db.Anchor1 = "TestArenaFallbackAnchor"

		local width, height = frames:GetTestArenaFrameSize()

		assert(width == 100, "the visible frame beats the party size, got " .. width)
		assert(height == 30, "converted for its scale, got " .. height)
	end)

	-- Blizzard's are built at login too, but sit at their template size until an arena loads.
	fw.it("ignores a hidden Blizzard arena frame", function()
		_G.CompactArenaFrame = { memberUnitFrames = { NewArenaFrame(false, 200, 60, 1) } }
		NewSizedAnchor("TestArenaFallbackAnchor", 96, 40, 1)
		db.Anchor1 = "TestArenaFallbackAnchor"

		local width, height = frames:GetTestArenaFrameSize()

		assert(width == 96, "the party size stands in instead, got " .. width)
		assert(height == 40, "in both directions, got " .. height)
	end)
end)

_G.UIParent = realUIParent
-- The last arena test leaves its stub behind, and a later file loading ArenaFrames would find it.
_G.sArenaEnemyFrame1 = nil
_G.CompactArenaFrame = nil
