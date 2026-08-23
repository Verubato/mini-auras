-- The Frame Auras module: the buff whitelist it filters on, and the one thing it does to the
-- client outside its own frames - switching Blizzard's raid frame aura rows off while it draws
-- its own. That cvar is only ever written on an edge, so a player who turned Blizzard's rows off
-- themselves does not get them handed back by a module they never switched on.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
-- The sweep only moves on a frame of its own, so the prewarm tests have to pump it by hand.
local acm = require("AuraContainerMock")
-- For marking a value secret, which is how the client answers about units mid-loading-screen.
local wow = require("WowApi")

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

-- The client's own "can I dispel this" classification, which the debuff row asks for by value. The
-- mock does not model AuraUtil, and the number itself is opaque to everything but the engine.
local DISPEL_TYPE = 2

_G.AuraUtil = { AuraUpdateChangedType = { Dispel = DISPEL_TYPE } }

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

-- What the client has its own container set to, and what it has to be left holding again.
local BLIZZARD_MAX_BUFFS = 4
local BLIZZARD_MAX_DEBUFFS = 3

-- Blizzard's own aura container on the target frame. The counts and the unit are modelled although
-- the module has no business writing them, because a test that only watched the switch it is
-- allowed to throw would not notice it throwing the others.
local blizzardAuras = {}

function blizzardAuras:Reset()
	self._enabled = true
	self._shown = true
	self._maxBuffs = BLIZZARD_MAX_BUFFS
	self._maxDebuffs = BLIZZARD_MAX_DEBUFFS
	self._unit = "target"
end

function blizzardAuras:SetEnabled(enabled)
	self._enabled = enabled
end

function blizzardAuras:SetMaxBuffs(count)
	self._maxBuffs = count
end

function blizzardAuras:SetMaxDebuffs(count)
	self._maxDebuffs = count
end

function blizzardAuras:SetUnit(unit)
	self._unit = unit
end

function blizzardAuras:IsEnabled()
	return self._enabled
end

function blizzardAuras:SetShown(shown)
	self._shown = shown
end

function blizzardAuras:Show()
	self._shown = true
end

function blizzardAuras:Hide()
	self._shown = false
end

function blizzardAuras:IsShown()
	return self._shown
end

blizzardAuras:Reset()

-- Where the client itself hangs the cast bar, which the rows take over and have to give back.
local CASTBAR_HOME = { Point = "TOP", RelativePoint = "BOTTOM", X = 0, Y = -5 }

-- The target frame, carrying the two things the rows take over: the client's aura container and its
-- cast bar. Set up by hand for the same reason the party frame above is.
local targetFrame = _G.CreateFrame("Frame", "TargetFrame", _G.UIParent)

targetFrame.GetAuraContainer = function()
	return blizzardAuras
end

targetFrame.ConfigureAuraContainer = function() end
targetFrame.spellbar = _G.CreateFrame("Frame", nil, targetFrame)
targetFrame.spellbar:SetPoint(CASTBAR_HOME.Point, targetFrame, CASTBAR_HOME.RelativePoint,
	CASTBAR_HOME.X, CASTBAR_HOME.Y)

_G.TargetFrame = targetFrame

env.loadModule("src/Core/Display/Pixels.lua")
env.loadModule("src/Core/Auras/TrackedBuffs.lua")
env.loadModule("src/Core/Auras/ClassBuffs.lua")
env.loadModule("src/Modules/FrameAuras/Spells.lua")
env.loadModule("src/Modules/FrameAuras/PartyAuras.lua")
env.loadModule("src/Modules/FrameAuras/ClassBuff.lua")
env.loadModule("src/Modules/FrameAuras/TargetAuras.lua")
env.loadModule("src/Modules/FrameAuras/Module.lua")

local spells = env.addon.Modules.FrameAuras.Spells
local partyAuras = env.addon.Modules.FrameAuras.PartyAuras
local targetAuras = env.addon.Modules.FrameAuras.TargetAuras
-- Read before any describe switches it on, so the shipped answer is what gets asserted.
local TARGET_ROWS_SHIPPED = targetAuras.Available
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
-- The one aura group the debuff row draws through.
local DEBUFF_GROUP = "FrameDebuffs"

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

		partyAuras:Refresh()

		assert(#cvarWrites == 0, "an off side has never touched the setting, so it hands nothing back")
		assert(#env.containersForUnit("party1") == 0, "and nothing is built for a side nobody asked for")
	end)

	fw.it("switches Blizzard's row off when a side is enabled", function()
		ResetCVars()
		options.Buffs.Enabled = true

		partyAuras:Refresh()

		assert(LastWrite("raidFramesDisplayBuffs") == "0", "the buff row is switched off")
		assert(LastWrite("raidFramesDisplayDebuffs") == nil, "and the debuff row is left alone")
		-- The frames are reached through the compact-frame walk, so this is also what proves the
		-- walk found the party frame at all.
		assert(#env.containersForUnit("party1") == 1, "and the row itself reached the party frame")
	end)

	fw.it("writes nothing on a refresh that changed nothing", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		ResetCVars()
		partyAuras:Refresh()

		assert(#cvarWrites == 0, "a level-triggered refresh is not an edge")
	end)

	fw.it("hands Blizzard's row back when a side is switched off", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		ResetCVars()
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(LastWrite("raidFramesDisplayBuffs") == "1", "the row goes back to the client's default")
	end)

	fw.it("puts back the value the player had, not the one the client ships", function()
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		-- A player who had already turned Blizzard's buffs off themselves.
		cvars.raidFramesDisplayBuffs = "0"

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(cvars.raidFramesDisplayBuffs == "0", "the row stays off, because that is how they left it")

		cvars.raidFramesDisplayBuffs = "1"
	end)

	fw.it("tracks the two sides separately", function()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		partyAuras:Refresh()

		ResetCVars()
		options.Debuffs.Enabled = true
		partyAuras:Refresh()

		assert(LastWrite("raidFramesDisplayDebuffs") == "0", "the debuff row is switched off")
		assert(LastWrite("raidFramesDisplayBuffs") == nil, "the buff side is untouched by it")

		options.Debuffs.Enabled = false
		partyAuras:Refresh()
	end)
end)

-- The preview draws through TestSpells:FillContainer, so recording the calls says which sides
-- reached the screen and which container each row landed in.
local fills = {}
local originalFill = testSpells.FillContainer

testSpells.FillContainer = function(self, container, previewSpells, startSlot, fillOptions)
	-- Copied, not kept: the module builds each preview list in a scratch table it refills per
	-- call, so holding the reference would leave every capture showing the last row drawn.
	local captured = {}

	for index, spellId in ipairs(previewSpells) do
		captured[index] = spellId
	end

	fills[#fills + 1] = { Container = container, Spells = captured, Frame = container.Frame }

	return originalFill(self, container, previewSpells, startSlot, fillOptions)
end

---A Blizzard party member frame the client has just put up, for a test that needs a frame with
---nothing built on it yet: a display is created once per frame and kept for the session.
---@param index number
---@return table
local function NewPartyFrame(index)
	local name = "CompactPartyFrameMember" .. index
	local frame = _G.CreateFrame("Frame", name, _G.UIParent)

	frame.healthBar = _G.CreateFrame("Frame", nil, frame)
	frame.unit = "party" .. index
	frame.GetAttribute = function(_, key)
		return key == "unit" and frame.unit or nil
	end

	_G[name] = frame

	return frame
end

---@param index number
local function DropPartyFrame(index)
	_G["CompactPartyFrameMember" .. index] = nil
end

---The same for one of Blizzard's forty raid frames. The party frames only run to five, so a test
---needing its own frame past that takes a raid one.
---@param index number
---@return table
local function NewRaidFrame(index)
	local name = "CompactRaidFrame" .. index
	local frame = _G.CreateFrame("Frame", name, _G.UIParent)

	frame.healthBar = _G.CreateFrame("Frame", nil, frame)
	frame.unit = "raid" .. index
	frame.GetAttribute = function(_, key)
		return key == "unit" and frame.unit or nil
	end

	_G[name] = frame

	return frame
end

---@param index number
local function DropRaidFrame(index)
	_G["CompactRaidFrame" .. index] = nil
end

---How many aura containers are parented to a frame. Asked of the frame rather than of the unit,
---because a spare warmed up ahead of a group sits on "none" until one takes it.
---@param frame table
---@return number
local function ContainersOn(frame)
	local count = 0

	for _, candidate in ipairs(acm.frames) do
		if candidate._type == "AuraContainer" and candidate:GetParent() == frame then
			count = count + 1
		end
	end

	return count
end

---Whether a captured preview list holds a spell id.
---@param list number[]
---@param spellId number
---@return boolean
local function Includes(list, spellId)
	for _, id in ipairs(list) do
		if id == spellId then
			return true
		end
	end

	return false
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

fw.describe("Frame Auras - what one frame costs", function()
	fw.before_each(function()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		partyAuras:Refresh()
	end)

	---Every aura group on the containers parented to a frame, and the buttons they were declared
	---with. The engine hands out a group's buttons from that count, so it is what a frame costs.
	---@param frame table
	---@return number groups, number buttons
	local function CostOf(frame)
		local groups, buttons = 0, 0

		for _, candidate in ipairs(acm.frames) do
			if candidate._type == "AuraContainer" and candidate:GetParent() == frame then
				for _, group in pairs(candidate._groups) do
					groups = groups + 1
					buttons = buttons + (group.maxFrameCountAtCreation or 0)
				end
			end
		end

		return groups, buttons
	end

	fw.it("declares one group per row, and one batch of buttons per group", function()
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = true

		local fresh = NewPartyFrame(3)

		partyAuras:Refresh()
		acm.tickAll(400)

		local groups, buttons = CostOf(fresh)
		local expected = options.Buffs.MaxIcons + options.Debuffs.MaxIcons + 1

		-- Buffs are two groups only while the refresh-window reveal is on: the plain row plus one
		-- button for the single spell that carries it. Debuffs are one group, ranked by the game's
		-- own debuff sort rather than partitioned into two.
		assert(groups == 3, "three groups on a frame, not four, got " .. groups)
		assert(buttons == expected,
			"the row budgets are what a frame costs, expected " .. expected .. " got " .. buttons)

		DropPartyFrame(3)
	end)

	fw.it("drops the glow group entirely when the reveal is off", function()
		options.Buffs.Enabled = true
		options.Buffs.PandemicGlow = false

		-- Its own frame: a display is built once and kept, so a frame that already has one was
		-- built under whatever the settings were then.
		local fresh = NewPartyFrame(4)

		partyAuras:Refresh()
		acm.tickAll(400)

		local groups, buttons = CostOf(fresh)

		assert(groups == 1, "one group for the buff row, got " .. groups)
		assert(buttons == options.Buffs.MaxIcons,
			"and no batch of buttons for a reveal nothing can trigger, got " .. buttons)

		options.Buffs.PandemicGlow = true
		DropPartyFrame(4)
	end)
end)

fw.describe("Frame Auras - warming up ahead of a group", function()
	fw.before_each(function()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		partyAuras:Refresh()
	end)

	fw.it("builds spare rows for the frames a group has yet to fill", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()
		acm.tickAll(400)

		local warmed = env.auraContainerCount()

		-- Five frames' worth are wanted in total, and only one frame is on screen, so the walker
		-- has more to build than the frames alone would ever ask for.
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(warmed >= 5, "five frames' worth were made ready, got " .. warmed)
	end)

	fw.it("hands a waiting spare to the next frame rather than building another", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()
		acm.tickAll(400)

		local warmed = env.auraContainerCount()

		-- A second frame turns up, as one does when somebody joins.
		local joined = _G.CreateFrame("Frame", "CompactPartyFrameMember2", _G.UIParent)
		joined.healthBar = _G.CreateFrame("Frame", nil, joined)
		joined.unit = "party2"
		joined.GetAttribute = function(_, key)
			return key == "unit" and joined.unit or nil
		end
		_G.CompactPartyFrameMember2 = joined

		partyAuras:Refresh()

		assert(env.auraContainerCount() == warmed,
			"the frame took a row that already existed instead of paying to build one")

		_G.CompactPartyFrameMember2 = nil
		options.Buffs.Enabled = false
		partyAuras:Refresh()
	end)

	fw.it("builds no spares for a side nobody switched on", function()
		local before = env.auraContainerCount()

		partyAuras:Refresh()
		acm.tickAll(400)

		assert(env.auraContainerCount() == before, "an off module warms nothing up")
	end)
end)

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
			assert(Includes(fill.Spells, testSpells.FrameAuras.Debuffs[1]), "only the debuff side draws")
		end
	end)

	fw.it("builds nothing while a loading screen is up", function()
		options.Buffs.Enabled = true

		local frame = NewRaidFrame(20)

		-- Blizzard shows all forty raid frames and five party frames pointed at "player" while it
		-- lays them out at login, so during that window every one of them looks like a frame worth
		-- building for. Nothing about the frame can tell them apart; only the timing can.
		env.loadingScreenUp = true

		partyAuras:Refresh()

		assert(ContainersOn(frame) == 0, "the layout pass builds nothing")

		env.loadingScreenUp = false
		partyAuras:Refresh()

		assert(ContainersOn(frame) > 0, "and the pass after the screen builds what is really there")

		DropRaidFrame(20)
		options.Buffs.Enabled = false
		partyAuras:Refresh()
	end)

	fw.it("waits for a definite answer before building a frame's rows", function()
		options.Buffs.Enabled = true

		local frame = NewPartyFrame(5)
		local realExists = _G.UnitExists

		-- What a loading screen looks like: the client answers about units SECRETLY. Not falsely -
		-- a secret answer reads as "maybe", and the show path deliberately treats it as occupied.
		-- Building is a batch of buttons the engine can never free, so it has to mean "not yet".
		local secret = wow.markSecret({})

		_G.UnitExists = function()
			return secret
		end

		partyAuras:Refresh()

		assert(ContainersOn(frame) == 0, "nothing is built while the client will not answer")

		_G.UnitExists = realExists
		partyAuras:Refresh()

		assert(ContainersOn(frame) > 0, "and the pass after it builds what was skipped")

		DropPartyFrame(5)
		options.Buffs.Enabled = false
		partyAuras:Refresh()
	end)

	fw.it("builds nothing for a frame the client is not showing", function()
		options.Buffs.Enabled = true

		-- A compact frame still carrying the unit it last held, which is what a spare raid frame
		-- looks like after the group it belonged to broke up.
		local hidden = _G.CreateFrame("Frame", "CompactRaidFrame2", _G.UIParent)
		hidden.healthBar = _G.CreateFrame("Frame", nil, hidden)
		hidden.unit = "party1"
		hidden.GetAttribute = function(_, key)
			return key == "unit" and hidden.unit or nil
		end
		hidden:Hide()
		_G.CompactRaidFrame2 = hidden

		partyAuras:Refresh()

		assert(ContainersOn(hidden) == 0,
			"a hidden frame costs no display, however occupied its token says it is")

		-- Put it on screen and it gets one, so the gate defers the work rather than losing it.
		hidden:Show()
		partyAuras:Refresh()

		assert(ContainersOn(hidden) > 0, "showing the frame is what builds its rows")

		options.Buffs.Enabled = false
		_G.CompactRaidFrame2 = nil
	end)

	fw.it("puts a stun in the debuff preview only while crowd control is let in", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCC = false

		module:StartTesting()

		local stun = testSpells.FrameAuras.CrowdControl

		assert(#fills > 0, "the debuff row previews something")
		assert(not Includes(fills[1].Spells, stun), "with crowd control kept out, no stun is shown")

		module:StopTesting()
		ResetFills()
		options.Debuffs.ShowCC = true
		module:StartTesting()

		assert(Includes(fills[1].Spells, stun), "letting it in puts one in the row")
		assert(fills[1].Spells[1] == stun, "and it leads, the way a flagged category does in play")

		options.Debuffs.ShowCC = false
	end)

	fw.it("puts a defensive in the buff preview only while defensives are let in", function()
		options.Buffs.Enabled = true
		options.Buffs.ShowDefensives = false

		module:StartTesting()

		local defensive = testSpells.FrameAuras.Defensive

		assert(#fills > 0, "the buff row previews something")
		assert(not Includes(fills[1].Spells, defensive), "with defensives kept out, none is shown")

		module:StopTesting()
		ResetFills()
		options.Buffs.ShowDefensives = true
		module:StartTesting()

		assert(Includes(fills[1].Spells, defensive), "letting them in puts one in the row")

		options.Buffs.ShowDefensives = false
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
		partyAuras:Refresh()

		-- A preview that let every empty frame through would leave an entry for each, and every
		-- refresh after it would build that entry a display and its batch of buttons.
		assert(not RowOn(spare), "the empty frame never got a preview row")
		assert(ContainersOn(spare) == 0, "nor a live display once the preview ended")

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

---The debuff group on the container built for a frame, so a test can read what the module handed
---the engine. Nil when the frame has no debuff row at all, which a nil filter set does not mean.
---@param frame table
---@return table?
local function DebuffGroup(frame)
	for _, candidate in ipairs(acm.frames) do
		if candidate._type == "AuraContainer" and candidate:GetParent() == frame then
			local group = candidate._groups[DEBUFF_GROUP]

			if group then
				return group
			end
		end
	end

	return nil
end

---The game's own debuff sort ranks the row and the budget trims it, so partitioning it by the boss
---and priority flags would only ever take icons away. Checked wherever a filter set exists at all,
---since a switch is what gives the partition somewhere to come back.
---@param filters table
local function AssertUnpartitioned(filters)
	assert(filters.isBossOrRoleAura == nil, "no boss partition reaches the engine")
	assert(filters.isPriorityAura == nil, "and no priority one either")
end

fw.describe("Frame Auras - what the debuff row lets through", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.Debuffs.ShortOnly = false
		options.Debuffs.Dispellable = false
		partyAuras:Refresh()
	end)

	fw.it("narrows the row by nothing at all under stock settings", function()
		options.Debuffs.Enabled = true

		-- Its own frame, like the cost tests: a display is built once per frame and kept, so one that
		-- already exists was built under whatever the settings were then.
		local fresh = NewRaidFrame(21)

		partyAuras:Refresh()
		acm.tickAll(400)

		local group = assert(DebuffGroup(fresh), "the frame got a debuff row")

		assert(group.candidateFilters == nil, "with neither switch on there is nothing left to narrow by")

		DropRaidFrame(21)
	end)

	fw.it("asks for a duration bound when the player wants the short ones only", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShortOnly = true

		local fresh = NewRaidFrame(22)

		partyAuras:Refresh()
		acm.tickAll(400)

		local group = assert(DebuffGroup(fresh), "the frame got a debuff row")
		local filters = assert(group.candidateFilters, "the switch put a filter set on the group")

		assert(filters.maxDuration == 60,
			"under a minute is a bound on the whole duration, got " .. tostring(filters.maxDuration))
		AssertUnpartitioned(filters)

		options.Debuffs.ShortOnly = false
		DropRaidFrame(22)
	end)

	fw.it("asks for the dispel classification when the player wants only what they can take off", function()
		options.Debuffs.Enabled = true
		options.Debuffs.Dispellable = true

		local fresh = NewRaidFrame(23)

		partyAuras:Refresh()
		acm.tickAll(400)

		local group = assert(DebuffGroup(fresh), "the frame got a debuff row")
		local filters = assert(group.candidateFilters, "the switch put a filter set on the group")

		assert(filters.processedAuraType == DISPEL_TYPE,
			"the engine's own dispel classification is what it filters on")
		AssertUnpartitioned(filters)

		options.Debuffs.Dispellable = false
		DropRaidFrame(23)
	end)
end)

---The two buff groups the target and focus rows draw through. The purgeable ones lead so they can
---carry the glow: which icons light up is decided by which group they land in, an aura's own dispel
---type being unreadable.
local BUFF_GROUP = "TargetBuffs"
local BUFF_PURGE_GROUP = "TargetBuffsPurge"
local TARGET_DEBUFF_GROUP = "TargetDebuffs"
local PURGE_FILTER = "HELPFUL|RAID_PLAYER_DISPELLABLE"
local PLAIN_BUFF_FILTER = "HELPFUL|!RAID_PLAYER_DISPELLABLE"

---The container carrying the buff groups on a target or focus frame.
---@param frame table
---@return table?
local function BuffContainer(frame)
	for _, candidate in ipairs(acm.frames) do
		if candidate._type == "AuraContainer" and candidate:GetParent() == frame
			and candidate._groups[BUFF_GROUP] then
			return candidate
		end
	end

	return nil
end

---The container carrying the debuff group on a target or focus frame.
---@param frame table
---@return table?
local function DebuffContainer(frame)
	for _, candidate in ipairs(acm.frames) do
		if candidate._type == "AuraContainer" and candidate:GetParent() == frame
			and candidate._groups[TARGET_DEBUFF_GROUP] then
			return candidate
		end
	end

	return nil
end

---The glow overlay on a group's first button, which is where the purge colour lands. Found by the
---texture field rather than by name: it is the only child frame the display builds one on.
---@param container table
---@param groupKey string
---@return table?
local function GlowOn(container, groupKey)
	local group = container._groups[groupKey]
	local button = group and group.buttons[1]

	if not button then
		return nil
	end

	for _, candidate in ipairs(acm.frames) do
		if candidate._parent == button and candidate.Texture then
			return candidate
		end
	end

	return nil
end

-- The target and focus rows are finished but held back until 12.1.5, when a container can carry
-- its own icon cap; the describes after this one switch them on to test what will ship then. This
-- one has to come first: a container is never destroyed, so once a later describe has built the
-- rows once, "nothing is built" could not be told from "something was built earlier".
fw.describe("Frame Auras - the target rows this build holds back", function()
	fw.before_each(function()
		module:StopTesting()
		targetAuras.Available = false
		options.TargetFocus.Enabled = true

		module:Refresh()
		acm.tickAll(400)
	end)

	fw.it("draws nothing, even for a profile that saved the switch on", function()
		assert(not BuffContainer(targetFrame), "no buff row is built")
		assert(not DebuffContainer(targetFrame), "and no debuff row either")
	end)

	fw.it("leaves the client's own container and cast bar alone", function()
		local point, relativeTo, relativePoint = targetFrame.spellbar:GetPoint(1)

		assert(blizzardAuras:IsEnabled() and blizzardAuras:IsShown(),
			"Blizzard keeps drawing the auras it always did")
		assert(relativeTo == targetFrame and point == CASTBAR_HOME.Point
			and relativePoint == CASTBAR_HOME.RelativePoint, "and the cast bar stays where it was")
	end)
end)

fw.describe("Frame Auras - the purge glow on the target row", function()
	fw.before_each(function()
		module:StopTesting()
		targetAuras.Available = true
		options.TargetFocus.Enabled = true
		options.TargetFocus.PurgeGlow = true

		module:Refresh()
		acm.tickAll(400)
	end)

	fw.it("splits the buff row so the purgeable ones can be told apart", function()
		local container = assert(BuffContainer(targetFrame), "the target frame got a buff row")
		local purge = assert(container._groups[BUFF_PURGE_GROUP], "and a group for the purgeable ones")

		assert(purge.filterString == PURGE_FILTER,
			"the purgeable group asks for what this player can remove, got " .. tostring(purge.filterString))
		assert(container._groups[BUFF_GROUP].filterString == PLAIN_BUFF_FILTER,
			"and the plain group gives them up, so no buff is drawn twice")
		assert(purge.maxFrameCount == options.TargetFocus.MaxIcons,
			"the purgeable group carries the row's own budget, got " .. tostring(purge.maxFrameCount))
	end)

	fw.it("lights the purgeable icons up in the chosen colour and leaves the rest plain", function()
		local container = assert(BuffContainer(targetFrame), "the target frame got a buff row")
		local lit = assert(GlowOn(container, BUFF_PURGE_GROUP), "the purgeable buttons carry a glow")
		local plain = assert(GlowOn(container, BUFF_GROUP), "so do the plain ones, hidden")

		assert(lit:IsShown(), "the purgeable group's glow is on")
		assert(not plain:IsShown(), "the rest of the row stays plain")

		local color = options.TargetFocus.PurgeColor
		local applied = assert(lit.Texture._lastArgs.SetVertexColor, "the glow took a colour")

		assert(applied[1] == color.R and applied[2] == color.G and applied[3] == color.B,
			"and it is the one the player picked")
	end)

	fw.it("hands the purgeable buffs back to the plain group when the glow is switched off", function()
		options.TargetFocus.PurgeGlow = false
		module:Refresh()

		local container = assert(BuffContainer(targetFrame), "the target frame still has its buff row")

		assert(container._groups[BUFF_PURGE_GROUP].maxFrameCount == 0,
			"the purgeable group is closed rather than left drawing uncoloured icons")
		assert(container._groups[BUFF_GROUP].filterString == "HELPFUL",
			"and the plain group takes them back, so the row loses no icon")
		assert(not GlowOn(container, BUFF_PURGE_GROUP):IsShown(), "nothing is lit up")
	end)

	fw.it("opens the purgeable group again when the glow comes back", function()
		options.TargetFocus.PurgeGlow = false
		module:Refresh()
		options.TargetFocus.PurgeGlow = true
		module:Refresh()

		local container = assert(BuffContainer(targetFrame), "the target frame still has its buff row")
		local purge = container._groups[BUFF_PURGE_GROUP]

		-- The engine hands a group its buttons from the count it was DECLARED with, so a group
		-- born closed could never open. This is what says it was born open.
		assert(purge.maxFrameCountAtCreation == options.TargetFocus.MaxIcons,
			"it was declared with the full budget, got " .. tostring(purge.maxFrameCountAtCreation))
		assert(purge.maxFrameCount == options.TargetFocus.MaxIcons, "and got it back")
		assert(GlowOn(container, BUFF_PURGE_GROUP):IsShown(), "with the glow on it again")
	end)

	fw.it("moves both buff groups onto the unit the frame now holds", function()
		local container = assert(BuffContainer(targetFrame), "the target frame got a buff row")

		options.TargetFocus.ShortBuffsOnly = true
		module:Refresh()

		local purge = container._groups[BUFF_PURGE_GROUP].candidateFilters
		local plain = container._groups[BUFF_GROUP].candidateFilters

		assert(purge and purge.maxDuration, "the purgeable group is filtered like the rest of the row")
		assert(plain and plain.maxDuration, "and so is the plain one")

		options.TargetFocus.ShortBuffsOnly = false
	end)
end)

fw.describe("Frame Auras - how the target rows stack", function()
	fw.before_each(function()
		module:StopTesting()
		targetAuras.Available = true
		options.TargetFocus.Enabled = true

		module:Refresh()
		acm.tickAll(400)
	end)

	fw.it("puts the buffs above the debuffs", function()
		local buffs = assert(BuffContainer(targetFrame), "the target frame got a buff row")
		local debuffs = assert(DebuffContainer(targetFrame), "and a debuff row")
		local _, relativeTo = debuffs:GetPoint(1)

		assert(relativeTo == buffs, "the debuff row hangs off the buff row, not the other way round")
	end)

	fw.it("drops the cast bar under the lower of the two rows", function()
		local debuffs = assert(DebuffContainer(targetFrame), "the target frame got a debuff row")
		local _, relativeTo = targetFrame.spellbar:GetPoint(1)

		assert(relativeTo == debuffs, "the bar follows the bottom row, so it cannot cover it")
	end)
end)

fw.describe("Frame Auras - handing the target frame back", function()
	fw.before_each(function()
		module:StopTesting()
		targetAuras.Available = true
		options.TargetFocus.Enabled = false
		module:Refresh()

		blizzardAuras:Reset()
	end)

	fw.it("switches the client's own container off while the rows are up", function()
		options.TargetFocus.Enabled = true
		module:Refresh()

		assert(not blizzardAuras:IsEnabled(), "the client's container stops tracking")
		assert(not blizzardAuras:IsShown(), "and stops drawing what it already had")

		-- Those two and nothing else. There is no getter for either count or for the unit, so a
		-- module that emptied them could never fill them back in.
		assert(blizzardAuras._maxBuffs == BLIZZARD_MAX_BUFFS, "its buff count is left alone")
		assert(blizzardAuras._maxDebuffs == BLIZZARD_MAX_DEBUFFS, "so is its debuff count")
		assert(blizzardAuras._unit == "target", "and so is the unit it was pointed at")
	end)

	fw.it("hands the container back the moment the rows are switched off", function()
		options.TargetFocus.Enabled = true
		module:Refresh()
		options.TargetFocus.Enabled = false
		module:Refresh()

		-- On this pass rather than on the next target change: this is what the player is looking at
		-- when they throw the switch. Nothing else is written to the container, because nothing else
		-- could be read back to write again.
		assert(blizzardAuras:IsEnabled(), "the container is tracking again")
		assert(blizzardAuras:IsShown(), "and drawing again")
		assert(blizzardAuras._maxBuffs == BLIZZARD_MAX_BUFFS,
			"with room for the buffs it had, got " .. tostring(blizzardAuras._maxBuffs))
		assert(blizzardAuras._maxDebuffs == BLIZZARD_MAX_DEBUFFS,
			"and for the debuffs, got " .. tostring(blizzardAuras._maxDebuffs))
		assert(blizzardAuras._unit == "target",
			"still on the unit the frame holds, got " .. tostring(blizzardAuras._unit))
	end)

	fw.it("hands an already-off container back the way it found it", function()
		blizzardAuras._enabled = false
		blizzardAuras._shown = false

		options.TargetFocus.Enabled = true
		module:Refresh()
		options.TargetFocus.Enabled = false
		module:Refresh()

		assert(not blizzardAuras:IsEnabled(), "a container the player had off is handed back off")
		assert(not blizzardAuras:IsShown(), "rather than switched on by a module that found it off")
	end)

	fw.it("leaves a container alone that it never took over", function()
		blizzardAuras._enabled = false
		blizzardAuras._shown = false

		module:Refresh()

		assert(not blizzardAuras:IsEnabled(), "a player who switched these off keeps them off")
		assert(not blizzardAuras:IsShown(), "and gets back nothing the module never took")
	end)

	fw.it("puts the cast bar back where the client had it", function()
		local bar = targetFrame.spellbar

		options.TargetFocus.Enabled = true
		module:Refresh()

		local _, followed = bar:GetPoint(1)

		assert(followed and followed ~= targetFrame, "the bar follows the rows while they are up")

		-- A second pass over a bar this module has already moved. What gets handed back is what
		-- the client had, never the anchor the rows put there.
		module:Refresh()

		options.TargetFocus.Enabled = false
		module:Refresh()

		local point, relativeTo, relativePoint, x, y = bar:GetPoint(1)

		assert(bar:GetNumPoints() == 1, "one anchor, not the row's left sitting under the client's")
		assert(point == CASTBAR_HOME.Point and relativePoint == CASTBAR_HOME.RelativePoint,
			"the bar is back on the client's own anchor, got " .. tostring(point))
		assert(relativeTo == targetFrame, "hung off the frame again rather than off a row that is gone")
		assert(x == CASTBAR_HOME.X and y == CASTBAR_HOME.Y, "at the client's own offset")
	end)
end)

targetAuras.Available = TARGET_ROWS_SHIPPED
