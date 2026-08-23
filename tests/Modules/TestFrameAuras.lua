-- The Frame Auras module: the buff whitelist it filters on, and the one thing it does to the
-- client outside its own frames - switching Blizzard's raid frame aura rows off while it draws
-- its own. That cvar is only ever written on an edge, so a player who turned Blizzard's rows off
-- themselves does not get them handed back by a module they never switched on.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db

-- Written by SetCVar so a test can see what reached the client, and when nothing did. The store
-- behind it is real, so a value the module puts back can be read for what it actually is.
local cvarWrites = {}
local cvars = { raidFramesDisplayBuffs = "1", raidFramesDisplayDebuffs = "1" }

_G.SetCVar = function(name, value)
	cvars[name] = value
	cvarWrites[#cvarWrites + 1] = { Name = name, Value = value }
end

_G.GetCVar = function(name)
	return cvars[name]
end

-- One of Blizzard's party member frames, which the rows collect through Core/Frames. The lookup
-- reads the globals by name and the mock's CreateFrame does not publish one, so it is set by hand.
local partyContainer = _G.CreateFrame("Frame", "CompactPartyFrame", _G.UIParent)
local memberFrame = _G.CreateFrame("Frame", "CompactPartyFrameMember1", partyContainer)
memberFrame.healthBar = _G.CreateFrame("Frame", nil, memberFrame)
memberFrame.unit = "party1"
memberFrame.GetAttribute = function(_, key)
	return key == "unit" and memberFrame.unit or nil
end

_G.CompactPartyFrame = partyContainer
_G.CompactPartyFrameMember1 = memberFrame

env.loadModule("src/Core/Display/Pixels.lua")
env.loadModule("src/Core/Auras/TrackedBuffs.lua")
env.loadModule("src/Core/Auras/ClassBuffs.lua")
env.loadModule("src/Modules/FrameAuras/Spells.lua")
env.loadModule("src/Modules/FrameAuras/GroupAuras.lua")
env.loadModule("src/Modules/FrameAuras/ClassBuff.lua")
env.loadModule("src/Modules/FrameAuras/TargetAuras.lua")
env.loadModule("src/Modules/FrameAuras/Module.lua")

local spells = env.addon.Modules.FrameAuras.Spells
local groupAuras = env.addon.Modules.FrameAuras.GroupAuras
local module = env.addon.Modules.FrameAurasModule
local testSpells = env.addon.Core.TestSpells
local trackedBuffs = env.addon.Core.TrackedBuffs
local options = db.Modules.FrameAurasModule

---The lowest curated buff id, picked by value so the assertions survive a change to the list.
---@return number
local function CuratedId()
	local lowest

	for spellId in pairs(trackedBuffs.ById) do
		if not lowest or spellId < lowest then
			lowest = spellId
		end
	end

	return assert(lowest, "the tracked buff list ships no spells")
end

local CURATED = CuratedId()
-- An id the curated list will never hold, for the hand-added cases.
local CUSTOM = 99000001

local function ResetSpells()
	options.Spells.Disabled = {}
	options.Spells.Custom = {}
end

local function ResetCVars()
	for index = #cvarWrites, 1, -1 do
		cvarWrites[index] = nil
	end
end

---@param name string
---@return string? value The last value written for this cvar, or nil if it was never written.
local function LastWrite(name)
	local found

	for _, write in ipairs(cvarWrites) do
		if write.Name == name then
			found = write.Value
		end
	end

	return found
end

fw.describe("Frame Auras - the tracked buff list", function()
	fw.it("tracks every curated spell out of the box", function()
		ResetSpells()

		assert(spells:IsCurated(CURATED), "the sample id should be curated")
		assert(spells:IsTracked(CURATED), "a curated spell starts tracked")
		assert(not spells:IsTracked(CUSTOM), "an id nobody added is not tracked")
	end)

	fw.it("switches a curated spell off without forgetting it", function()
		ResetSpells()
		spells:SetTracked(CURATED, false)

		assert(not spells:IsTracked(CURATED), "the spell is off")
		assert(options.Spells.Disabled[CURATED], "and the override says so")
		assert(options.Spells.Custom[CURATED] == nil, "a curated id never lands in Custom")
	end)

	fw.it("switching a curated spell back on clears the override rather than adding one", function()
		ResetSpells()
		spells:SetTracked(CURATED, false)
		spells:SetTracked(CURATED, true)

		assert(spells:IsTracked(CURATED), "the spell is back")
		assert(options.Spells.Disabled[CURATED] == nil, "and nothing is left saying otherwise")
		assert(options.Spells.Custom[CURATED] == nil, "a curated id never lands in Custom")
	end)

	fw.it("adds and forgets a hand-added spell", function()
		ResetSpells()
		spells:SetTracked(CUSTOM, true)

		assert(spells:IsTracked(CUSTOM), "the added spell is tracked")
		assert(options.Spells.Custom[CUSTOM], "and it is stored as a custom id")

		spells:Forget(CUSTOM)

		assert(not spells:IsTracked(CUSTOM), "forgetting drops it")
		assert(options.Spells.Custom[CUSTOM] == nil, "leaving nothing behind")
	end)

	fw.it("lists a hand-added spell in its own section", function()
		ResetSpells()
		spells:SetTracked(CUSTOM, true)

		local custom

		for _, group in ipairs(spells:SpellGroups()) do
			if group.Key == spells.CustomGroupKey then
				custom = group
			end
		end

		assert(custom, "there is always a custom section, even when empty")
		assert(custom.Ids[1] == CUSTOM, "and the added id is in it")
	end)

	fw.it("never hands the engine an empty spell-id map", function()
		ResetSpells()

		-- An empty map reads to the engine as "no ids required", which would match every buff on
		-- the unit rather than none of them, so both sets always carry something.
		for spellId in pairs(trackedBuffs.ById) do
			options.Spells.Disabled[spellId] = true
		end

		local pandemic, plain = spells:BuildSpellSets()

		assert(next(pandemic) ~= nil, "the glow set is never empty")
		assert(next(plain) ~= nil, "and neither is the plain one")

		ResetSpells()
	end)

	fw.it("puts a refresh-window spell in the glow set only while the glow is on", function()
		ResetSpells()

		local glowing = next(trackedBuffs.Pandemic)

		if not glowing then
			return
		end

		options.Buffs.PandemicGlow = true

		local pandemic = spells:BuildSpellSets()
		assert(pandemic[glowing], "the spell is in the glow set")

		options.Buffs.PandemicGlow = false

		local off, plain = spells:BuildSpellSets()
		assert(not off[glowing], "with the glow off it is not")
		assert(plain[glowing], "it draws through the plain group instead")

		options.Buffs.PandemicGlow = true
	end)
end)

fw.describe("Frame Auras - Blizzard's own aura rows", function()
	fw.it("leaves the cvars alone for a side that was already off at login", function()
		ResetCVars()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false

		groupAuras:Refresh()

		assert(#cvarWrites == 0, "an off side has never touched the setting, so it hands nothing back")
		assert(#env.containersForUnit("party1") == 0, "and nothing is built for a side nobody asked for")
	end)

	fw.it("switches Blizzard's row off when a side is enabled", function()
		ResetCVars()
		options.Buffs.Enabled = true

		groupAuras:Refresh()

		assert(LastWrite("raidFramesDisplayBuffs") == "0", "the buff row is switched off")
		assert(LastWrite("raidFramesDisplayDebuffs") == nil, "and the debuff row is left alone")
		-- The frames are reached through the compact-frame walk, so this is also what proves the
		-- walk found the party frame at all.
		assert(#env.containersForUnit("party1") == 1, "and the row itself reached the party frame")
	end)

	fw.it("writes nothing on a refresh that changed nothing", function()
		options.Buffs.Enabled = true
		groupAuras:Refresh()

		ResetCVars()
		groupAuras:Refresh()

		assert(#cvarWrites == 0, "a level-triggered refresh is not an edge")
	end)

	fw.it("hands Blizzard's row back when a side is switched off", function()
		options.Buffs.Enabled = true
		groupAuras:Refresh()

		ResetCVars()
		options.Buffs.Enabled = false
		groupAuras:Refresh()

		assert(LastWrite("raidFramesDisplayBuffs") == "1", "the row goes back to the client's default")
	end)

	fw.it("puts back the value the player had, not the one the client ships", function()
		options.Buffs.Enabled = false
		groupAuras:Refresh()

		-- A player who had already turned Blizzard's buffs off themselves.
		cvars.raidFramesDisplayBuffs = "0"

		options.Buffs.Enabled = true
		groupAuras:Refresh()

		options.Buffs.Enabled = false
		groupAuras:Refresh()

		assert(cvars.raidFramesDisplayBuffs == "0", "the row stays off, because that is how they left it")

		cvars.raidFramesDisplayBuffs = "1"
	end)

	fw.it("tracks the two sides separately", function()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		groupAuras:Refresh()

		ResetCVars()
		options.Debuffs.Enabled = true
		groupAuras:Refresh()

		assert(LastWrite("raidFramesDisplayDebuffs") == "0", "the debuff row is switched off")
		assert(LastWrite("raidFramesDisplayBuffs") == nil, "the buff side is untouched by it")

		options.Debuffs.Enabled = false
		groupAuras:Refresh()
	end)
end)

-- The preview draws through TestSpells:FillContainer, so recording the calls says which sides
-- reached the screen and which container each row landed in.
local fills = {}
local originalFill = testSpells.FillContainer

testSpells.FillContainer = function(self, container, previewSpells, startSlot, fillOptions)
	fills[#fills + 1] = { Container = container, Spells = previewSpells, Frame = container.Frame }

	return originalFill(self, container, previewSpells, startSlot, fillOptions)
end

local function ResetFills()
	for index = #fills, 1, -1 do
		fills[index] = nil
	end
end

---The preview row drawn on a given frame, or nil when nothing was drawn there.
---@param frame table
---@return IconSlotContainer?
local function RowOn(frame)
	for _, fill in ipairs(fills) do
		if fill.Frame:GetParent() == frame then
			return fill.Container
		end
	end

	return nil
end

fw.describe("Frame Auras - test mode", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		ResetFills()
	end)

	fw.it("draws a preview row on the party frame for a side that is on", function()
		options.Buffs.Enabled = true

		module:StartTesting()

		local row = RowOn(memberFrame)

		assert(row, "the party frame got a preview row")
		assert(row:GetUsedSlotCount() > 0, "with icons in it")
		assert(row.Frame:IsShown(), "and it is on screen")
	end)

	fw.it("clears the preview when test mode stops", function()
		options.Buffs.Enabled = true

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")

		module:StopTesting()

		assert(row:GetUsedSlotCount() == 0, "the fake icons are gone")
		assert(not row.Frame:IsShown(), "and so is the row itself")
	end)

	fw.it("previews nothing for a side that is switched off", function()
		options.Debuffs.Enabled = true

		module:StartTesting()

		assert(#fills > 0, "the enabled side previews something")

		for _, fill in ipairs(fills) do
			assert(fill.Spells == testSpells.FrameAuras.Debuffs, "only the debuff side draws")
		end
	end)

	fw.it("previews nothing at all while both sides are off", function()
		module:StartTesting()

		assert(#fills == 0, "a page nobody switched on shows an empty frame, as it does in play")
	end)

	fw.it("leaves nothing behind on the spare frames a raid never fills", function()
		options.Buffs.Enabled = true

		-- One of Blizzard's forty raid frames with nobody on it, which is what the client leaves
		-- sitting hidden for most of a session.
		local spare = _G.CreateFrame("Frame", "CompactRaidFrame1", _G.UIParent)
		spare.healthBar = _G.CreateFrame("Frame", nil, spare)
		spare.GetAttribute = function() end
		spare:Hide()
		_G.CompactRaidFrame1 = spare

		module:StartTesting()
		module:StopTesting()
		groupAuras:Refresh()

		-- A preview that let every empty frame through would leave an entry for each, and every
		-- refresh after it would build that entry a display and its batch of buttons.
		assert(not RowOn(spare), "the empty frame never got a preview row")
		assert(#env.containersForUnit("none") == 0, "nor a live display once the preview ended")

		_G.CompactRaidFrame1 = nil
	end)

	fw.it("reaches the stand-in frames a solo player sees", function()
		options.Buffs.Enabled = true

		module:StartTesting()

		local drawn = 0

		for _, standIn in ipairs(env.testFrames) do
			if RowOn(standIn) then
				drawn = drawn + 1
			end
		end

		assert(drawn == #env.testFrames, "every stand-in got a row, whether or not its unit exists")

		local standIn = assert(RowOn(env.testFrames[1]))

		module:StopTesting()

		-- The stand-ins leave the frame list with test mode, so the refresh that follows never
		-- walks them: whatever cleared this row did it without being handed the frame.
		assert(standIn:GetUsedSlotCount() == 0, "the stand-in row is cleared too")
	end)
end)
