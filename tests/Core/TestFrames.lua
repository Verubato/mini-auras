-- Frames:GetAll's reuse contract. Every module now hands it a long-lived scratch table instead of
-- taking a fresh one, so the two properties that keeps them correct - the table handed back IS the
-- one passed in, and it is wiped rather than appended to - have to hold. A caller that held the
-- result across two calls, or a provider that stopped wiping, would otherwise pass the whole suite.

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
loadFile("src/Core/Frames/Frames.lua")
loadFile("src/Core/Frames/ArenaFrames.lua")
loadFile("src/Core/Frames/TestFrames.lua")
loadFile("src/Core/Frames/ExternalProviders.lua")
for _, provider in ipairs({
	"Blizzard", "DandersFrames", "ElvUI", "Grid2", "ShadowedUF", "Plexus", "VuhDo", "Cell",
	"TPerl", "EnhancedQoL", "Buzzard", "NDui", "GW2UI", "MSUF",
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
