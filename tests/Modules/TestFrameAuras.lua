-- The Frame Auras module: the buff whitelist it filters on, and the one thing it does to the
-- client outside its own frames, switching Blizzard's raid frame aura rows off while it draws
-- its own. That cvar is only ever written on an edge, so a player who turned Blizzard's rows off
-- themselves does not get them handed back by a module they never switched on.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
-- The sweep only moves on a frame of its own, so a test that waits on it has to pump it by hand.
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

-- The client's aura classification policies, as AuraContainerMock publishes them.
local PROCESS_AURA_POLICY = 1
local NO_PROCESS_POLICY = 0
-- The debuff sort the row asks for, which ranks on what that classification writes.
local UNIT_FRAME_DEBUFF_SORT = 2

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
local classBuffs = env.addon.Core.ClassBuffs
local readableAuraIds = env.addon.Core.ReadableAuraIds
local options = db.Modules.FrameAuras
local dbDefaults = env.addon.Config.Defaults
local moduleUtil = env.addon.Utils.ModuleUtil
local auraContainerDisplay = env.addon.Core.AuraContainerDisplay

-- Every display the rows build, kept as it is made. The module holds them privately, and the style
-- one was built with can only be read off the display itself.
local builtDisplays = {}
local realNewDisplay = auraContainerDisplay.New

auraContainerDisplay.New = function(self, ...)
	local display = realNewDisplay(self, ...)

	builtDisplays[#builtDisplays + 1] = display

	return display
end

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
-- The second Lifebloom, which the client names after the spell it copies.
local FULL_BLOOM = 290754
-- The aura groups the rows draw through. Boss and role auras lead the debuff row, then crowd
-- control, both drawn larger than the rest of it.
local PARTY_BUFF_GROUP = "FrameBuffs"
local DEBUFF_GROUP = "FrameDebuffs"
local DEBUFF_CROWD_CONTROL_GROUP = "FrameDebuffsCrowdControl"
local DEBUFF_ROLE_GROUP = "FrameDebuffsRole"
-- What the front of the row is drawn at, as a share of the rest of it.
local LEAD_SCALE = 1.25
-- The cap each of the two groups at the front of the row carries, whatever the row's own budget
-- is.
local LEAD_MAX_ICONS = 2
-- The gap the rows leave between one icon and the next.
local ICON_SPACING = 1
-- What an icon falls back to only when its frame has never once been measured successfully.
local FALLBACK_ICON_SIZE = 14

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

---Fires one event at the frames listening for it. A refresh would carry a settings change with it.
---@param event string
local function Fire(event)
	for _, frame in ipairs(acm.frames) do
		local listening = frame._events and frame._events[event]
		local handler = frame._scripts and frame._scripts.OnEvent

		if listening and handler then
			handler(frame, event)
		end
	end
end

fw.describe("Frame Auras - the tracked buff list", function()
	fw.it("tracks every curated spell out of the box", function()
		ResetSpells()

		assert(spells:IsCurated(CURATED), "the sample id should be curated")
		assert(spells:IsTracked(CURATED), "a curated spell starts tracked")
		assert(not spells:IsTracked(CUSTOM), "an id nobody added is not tracked")
	end)

	fw.it("ships Full Bloom under a label of its own", function()
		ResetSpells()

		assert(spells:IsCurated(FULL_BLOOM), "Full Bloom ships tracked")
		assert(trackedBuffs.Names[FULL_BLOOM] == "Full Bloom",
			"and the list names it, because the client calls it Lifebloom")
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
	fw.it("hands the row back on a login after a reload stranded the write", function()
		-- What a reload mid-fight leaves behind: the side off, and the flag still set because the
		-- write it was waiting on never reached the client.
		ResetCVars()
		db.FrameAuraCVars = { Buffs = true }
		cvars.raidFramesDisplayBuffs = "0"

		-- The debuff side is the other half of the same pass: off, nothing held for it, and the
		-- player keeping Blizzard's row hidden by their own choice. It must be left alone.
		cvars.raidFramesDisplayDebuffs = "0"

		partyAuras:Refresh()

		local handed = LastWrite("raidFramesDisplayBuffs")
		local untouched = LastWrite("raidFramesDisplayDebuffs")

		db.FrameAuraCVars = nil
		cvars.raidFramesDisplayBuffs = "1"
		cvars.raidFramesDisplayDebuffs = "1"

		assert(handed == "1", "the row was left hidden with nothing drawing it, got " .. tostring(handed))
		assert(untouched == nil, "a row this module never took was handed back, got " .. tostring(untouched))
	end)

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

	fw.it("writes nothing when the client already holds the value", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		-- What the client carries into a session that follows one with this side switched on.
		cvars.raidFramesDisplayBuffs = "0"
		ResetCVars()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		local written = #cvarWrites

		-- The tests after this one build on the state a session with this side on leaves behind.
		cvars.raidFramesDisplayBuffs = "0"
		db.FrameAuraCVars = nil

		assert(written == 0, "writing what the client holds rebuilds every raid frame for nothing")
	end)

	fw.it("hands Blizzard's row back when a side is switched off", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		ResetCVars()
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(LastWrite("raidFramesDisplayBuffs") == "1", "the row goes back to the client's default")
	end)

	fw.it("holds the flag from the switch going on until the hand-back reaches the client", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		local taken = db.FrameAuraCVars.Buffs

		env.inCombat = true

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		-- What a reload landing here would leave for the next login to hand back.
		local owed = db.FrameAuraCVars.Buffs

		env.inCombat = false
		Fire("PLAYER_REGEN_ENABLED")

		local settled = db.FrameAuraCVars.Buffs

		db.FrameAuraCVars = nil
		cvars.raidFramesDisplayBuffs = "1"

		assert(taken == true, "the switch going on records the row as taken, got " .. tostring(taken))
		assert(owed == true, "it is still owed while the write waits on the fight, got " .. tostring(owed))
		assert(settled == false, "the write landing lets it go, got " .. tostring(settled))
	end)

	fw.it("switches the row back on even where the player had it off", function()
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		-- A player who had already turned Blizzard's buffs off themselves.
		cvars.raidFramesDisplayBuffs = "0"

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		local handed = cvars.raidFramesDisplayBuffs

		db.FrameAuraCVars = nil
		cvars.raidFramesDisplayBuffs = "1"

		assert(handed == "1", "the row the player had off is not switched back on, got " .. tostring(handed))
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

	fw.it("keeps the row hidden when a side goes off and back on inside one fight", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		env.inCombat = true

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		env.inCombat = false
		Fire("PLAYER_REGEN_ENABLED")

		local held = cvars.raidFramesDisplayBuffs

		options.Buffs.Enabled = false
		partyAuras:Refresh()
		db.FrameAuraCVars = nil
		cvars.raidFramesDisplayBuffs = "1"

		assert(held == "0", "the hand-back queued behind the switch ran anyway, got " .. tostring(held))
	end)

	fw.it("hands the row back when a side ends a fight switched off", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		env.inCombat = true

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		env.inCombat = false
		Fire("PLAYER_REGEN_ENABLED")

		local held = cvars.raidFramesDisplayBuffs

		db.FrameAuraCVars = nil
		cvars.raidFramesDisplayBuffs = "1"

		assert(held == "1", "a side that ends a fight switched off keeps the row, got " .. tostring(held))
	end)

	fw.it("hands the row back for a side that has been on since login", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		-- No flag held, which is where a side left on across a reload starts.
		db.FrameAuraCVars = nil
		env.inCombat = true

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		env.inCombat = false
		Fire("PLAYER_REGEN_ENABLED")

		ResetCVars()
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		local handed = LastWrite("raidFramesDisplayBuffs")

		db.FrameAuraCVars = nil
		cvars.raidFramesDisplayBuffs = "1"

		assert(handed == "1", "a side on since login hands nothing back, got " .. tostring(handed))
	end)

	fw.it("hands the row back long after a side was switched off and on in one fight", function()
		options.Buffs.Enabled = true
		partyAuras:Refresh()

		env.inCombat = true

		options.Buffs.Enabled = false
		partyAuras:Refresh()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		env.inCombat = false
		Fire("PLAYER_REGEN_ENABLED")

		-- Long after the fight, so the churn inside it cannot strand the flag that owes the write.
		ResetCVars()
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		local handed = LastWrite("raidFramesDisplayBuffs")

		db.FrameAuraCVars = nil
		cvars.raidFramesDisplayBuffs = "1"

		assert(handed == "1", "the churn inside the fight stranded the hand-back, got " .. tostring(handed))
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

	fills[#fills + 1] = {
		Container = container,
		Spells = captured,
		Frame = container.Frame,
		Lead = fillOptions.LeadCount,
		HideNumbers = fillOptions.HideNumbers,
		FontScale = fillOptions.FontScale,
		CenterStackText = fillOptions.CenterStackText,
	}

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

---How many aura containers are parented to a frame.
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

---The aura container carrying a given group on a frame, or nil where nothing built one.
---@param frame table
---@param groupKey string
---@return table?
local function GroupRowOn(frame, groupKey)
	for _, candidate in ipairs(acm.frames) do
		if candidate._type == "AuraContainer" and candidate:GetParent() == frame
			and candidate._groups[groupKey] then
			return candidate
		end
	end

	return nil
end

---The display behind one of those containers, which is where its style is kept.
---@param container table?
---@return table?
local function DisplayBehind(container)
	for index = #builtDisplays, 1, -1 do
		if builtDisplays[index].Frame == container then
			return builtDisplays[index]
		end
	end

	return nil
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

---How many lines a preview row's icons ended up on, counted by the distinct heights they were
---placed at. A row that never wrapped puts every icon at one height.
---@param container IconSlotContainer
---@return number
local function LinesIn(container)
	local heights = {}
	local lines = 0

	for index = 1, container.Count do
		local slot = container.Slots[index]

		if slot and slot.IsUsed then
			local _, _, _, _, y = slot.Frame:GetPoint(1)

			if not heights[y] then
				heights[y] = true
				lines = lines + 1
			end
		end
	end

	return lines
end

---The leftmost and rightmost x offset on each of a preview row's lines, keyed by the height the
---line sits at. A row that hugs the edge it grows from shares one of the two across every line.
---@param container IconSlotContainer
---@return table<number, { Min: number, Max: number }>
local function LineSpansIn(container)
	local spans = {}

	for index = 1, container.Count do
		local slot = container.Slots[index]

		if slot and slot.IsUsed then
			local _, _, _, x, y = slot.Frame:GetPoint(1)
			local span = spans[y]

			if span then
				span.Min = math.min(span.Min, x)
				span.Max = math.max(span.Max, x)
			else
				spans[y] = { Min = x, Max = x }
			end
		end
	end

	return spans
end

---The x offset each line of a preview row starts at, taken from the edge the row grows from.
---@param container IconSlotContainer
---@param leftward boolean Whether the row fills leftwards, so its icons pile up on the right.
---@return number[]
local function StartsIn(container, leftward)
	local starts = {}

	for _, span in pairs(LineSpansIn(container)) do
		starts[#starts + 1] = leftward and span.Max or span.Min
	end

	return starts
end

---@param starts number[]
---@return string
local function Listed(starts)
	return table.concat(starts, ", ")
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
		local expected = options.Buffs.MaxIcons + options.Debuffs.MaxIcons
			+ math.min(options.Debuffs.MaxIcons, LEAD_MAX_ICONS) + 1

		-- Buffs are two groups only while the refresh-window reveal is on: the plain row plus one
		-- button for the single spell that carries it. Debuffs are two, because the boss and role
		-- auras always lead the row in a group of their own, even with crowd control off.
		assert(groups == 4, "four groups on a frame, got " .. groups)
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

	fw.it("hands the reveal to the glow group's buttons and no others", function()
		options.Buffs.Enabled = true
		options.Buffs.PandemicGlow = true

		local fresh = NewPartyFrame(5)

		partyAuras:Refresh()
		acm.tickAll(400)

		local buffs

		for _, candidate in ipairs(acm.frames) do
			if candidate._type == "AuraContainer" and candidate:GetParent() == fresh then
				buffs = candidate
			end
		end

		assert(buffs, "the buff row was built")

		local glowing = buffs._groups["FrameBuffsPandemic"].buttons
		local plainRow = buffs._groups["FrameBuffs"].buttons

		-- Both loops below pass over an empty list, so the counts are what keeps them honest.
		assert(#glowing > 0 and #plainRow > 0, "both groups built buttons")

		for _, button in ipairs(glowing) do
			assert(button._calls.AddPandemicRegion == 1, "the glow group's buttons carry a region")
		end

		-- The engine lights every region it is handed, so a region here would put the cue on any
		-- heal over time in the row rather than the one spell that asked for it.
		for _, button in ipairs(plainRow) do
			assert((button._calls.AddPandemicRegion or 0) == 0, "the plain group's buttons carry none")
		end

		DropPartyFrame(5)
	end)
end)

fw.describe("Frame Auras - the icon size measured off the frame", function()
	fw.before_each(function()
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = false
		partyAuras:Refresh()
	end)

	fw.it("keeps the size it last measured when the frame stops answering, not the fallback", function()
		-- The mock's UIParent carries no size until told, which always fails the measurement and
		-- hides a real one behind the fallback. Give the screen a real height so this test can
		-- tell the two apart.
		local screenWidth, screenHeight = _G.UIParent:GetWidth(), _G.UIParent:GetHeight()
		local fresh, realGetHeight

		_G.UIParent:SetSize(1920, 1080)

		-- Every other test in this file measures against a sizeless screen, so the two changes
		-- above have to come back however this one ends.
		local ok, err = pcall(function()
			fresh = NewRaidFrame(39)
			fresh:SetSize(100, 200)

			partyAuras:Refresh()
			acm.tickAll(400)

			local row = assert(GroupRowOn(fresh, PARTY_BUFF_GROUP), "the frame got a buff row")
			local measured = row._groups[PARTY_BUFF_GROUP].layout.elementHeight

			assert(measured > 0 and measured ~= FALLBACK_ICON_SIZE,
				"measured against the frame's real height, got " .. tostring(measured))

			realGetHeight = fresh.GetHeight
			fresh.GetHeight = function() return 0 end

			partyAuras:Refresh()
			acm.tickAll(400)

			assert(row._groups[PARTY_BUFF_GROUP].layout.elementHeight == measured,
				"kept the size it last measured rather than the fallback, got "
				.. tostring(row._groups[PARTY_BUFF_GROUP].layout.elementHeight))
		end)

		if realGetHeight then
			fresh.GetHeight = realGetHeight
		end

		_G.UIParent:SetSize(screenWidth, screenHeight)
		DropRaidFrame(39)

		assert(ok, err)
	end)
end)

fw.describe("Frame Auras - clearing the raid frame power bar", function()
	fw.before_each(function()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		partyAuras:Refresh()
	end)

	---How far off the bottom of its frame a side's row was pinned.
	---@param frame table
	---@param groupKey string
	---@return number
	local function RowHeightOn(frame, groupKey)
		local row = GroupRowOn(frame, groupKey)

		assert(row, "the row was built")

		local _, _, _, _, y = row:GetPoint(1)

		return y
	end

	fw.it("lifts both rows clear of the bar the client made room for", function()
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = true

		local plain = NewRaidFrame(6)
		local powered = NewRaidFrame(7)

		-- What the client writes on a frame it has just laid a power bar out on. Every one of its
		-- own bottom-anchored pieces adds the same number.
		powered.powerBarUsedHeight = 8

		partyAuras:Refresh()
		acm.tickAll(400)

		local plainBuffs = RowHeightOn(plain, PARTY_BUFF_GROUP)
		local plainDebuffs = RowHeightOn(plain, DEBUFF_GROUP)

		assert(RowHeightOn(powered, PARTY_BUFF_GROUP) == plainBuffs + 8,
			"the buff row sits above the bar, got " .. RowHeightOn(powered, PARTY_BUFF_GROUP))
		assert(RowHeightOn(powered, DEBUFF_GROUP) == plainDebuffs + 8,
			"and so does the debuff row, got " .. RowHeightOn(powered, DEBUFF_GROUP))

		DropRaidFrame(6)
		DropRaidFrame(7)
	end)

	fw.it("moves the rows when the bar is switched on behind its back", function()
		options.Buffs.Enabled = true

		local frame = NewRaidFrame(8)

		partyAuras:Refresh()
		acm.tickAll(400)

		local seated = RowHeightOn(frame, PARTY_BUFF_GROUP)

		-- The player throws the client's own switch, so nothing this module owns has moved and the
		-- roster pass is what carries the frame back through.
		frame.powerBarUsedHeight = 8

		local events = acm.lastFrameForEvent("GROUP_ROSTER_UPDATE")

		assert(events, "the module registered for the roster")
		events:TriggerEvent("GROUP_ROSTER_UPDATE")

		assert(RowHeightOn(frame, PARTY_BUFF_GROUP) == seated + 8,
			"the row followed the bar up, got " .. RowHeightOn(frame, PARTY_BUFF_GROUP))

		DropRaidFrame(8)
	end)

	fw.it("puts the rows back down when the bar goes away", function()
		options.Buffs.Enabled = true

		local frame = NewRaidFrame(9)
		frame.powerBarUsedHeight = 8

		partyAuras:Refresh()
		acm.tickAll(400)

		local lifted = RowHeightOn(frame, PARTY_BUFF_GROUP)

		frame.powerBarUsedHeight = 0

		local events = acm.lastFrameForEvent("GROUP_ROSTER_UPDATE")
		events:TriggerEvent("GROUP_ROSTER_UPDATE")

		assert(RowHeightOn(frame, PARTY_BUFF_GROUP) == lifted - 8,
			"the row came back down, got " .. RowHeightOn(frame, PARTY_BUFF_GROUP))

		DropRaidFrame(9)
	end)

	fw.it("leaves a frame alone where the client says nothing about a bar", function()
		options.Buffs.Enabled = true

		-- Frames from other addons carry no such field, and they place their own bars.
		local frame = NewRaidFrame(10)

		partyAuras:Refresh()
		acm.tickAll(400)

		assert(RowHeightOn(frame, PARTY_BUFF_GROUP) == 2,
			"the shipped inset and nothing else, got " .. RowHeightOn(frame, PARTY_BUFF_GROUP))

		DropRaidFrame(10)
	end)
end)

fw.describe("Frame Auras - test mode", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		-- The tests that throw these leave them thrown when they fail part way.
		options.Debuffs.ShowCrowdControl = false
		options.Buffs.ShowDefensives = false
		-- A test that raises the screen and then fails would otherwise leave it up for every test
		-- after it.
		env.loadingScreenUp = false
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

	fw.it("captions no preview row", function()
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = true

		module:StartTesting()

		assert(#fills > 0, "the preview drew something")

		for _, fill in ipairs(fills) do
			assert(not fill.Frame.MiniAurasTestLabel, "a preview row got a caption")
		end
	end)

	fw.it("builds through the login layout pass", function()
		options.Buffs.Enabled = true

		local frame = NewRaidFrame(20)

		-- Blizzard shows all forty raid frames and five party frames pointed at "player" while it
		-- lays them out at login, so a row is ready on each before a group can turn up.
		env.loadingScreenUp = true

		partyAuras:Refresh()

		local built = ContainersOn(frame)

		env.loadingScreenUp = false

		DropRaidFrame(20)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(built > 0, "the layout pass built nothing")
	end)

	fw.it("stops the client tracking a row the layout pass built on an empty frame", function()
		options.Buffs.Enabled = true

		local frame = NewRaidFrame(24)
		local realExists = _G.UnitExists

		-- Forty-five containers the client still weighs auras against is the cost this is here to
		-- catch.
		env.loadingScreenUp = true

		partyAuras:Refresh()

		-- The groups only declare once the screen is off the walker's way.
		env.loadingScreenUp = false

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = GroupRowOn(frame, PARTY_BUFF_GROUP)

		assert(row, "the layout pass built the row")

		_G.UnitExists = function()
			return false
		end

		partyAuras:Refresh()

		local tracking = row._enabled

		_G.UnitExists = realExists
		DropRaidFrame(24)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(tracking == false, "the client is still weighing every aura against an empty row")
	end)

	fw.it("measures a row built behind the screen again once it lifts", function()
		options.Debuffs.Enabled = true
		options.Debuffs.MaxIcons = 3

		local frame = NewRaidFrame(21)

		env.loadingScreenUp = true

		partyAuras:Refresh()

		-- No refresh behind it, because the pass the screen lifting runs carries none either. An
		-- entry stamped as settled behind the screen would keep the geometry it read mid-layout.
		options.Debuffs.MaxIcons = 2
		env.loadingScreenUp = false

		Fire("LOADING_SCREEN_DISABLED")
		acm.tickAll(400)

		local row = GroupRowOn(frame, DEBUFF_GROUP)
		local budget = row and row._groups[DEBUFF_GROUP].maxFrameCount

		DropRaidFrame(21)
		options.Debuffs.MaxIcons = 3
		options.Debuffs.Enabled = false
		partyAuras:Refresh()

		assert(budget == 2, "the pass after the screen never measured the row again, got " .. tostring(budget))
	end)

	fw.it("waits for a definite answer before building a frame's rows", function()
		options.Buffs.Enabled = true

		local frame = NewPartyFrame(5)
		local realExists = _G.UnitExists

		-- What a loading screen looks like: the client answers about units secretly. Not falsely,
		-- because a secret answer reads as "maybe" and the show path deliberately treats it as
		-- occupied. Building is a batch of buttons the engine can never free, so it has to mean
		-- "not yet".
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

		-- Put it on screen and it gets one, so the walk defers the work rather than losing it.
		hidden:Show()
		partyAuras:Refresh()

		assert(ContainersOn(hidden) > 0, "showing the frame is what builds its rows")

		options.Buffs.Enabled = false
		_G.CompactRaidFrame2 = nil
	end)

	fw.it("puts a stun in the debuff preview only while crowd control is let in", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = false

		module:StartTesting()

		local stun = testSpells.FrameAuras.CrowdControl

		assert(#fills > 0, "the debuff row previews something")
		assert(not Includes(fills[1].Spells, stun), "with crowd control kept out, no stun is shown")

		module:StopTesting()
		ResetFills()
		options.Debuffs.ShowCrowdControl = true
		module:StartTesting()

		assert(Includes(fills[1].Spells, stun), "letting it in puts one in the row")
		assert(fills[1].Spells[1] == stun, "and it leads, the way a flagged category does in play")

		options.Debuffs.ShowCrowdControl = false
	end)

	fw.it("rings the stun leading the debuff preview while the dispel colours are on", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true
		options.Debuffs.ColorByDispelType = true

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")
		local border = row.Slots[1].Container.Border
		local tint = _G.DEBUFF_TYPE_NONE_COLOR

		assert(border._shown, "the stand-in is ringed the way the live icon is")

		local color = border._lastArgs.SetVertexColor

		assert(color[1] == tint.r and color[2] == tint.g and color[3] == tint.b,
			"in the colour the game gives a stun, which carries no dispel type")
		assert(row.Slots[2].Container.Border._shown == false,
			"while the debuffs behind it are drawn plain")

		module:StopTesting()
		ResetFills()
		options.Debuffs.ColorByDispelType = false
		module:StartTesting()

		local plain = assert(RowOn(memberFrame), "the frame still gets a preview row")

		assert(plain.Slots[1].Container.Border._shown == false,
			"and switching the colours off takes the ring off the preview too")

		options.Debuffs.ShowCrowdControl = false
		options.Debuffs.ColorByDispelType = true
	end)

	fw.it("draws the stun leading the debuff preview a quarter again the size of the rest", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")
		local plain = row.Slots[2].Frame:GetWidth()

		assert(plain > 0, "the row has a size to be measured against")
		assert(math.abs(row.Slots[1].Frame:GetWidth() - plain * LEAD_SCALE) < 0.01,
			"the stun leading the row is drawn larger, got " .. row.Slots[1].Frame:GetWidth())

		module:StopTesting()
		ResetFills()
		options.Debuffs.ShowCrowdControl = false
		module:StartTesting()

		local uniform = assert(RowOn(memberFrame), "the frame still gets a preview row")

		assert(uniform.Slots[1].Frame:GetWidth() == uniform.Slots[2].Frame:GetWidth(),
			"and with crowd control kept out the row is drawn at one size, got "
			.. uniform.Slots[1].Frame:GetWidth())
	end)

	fw.it("counts the stand-ins at the head of the list, so a repeat does not draw one again", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		module:StartTesting()

		assert(fills[1].Lead == 1,
			"the stun leading the list is marked as a stand-in, got " .. tostring(fills[1].Lead))

		module:StopTesting()
		ResetFills()
		options.Debuffs.ShowCrowdControl = false
		module:StartTesting()

		assert(fills[1].Lead == 0,
			"and a row leading with nothing marks nothing, got " .. tostring(fills[1].Lead))
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

	fw.it("previews the heal-over-times and the plain debuffs its rows are for", function()
		local hots = { 8936, 155777, 48438 }
		local corruption = 146739

		options.Buffs.Enabled = true

		module:StartTesting()

		local buffs = assert(fills[1], "the buff row previews something").Spells

		for _, spellId in ipairs(hots) do
			assert(Includes(buffs, spellId), "heal-over-time " .. spellId .. " reached the row")
		end

		module:StopTesting()
		ResetFills()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = true
		module:StartTesting()

		local debuffs = assert(fills[1], "the debuff row previews something").Spells

		assert(Includes(debuffs, corruption), "Corruption reached the row")

		options.Debuffs.Enabled = false
	end)

	---Checks a previewed row against the order its spells are meant to draw in.
	---@param row number[]
	---@param expected number[]
	local function AssertOrder(row, expected)
		assert(#row == #expected, "the row draws every spell in the list, got " .. #row)

		for index, spellId in ipairs(expected) do
			assert(row[index] == spellId,
				"slot " .. index .. " is " .. spellId .. ", got " .. tostring(row[index]))
		end
	end

	fw.it("draws the heal-over-times in the order the buff row lists them", function()
		options.Buffs.Enabled = true

		module:StartTesting()

		local row = assert(fills[1], "the buff row previews something").Spells

		-- Lifebloom, Rejuvenation, Germination, Regrowth, Wild Growth, Renew, Riptide.
		AssertOrder(row, { 33763, 774, 155777, 8936, 48438, 139, 61295 })

		options.Buffs.Enabled = false
	end)

	fw.it("draws the debuffs in the order the debuff row lists them", function()
		options.Debuffs.Enabled = true

		module:StartTesting()

		local row = assert(fills[1], "the debuff row previews something").Spells

		-- Vampiric Touch, Shadow Word: Pain, Agony, Corruption.
		AssertOrder(row, { 34914, 589, 980, 146739 })

		options.Debuffs.Enabled = false
	end)

	fw.it("draws the whole icon budget, wrapped at the icons per row", function()
		options.Buffs.Enabled = true
		options.Buffs.MaxIcons = 8
		options.Buffs.PerRow = 3

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")

		assert(row:GetUsedSlotCount() == 8,
			"the budget above the line width still draws every icon, got " .. row:GetUsedSlotCount())
		assert(LinesIn(row) == 3, "and wraps them three to a line, got " .. LinesIn(row))

		options.Buffs.MaxIcons = 6
		options.Buffs.PerRow = 3
		options.Buffs.Enabled = false
	end)

	fw.it("hangs every buff line off the right, the corner the live row grows from", function()
		options.Buffs.Enabled = true
		options.Buffs.MaxIcons = 5
		options.Buffs.PerRow = 3

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")
		local starts = StartsIn(row, true)
		local _, _, _, firstX = row.Slots[1].Frame:GetPoint(1)

		assert(#starts == 2, "the budget wrapped onto a second line, got " .. #starts)
		assert(starts[1] == starts[2], "both lines end on the same edge, got " .. Listed(starts))
		assert(firstX == starts[1], "and slot 1 is the icon on it, got " .. firstX)

		options.Buffs.MaxIcons = 6
		options.Buffs.PerRow = 3
		options.Buffs.Enabled = false
	end)

	fw.it("hangs every debuff line off the left, the corner that row grows from", function()
		options.Debuffs.Enabled = true
		options.Debuffs.MaxIcons = 5
		options.Debuffs.PerRow = 3

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")
		local starts = StartsIn(row, false)
		local _, _, _, firstX = row.Slots[1].Frame:GetPoint(1)

		assert(#starts == 2, "the budget wrapped onto a second line, got " .. #starts)
		assert(starts[1] == starts[2], "both lines start on the same edge, got " .. Listed(starts))
		assert(firstX == starts[1], "and slot 1 is the icon on it, got " .. firstX)

		options.Debuffs.MaxIcons = 3
		options.Debuffs.PerRow = 3
		options.Debuffs.Enabled = false
	end)

	fw.it("keeps a budget narrower than the line width at its own width", function()
		options.Buffs.Enabled = true
		options.Buffs.MaxIcons = 2
		options.Buffs.PerRow = 6

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")
		local expected = 2 * row.Size + row.Spacing

		assert(row:GetUsedSlotCount() == 2, "the budget is what draws, got " .. row:GetUsedSlotCount())
		assert(row.Frame:GetWidth() == expected,
			"and the row is no wider than the icons in it, got " .. row.Frame:GetWidth())

		options.Buffs.MaxIcons = 6
		options.Buffs.PerRow = 3
		options.Buffs.Enabled = false
	end)

	fw.it("draws the spells round again rather than stopping short of the budget", function()
		options.Debuffs.Enabled = true
		options.Debuffs.MaxIcons = 9
		options.Debuffs.PerRow = 3

		module:StartTesting()

		local row = assert(RowOn(memberFrame), "the party frame got a preview row")

		assert(#testSpells.FrameAuras.Debuffs < 9, "the debuff list is shorter than this budget")
		assert(row:GetUsedSlotCount() == 9,
			"so it repeats to fill the row, got " .. row:GetUsedSlotCount())

		options.Debuffs.MaxIcons = 3
		options.Debuffs.PerRow = 3
		options.Debuffs.Enabled = false
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

-- The frame hooks the rows install, taken here because the missing buff mark installs its own set
-- later in this file and the environment only remembers the last one.
local partyHooks

---@return table
local function PartyHooks()
	if not partyHooks then
		options.Buffs.Enabled = true
		partyAuras:Refresh()
		partyHooks = assert(env.unitFrameHooks, "the rows installed no frame hooks")
		options.Buffs.Enabled = false
		partyAuras:Refresh()
	end

	return partyHooks
end

fw.describe("Frame Auras - frames the client has not shown yet", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		partyAuras:Refresh()
	end)

	---One of Blizzard's raid frames, off screen, which is how a battleground hands them over
	---before the gates open.
	---@param index number
	---@return table
	local function NewHiddenRaidFrame(index)
		local frame = NewRaidFrame(index)

		frame:Hide()

		return frame
	end

	fw.it("builds on a hidden frame the client has pointed at somebody", function()
		local hooks = PartyHooks()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		local hidden = NewHiddenRaidFrame(30)

		hooks.OnSetUnit(hidden)
		acm.tickAll(400)

		local built = ContainersOn(hidden)

		DropRaidFrame(30)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(built > 0, "a hidden frame with a real unit on it was turned away, got " .. built)
	end)

	fw.it("draws nothing on it while it is off screen", function()
		local hooks = PartyHooks()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		local hidden = NewHiddenRaidFrame(31)

		hooks.OnSetUnit(hidden)
		acm.tickAll(400)

		local row = GroupRowOn(hidden, PARTY_BUFF_GROUP)
		local tracking = row and row._enabled

		DropRaidFrame(31)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(row, "the row was built for the frame")
		assert(tracking == false, "the client is weighing every aura against a row nobody can see")
	end)

	fw.it("still waits for a definite answer about who is on a hidden frame", function()
		local hooks = PartyHooks()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		local hidden = NewHiddenRaidFrame(32)
		local realExists = _G.UnitExists
		-- Building is a batch of buttons the engine can never free, so an answer the client will
		-- not give has to mean "not yet" here as much as it does on a frame that is on screen.
		local secret = wow.markSecret({})

		_G.UnitExists = function()
			return secret
		end

		hooks.OnSetUnit(hidden)

		local built = ContainersOn(hidden)

		_G.UnitExists = realExists
		DropRaidFrame(32)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(built == 0, "a row was built for a unit the client never answered for, got " .. built)
	end)

	fw.it("builds for a unit the client only answers for once it comes into view", function()
		options.Buffs.Enabled = true

		local frame = NewRaidFrame(33)
		local realExists = _G.UnitExists
		local secret = wow.markSecret({})

		-- A battleground before the gates open, with the frame up and pointed at somebody outside
		-- the player's visible world.
		env.phased["raid33"] = true

		_G.UnitExists = function(unit)
			if unit == "raid33" then
				return secret
			end

			return realExists(unit)
		end

		partyAuras:Refresh()

		local beforeView = ContainersOn(frame)

		-- Into view, which the client announces with nothing at all.
		env.phased["raid33"] = nil
		_G.UnitExists = realExists

		acm.tickAll(1)

		local afterView = ContainersOn(frame)

		DropRaidFrame(33)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(beforeView == 0, "the row was built before the client would say who was there")
		assert(afterView > 0, "and coming into view never built it, got " .. afterView)
	end)

	fw.it("watches the unit on a frame that comes on screen between passes", function()
		local hooks = PartyHooks()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		local frame = NewHiddenRaidFrame(34)
		local realExists = _G.UnitExists
		local secret = wow.markSecret({})

		env.phased["raid34"] = true

		_G.UnitExists = function(unit)
			if unit == "raid34" then
				return secret
			end

			return realExists(unit)
		end

		hooks.OnSetUnit(frame)

		-- On screen, still outside the player's visible world. Nothing has walked this frame since
		-- it appeared, so the only thing that can hand its token to the poller is this hook.
		frame:Show()
		hooks.OnUpdateVisible(frame)
		acm.tickAll(1)

		env.phased["raid34"] = nil
		_G.UnitExists = realExists

		acm.tickAll(1)

		local built = ContainersOn(frame)

		DropRaidFrame(34)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(built > 0, "coming into view never built the row, got " .. built)
	end)

	fw.it("drops the rows on a frame a parent hid", function()
		local hooks = PartyHooks()

		options.Buffs.Enabled = true
		partyAuras:Refresh()

		local frame = NewRaidFrame(35)

		hooks.OnSetUnit(frame)
		acm.tickAll(400)

		local row = GroupRowOn(frame, PARTY_BUFF_GROUP)
		local before = row and row._enabled
		local shownBefore = row and row._shown

		-- A container toggled off in Edit Mode takes its members with it, and none of them get a
		-- hook of their own for that.
		frame:Hide()
		hooks.OnSorted()

		local after = row and row._enabled
		local shownAfter = row and row._shown

		DropRaidFrame(35)
		options.Buffs.Enabled = false
		partyAuras:Refresh()

		assert(before == true, "the row never tracked the unit while the frame was up")
		assert(after == false, "the client is still weighing auras for a frame nobody can see")
		assert(shownBefore == true, "the row never went up while the frame was there")
		assert(shownAfter == false, "and it stayed up after the frame went, got " .. tostring(shownAfter))
	end)

	fw.it("zeroes the crowd control budget for a unit outside the visible world", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		local frame = NewRaidFrame(36)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = GroupRowOn(frame, DEBUFF_CROWD_CONTROL_GROUP)
		local group = row and row._groups[DEBUFF_CROWD_CONTROL_GROUP]
		local before = group and group.maxFrameCount

		-- Out of the visible world the token is the group's only filter and the engine stops
		-- weighing it, so the head of the row fills with whatever else the unit has.
		env.phased["raid36"] = true

		acm.tickAll(400)

		local after = group and group.maxFrameCount

		env.phased["raid36"] = nil
		DropRaidFrame(36)
		options.Debuffs.ShowCrowdControl = false
		options.Debuffs.Enabled = false
		partyAuras:Refresh()

		assert(group, "the crowd control group was built")
		assert(before > 0, "the group never got a budget while the unit was in view, got " .. tostring(before))
		assert(after == 0, "the group kept its budget out of view, got " .. tostring(after))
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

---The groups behind the lead are always the false half of the boss and role partition, whatever
---the two switches on the page are set to, since the game never negates that flag in a filter
---string.
---@param filters table
local function AssertRestHalf(filters)
	assert(filters.isBossOrRoleAura == false, "the groups behind the lead are the half without the boss and role auras")
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

	fw.it("narrows the row by the boss and role partition alone with neither switch on", function()
		options.Debuffs.Enabled = true

		-- Its own frame, like the cost tests: a display is built once per frame and kept, so one that
		-- already exists was built under whatever the settings were then.
		local fresh = NewRaidFrame(21)

		partyAuras:Refresh()
		acm.tickAll(400)

		local group = assert(DebuffGroup(fresh), "the frame got a debuff row")
		local filters = assert(group.candidateFilters,
			"the partition is on the group whatever the switches say, since the row always has both halves")

		AssertRestHalf(filters)
		assert(filters.maxDuration == nil and filters.processedAuraType == nil,
			"and with neither switch on there is nothing else to narrow by")

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
		AssertRestHalf(filters)

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
		AssertRestHalf(filters)

		options.Debuffs.Dispellable = false
		DropRaidFrame(23)
	end)

	fw.it("asks for that bound out of the box, which is what the row ships doing", function()
		options.Debuffs.Enabled = true
		-- Back to the shipped answer, which the before_each clears for the tests around this one.
		options.Debuffs.ShortOnly = dbDefaults.Modules.FrameAuras.Debuffs.ShortOnly

		local fresh = NewRaidFrame(25)

		partyAuras:Refresh()
		acm.tickAll(400)

		local group = assert(DebuffGroup(fresh), "the frame got a debuff row")
		local filters = assert(group.candidateFilters,
			"a fresh profile narrows the row without the player touching anything")

		assert(filters.maxDuration == 60,
			"under a minute out of the box, got " .. tostring(filters.maxDuration))
		AssertRestHalf(filters)

		options.Debuffs.ShortOnly = false
		DropRaidFrame(25)
	end)

	fw.it("asks for the dispel classification out of the box, which is what the row ships doing", function()
		options.Debuffs.Enabled = true
		-- Back to the shipped answer, which the before_each clears for the tests around this one.
		options.Debuffs.Dispellable = dbDefaults.Modules.FrameAuras.Debuffs.Dispellable

		local fresh = NewRaidFrame(28)

		partyAuras:Refresh()
		acm.tickAll(400)

		local group = assert(DebuffGroup(fresh), "the frame got a debuff row")
		local filters = assert(group.candidateFilters,
			"a fresh profile narrows the row without the player touching anything")

		assert(filters.processedAuraType == DISPEL_TYPE,
			"dispel classification out of the box, got " .. tostring(filters.processedAuraType))
		AssertRestHalf(filters)

		options.Debuffs.Dispellable = false
		DropRaidFrame(28)
	end)
end)

fw.describe("Frame Auras - what the buff row lets through", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.Buffs.Mine = true
		partyAuras:Refresh()
	end)

	fw.it("narrows the row by its own switches alone, whoever cast the buff", function()
		options.Buffs.Enabled = true

		local fresh = NewRaidFrame(26)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(GroupRowOn(fresh, PARTY_BUFF_GROUP), "the frame got a buff row")
		local group = row._groups[PARTY_BUFF_GROUP]

		assert(group.filterString:find("PLAYER", 1, true),
			"the mine switch reaches the group, got " .. group.filterString)

		-- The engine's own combat narrowing drops buffs the switches above it allow.
		assert(not group.filterString:find("RAID_IN_COMBAT", 1, true),
			"and a fight takes nothing out of the row, got " .. group.filterString)

		-- The "mine" half is a spelling of its own, so a token on one and not the other goes
		-- missing for everyone who turns that switch off.
		options.Buffs.Mine = false
		partyAuras:Refresh()

		-- Losing PLAYER is what proves the refresh published the other spelling.
		assert(not group.filterString:find("PLAYER", 1, true),
			"the switch reached the group, got " .. group.filterString)

		assert(not group.filterString:find("RAID_IN_COMBAT", 1, true),
			"on the everyone-else spelling too, got " .. group.filterString)

		-- Alongside the negation the defensive switch adds, or a defensive would be drawn both here
		-- and on the Important Auras row.
		assert(group.filterString:find("!BIG_DEFENSIVE", 1, true)
			and group.filterString:find("!EXTERNAL_DEFENSIVE", 1, true),
			"without letting the defensives back in, got " .. group.filterString)

		options.Buffs.Mine = true
		DropRaidFrame(26)
	end)
end)

fw.describe("Frame Auras - the text size and the stack count on each row", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.Buffs.TextScale = 100
		options.Debuffs.TextScale = 100
		options.Buffs.CenterStacks = false
		options.Debuffs.CenterStacks = false
		db.FontScale = 1.0
		ResetFills()
		partyAuras:Refresh()
	end)

	fw.it("carries both settings into a row that is already on screen", function()
		db.FontScale = 1.25
		options.Buffs.Enabled = true

		local fresh = NewRaidFrame(30)

		partyAuras:Refresh()
		acm.tickAll(400)

		local display = assert(DisplayBehind(GroupRowOn(fresh, PARTY_BUFF_GROUP)),
			"the frame got a buff row")

		fw.eq(display.Style.FontScale, 1.25, "the shipped hundred percent is the global scale on its own")

		-- Dragging either control while the options window is open reaches a display already on
		-- screen, not a freshly built one.
		options.Buffs.TextScale = 200
		options.Buffs.CenterStacks = true
		partyAuras:Refresh()
		acm.tickAll(400)

		fw.eq(display.Style.FontScale, 2.5, "the display it already had picked the new text size up")
		assert(display.Style.CenterStacks == true, "and the centred count with it")

		db.FontScale = 1.0
		options.Buffs.TextScale = 100
		options.Buffs.CenterStacks = false
		DropRaidFrame(30)
	end)

	fw.it("scales each row's text by its own setting, on top of the global one", function()
		db.FontScale = 1.25
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = true
		options.Buffs.TextScale = 200
		options.Debuffs.TextScale = 50

		local fresh = NewRaidFrame(5)

		partyAuras:Refresh()
		acm.tickAll(400)

		local buffs = assert(DisplayBehind(GroupRowOn(fresh, PARTY_BUFF_GROUP)), "the frame got a buff row")
		local debuffs = assert(DisplayBehind(GroupRowOn(fresh, DEBUFF_GROUP)), "and a debuff row")

		fw.eq(buffs.Style.FontScale, 2.5, "double the text, over the global scale rather than instead of it")
		fw.eq(debuffs.Style.FontScale, 0.625, "and half of it on the row set the other way")

		db.FontScale = 1.0
		options.Buffs.TextScale = 100
		options.Debuffs.TextScale = 100
		DropRaidFrame(5)
	end)

	fw.it("centres the stack count on the row that asked for it and no other", function()
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = true
		options.Buffs.CenterStacks = true

		local fresh = NewRaidFrame(4)

		partyAuras:Refresh()
		acm.tickAll(400)

		local buffs = assert(DisplayBehind(GroupRowOn(fresh, PARTY_BUFF_GROUP)), "the frame got a buff row")
		local debuffs = assert(DisplayBehind(GroupRowOn(fresh, DEBUFF_GROUP)), "and a debuff row")

		assert(buffs.Style.CenterStacks == true, "the switch reached the buff row's style")
		assert(debuffs.Style.CenterStacks == false, "and left the debuff row's countdown where it was")

		options.Buffs.CenterStacks = false
		DropRaidFrame(4)
	end)

	fw.it("shows both of them in the preview they are read against", function()
		db.FontScale = 1.25
		options.Buffs.Enabled = true
		-- The countdown has to be on, or there is nothing for the centred count to displace.
		options.Buffs.EnableNumbers = true

		module:StartTesting()

		assert(#fills > 0, "the buff row previews something")
		fw.eq(fills[1].FontScale, 1.25, "the preview starts on the global scale like the live row")
		assert(fills[1].CenterStackText == nil, "and leaves the count out while the switch is off")
		assert(fills[1].HideNumbers == false, "so the countdown is what the stand-ins draw")

		module:StopTesting()
		ResetFills()
		options.Buffs.TextScale = 200
		options.Buffs.CenterStacks = true
		module:StartTesting()

		fw.eq(fills[1].FontScale, 2.5, "the preview scales its text with the row")
		assert(fills[1].CenterStackText ~= nil, "and stands a count in the middle of each icon")
		-- The live display folds this in for itself, so only the stand-ins have to be told.
		assert(fills[1].HideNumbers == true, "which takes the countdown's place rather than joining it")

		module:StopTesting()
		db.FontScale = 1.0
		options.Buffs.EnableNumbers = false
		options.Buffs.TextScale = 100
		options.Buffs.CenterStacks = false
	end)
end)

---The container the debuff row draws through on a frame, found by the group every one of them
---carries whatever the switches say.
---@param frame table
---@return table?
local function DebuffRow(frame)
	return GroupRowOn(frame, DEBUFF_GROUP)
end

fw.describe("Frame Auras - crowd control at the head of the debuff row", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.Debuffs.ShortOnly = false
		options.Debuffs.Dispellable = false
		options.Debuffs.ShowCrowdControl = false
		partyAuras:Refresh()
	end)

	fw.it("keeps crowd control out of the row until the player asks for it", function()
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(31)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")

		assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP] == nil,
			"a switch that is off builds no group, and a group is a batch of buttons")
		assert(row._groups[DEBUFF_GROUP].filterString:find("!CROWD_CONTROL", 1, true),
			"and the row negates it, which is what keeps one aura out of both halves")

		DropRaidFrame(31)
	end)

	fw.it("leads the row with a group of its own, a quarter again the size of the rest", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		local fresh = NewRaidFrame(32)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the switch built the group")
		local plain = row._groups[DEBUFF_GROUP]

		assert(cc.filterString:find("CROWD_CONTROL", 1, true)
			and not cc.filterString:find("!CROWD_CONTROL", 1, true),
			"the head of the row is the crowd control half of it, got " .. tostring(cc.filterString))
		assert(cc.layout.layoutIndex < plain.layout.layoutIndex, "and it is laid out ahead of the rest")

		local size = plain.layout.elementHeight

		assert(size > 0, "the row has a size to be measured against")
		assert(math.abs(cc.layout.elementHeight - size * LEAD_SCALE) < 0.01,
			"the engine spaces the head of the row at the larger size, got " .. tostring(cc.layout.elementHeight))
		assert(math.abs(cc.buttons[1]:GetHeight() - size * LEAD_SCALE) < 0.01,
			"and the button is drawn at it, got " .. tostring(cc.buttons[1]:GetHeight()))
		assert(math.abs(plain.buttons[1]:GetHeight() - size) < 0.01,
			"while the rest of the row keeps the row's own size")

		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(32)
	end)

	fw.it("carries its own budget, so the line the row wraps at still holds what the player asked for", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true
		-- A row wide enough and deep enough for the scaled group to buy a whole extra icon, which
		-- is what a budget as big as the row's did.
		options.Debuffs.PerRow = 4
		options.Debuffs.MaxIcons = 4

		local fresh = NewRaidFrame(20)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the row carries the crowd control group")

		assert(cc.maxFrameCount == LEAD_MAX_ICONS,
			"the group takes its own cap, not the row's, got " .. tostring(cc.maxFrameCount))

		-- What a row of plain icons alone would wrap at. The scaled group adds to it, and the whole
		-- point of the cap is how much.
		local size = row._groups[DEBUFF_GROUP].layout.elementHeight
		local plain = options.Debuffs.PerRow * (size + ICON_SPACING)

		assert(row._flowMaxLineSize > plain, "the larger icons widen the line they wrap at")
		assert(row._flowMaxLineSize < plain + size + ICON_SPACING,
			"but never by a whole icon and its gap, or a full line takes one more than the player asked for, got "
				.. tostring(row._flowMaxLineSize - plain))

		options.Debuffs.ShowCrowdControl = false
		options.Debuffs.PerRow = dbDefaults.Modules.FrameAuras.Debuffs.PerRow
		options.Debuffs.MaxIcons = dbDefaults.Modules.FrameAuras.Debuffs.MaxIcons
		DropRaidFrame(20)
	end)

	fw.it("gives the group to a row that was built before the switch was thrown", function()
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(33)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")

		assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP] == nil, "built without the group")

		local capped = row._flowMaxLineSize

		assert(capped and capped > 0, "and a line to wrap at")

		options.Debuffs.ShowCrowdControl = true
		partyAuras:Refresh()
		acm.tickAll(400)

		assert(ContainersOn(fresh) == 1, "nothing built a second row for the frame")

		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP],
			"the row it already had grew the group, rather than waiting out a reload")

		assert(cc.maxFrameCount > 0, "with a budget to draw on")
		assert(row._flowMaxLineSize > capped,
			"and the line it wraps at made room for the larger icon, got " .. tostring(row._flowMaxLineSize))

		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(33)
	end)

	fw.it("closes the group down again when the switch goes off", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		local fresh = NewRaidFrame(34)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the group is there while the switch is on")

		assert(cc.maxFrameCount > 0, "and drawing")

		options.Debuffs.ShowCrowdControl = false
		partyAuras:Refresh()
		acm.tickAll(400)

		assert(cc.maxFrameCount == 0, "the switch closes the budget, which is all a group can be told")

		DropRaidFrame(34)
	end)

	-- The switch can move while a row is still being built.
	fw.it("hands the group to a row mid-build, and draws it first anyway", function()
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(36)

		-- No pump: the row exists, but the walker has yet to declare a thing on it.
		partyAuras:Refresh()

		options.Debuffs.ShowCrowdControl = true
		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the group went in with the rest of the build")

		assert(cc.layout.layoutIndex < row._groups[DEBUFF_GROUP].layout.layoutIndex,
			"and leads the row, though it was declared after it")

		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(36)
	end)

	fw.it("narrows the head of the row by whatever the rest of it is narrowed by", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true
		options.Debuffs.ShortOnly = true

		local fresh = NewRaidFrame(35)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the switch built the group")

		assert(cc.candidateFilters and cc.candidateFilters.maxDuration == 60,
			"the two switches on the page are about the row, not about one category of it")

		options.Debuffs.ShowCrowdControl = false
		options.Debuffs.ShortOnly = false
		DropRaidFrame(35)
	end)

	fw.it("rings the head of the row in the dispel colours, and nothing behind it", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true
		options.Debuffs.ColorByDispelType = true

		local fresh = NewRaidFrame(37)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the switch built the group")
		local plain = row._groups[DEBUFF_GROUP]

		assert((cc.buttons[1]._calls.AddDispelTypeTexture or 0) > 0,
			"the crowd control border is handed to the engine, which is the only thing that knows the type")
		assert((plain.buttons[1]._calls.AddDispelTypeTexture or 0) == 0,
			"while the debuffs behind it stand in for Blizzard's own row and stay plain")

		local registered = cc.buttons[1]._lastArgs.AddDispelTypeTexture

		assert(registered[2].showWithoutDispelType == true,
			"and a physical stun still gets a ring, having no dispel type to be coloured by")

		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(37)
	end)

	fw.it("takes the ring off a row that is already drawing when the switch goes off", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true
		options.Debuffs.ColorByDispelType = false

		local fresh = NewRaidFrame(38)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the switch built the group")

		assert((cc.buttons[1]._calls.AddDispelTypeTexture or 0) == 0, "nothing is registered with it off")

		options.Debuffs.ColorByDispelType = true
		partyAuras:Refresh()
		acm.tickAll(400)

		assert((cc.buttons[1]._calls.AddDispelTypeTexture or 0) > 0,
			"the buttons the row already had take the ring, rather than waiting out a reload")

		local cleared = cc.buttons[1]._calls.ClearDispelTypeTextures

		options.Debuffs.ColorByDispelType = false
		partyAuras:Refresh()
		acm.tickAll(400)

		assert(cc.buttons[1]._calls.ClearDispelTypeTextures > cleared,
			"and switching it off again hands the border back")

		options.Debuffs.ShowCrowdControl = false
		options.Debuffs.ColorByDispelType = true
		DropRaidFrame(38)
	end)
end)

fw.describe("Frame Auras - the boss and role auras leading the debuff row", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.Debuffs.ShortOnly = false
		options.Debuffs.Dispellable = false
		options.Debuffs.ShowCrowdControl = false
		partyAuras:Refresh()
	end)

	fw.it("leads the row ahead of crowd control, whatever that switch says", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		local fresh = NewRaidFrame(11)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row always carries the role group")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the switch built the crowd control group")
		local plain = row._groups[DEBUFF_GROUP]

		assert(role.layout.layoutIndex < cc.layout.layoutIndex, "it leads crowd control")
		assert(cc.layout.layoutIndex < plain.layout.layoutIndex, "which leads the rest of the row")

		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(11)
	end)

	fw.it("still leads the row with crowd control switched off", function()
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(12)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row carries the role group without being asked")
		local plain = row._groups[DEBUFF_GROUP]

		assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP] == nil, "crowd control is off")
		assert(role.layout.layoutIndex < plain.layout.layoutIndex, "and the role group still leads")

		DropRaidFrame(12)
	end)

	fw.it("takes the boss and role half of the partition, leaving crowd control and the rest without it", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		local fresh = NewRaidFrame(13)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row carries the role group")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "the switch built the crowd control group")
		local plain = row._groups[DEBUFF_GROUP]

		local roleFilters = assert(role.candidateFilters, "the role group is handed a filter set")
		local ccFilters = assert(cc.candidateFilters, "so is crowd control")
		local plainFilters = assert(plain.candidateFilters, "and so is the rest of the row")

		assert(roleFilters.isBossOrRoleAura == true, "the group takes the boss and role auras and nothing else")
		AssertRestHalf(ccFilters)
		AssertRestHalf(plainFilters)

		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(13)
	end)

	fw.it("takes a plain HARMFUL filter string, with no crowd control token of its own", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		local fresh = NewRaidFrame(40)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row carries the role group")

		assert(role.filterString == "HARMFUL",
			"a crowd control debuff that is also boss or role flagged still has to reach this group, got "
				.. tostring(role.filterString))

		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(40)
	end)

	fw.it("narrows by whatever the rest of the row is narrowed by, on both halves of the partition", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShortOnly = true
		options.Debuffs.Dispellable = true

		local fresh = NewRaidFrame(14)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row carries the role group")
		local roleFilters = assert(role.candidateFilters, "with a filter set on it")
		local plainFilters = assert(row._groups[DEBUFF_GROUP].candidateFilters, "and on the rest of the row")

		assert(roleFilters.maxDuration == 60 and roleFilters.processedAuraType == DISPEL_TYPE,
			"the two switches on the page narrow the role group too, not only the rest of the row")
		assert(plainFilters.maxDuration == 60 and plainFilters.processedAuraType == DISPEL_TYPE,
			"which the rest of the row still carries")
		assert(roleFilters.isBossOrRoleAura == true, "without losing the partition")

		options.Debuffs.ShortOnly = false
		options.Debuffs.Dispellable = false
		DropRaidFrame(14)
	end)

	fw.it("caps its budget at the row's own slider where that is smaller", function()
		options.Debuffs.Enabled = true
		options.Debuffs.MaxIcons = 1

		local fresh = NewRaidFrame(15)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row carries the role group")

		assert(role.maxFrameCount == 1,
			"the row's slider wins under the group's own cap, got " .. tostring(role.maxFrameCount))

		options.Debuffs.MaxIcons = dbDefaults.Modules.FrameAuras.Debuffs.MaxIcons
		DropRaidFrame(15)
	end)

	fw.it("never needs the switch that gates crowd control, unlike the group ahead of it", function()
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(16)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row carries the role group")

		assert(role.maxFrameCount == LEAD_MAX_ICONS,
			"the budget is never zeroed by a switch, got " .. tostring(role.maxFrameCount))

		DropRaidFrame(16)
	end)

	fw.it("re-publishes the right filter set to each of the three groups when the switches flip", function()
		options.Debuffs.Enabled = true
		options.Debuffs.ShowCrowdControl = true

		local fresh = NewRaidFrame(29)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local role = assert(row._groups[DEBUFF_ROLE_GROUP], "the row carries the role group")
		local cc = assert(row._groups[DEBUFF_CROWD_CONTROL_GROUP], "and the crowd control group")
		local plain = row._groups[DEBUFF_GROUP]

		assert(role.candidateFilters.maxDuration == nil, "nothing narrows the row yet")

		options.Debuffs.ShortOnly = true
		partyAuras:Refresh()
		acm.tickAll(400)

		assert(role.candidateFilters.maxDuration == 60, "the role group picked up the new bound")
		assert(role.candidateFilters.isBossOrRoleAura == true, "without losing its own half of the partition")
		assert(cc.candidateFilters.maxDuration == 60 and cc.candidateFilters.isBossOrRoleAura == false,
			"crowd control took the rest half, with the same bound")
		assert(plain.candidateFilters.maxDuration == 60 and plain.candidateFilters.isBossOrRoleAura == false,
			"and so did the plain group behind it")

		options.Debuffs.ShortOnly = false
		options.Debuffs.ShowCrowdControl = false
		DropRaidFrame(29)
	end)
end)

fw.describe("Frame Auras - how the debuff row ranks what it shows", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.Debuffs.ShortOnly = false
		options.Debuffs.Dispellable = false
		options.Debuffs.ShowCrowdControl = false
		partyAuras:Refresh()
	end)

	fw.it("ranks the row by the game's own raid frame debuff order", function()
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(17)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")

		assert(row._groups[DEBUFF_GROUP].sortMethod == UNIT_FRAME_DEBUFF_SORT,
			"nothing can reorder a group once it has rendered, so the engine has to rank it, got "
				.. tostring(row._groups[DEBUFF_GROUP].sortMethod))

		DropRaidFrame(17)
	end)

	fw.it("asks the engine to classify every aura while the dispellable switch wants it", function()
		options.Debuffs.Enabled = true
		options.Debuffs.Dispellable = true

		local fresh = NewRaidFrame(18)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")

		assert(row._processingPolicy == PROCESS_AURA_POLICY,
			"the switch filters on what that pass writes, got " .. tostring(row._processingPolicy))

		options.Debuffs.Dispellable = false
		DropRaidFrame(18)
	end)

	fw.it("leaves the classification off when nothing reads it", function()
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(19)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")

		assert(row._processingPolicy == NO_PROCESS_POLICY,
			"a pass per aura on every unit, for a field nothing reads, got "
				.. tostring(row._processingPolicy))

		DropRaidFrame(19)
	end)

	fw.it("draws the rest of the row in one group, so the whole budget is one pool", function()
		options.Debuffs.Enabled = true
		options.Debuffs.MaxIcons = 4

		local fresh = NewRaidFrame(24)

		partyAuras:Refresh()
		acm.tickAll(400)

		local row = assert(DebuffRow(fresh), "the frame got a debuff row")
		local count = 0

		for _ in pairs(row._groups) do
			count = count + 1
		end

		-- The role group always leads the row, crowd control off or not, so "one pool" means the
		-- role group plus the one group everything else shares.
		assert(count == 2, "the row is the role group and one more, got " .. count)
		assert(row._groups[DEBUFF_GROUP].maxFrameCount == 4,
			"and it draws on the whole slider, got " .. tostring(row._groups[DEBUFF_GROUP].maxFrameCount))
		assert(row._groups[DEBUFF_ROLE_GROUP].maxFrameCount == LEAD_MAX_ICONS,
			"but the role group still takes its own cap, not the row's, got "
				.. tostring(row._groups[DEBUFF_ROLE_GROUP].maxFrameCount))

		options.Debuffs.MaxIcons = dbDefaults.Modules.FrameAuras.Debuffs.MaxIcons
		DropRaidFrame(24)
	end)
end)

---What the engine was last told about one row's countdown numbers, read off the first button the
---row built. Every button on a row is styled from the one style, so the first speaks for the lot.
---@param row table An aura container.
---@param groupKey string
---@return boolean
local function NumbersHiddenOn(row, groupKey)
	local button = assert(row._groups[groupKey].buttons[1], "the group built a button")
	local cooldown = assert(button._lastArgs.SetDurationCooldown, "the button was given a cooldown")[1]

	return cooldown._lastArgs.SetHideCountdownNumbers[1]
end

---How visible one row's stack count is, read off the same button. The engine owns the text, so
---alpha is all the display gets to say about it.
---@param row table An aura container.
---@param groupKey string
---@return number
local function StackAlphaOn(row, groupKey)
	local button = assert(row._groups[groupKey].buttons[1], "the group built a button")
	local stacks = assert(button._lastArgs.SetApplicationCount, "the button was given a count")[1]

	return stacks._lastArgs.SetAlpha[1]
end

-- FontUtil's shared stack ratio, which every other module's icons are large enough for.
local SHARED_STACK_RATIO = 0.38

---The share of the icon one row draws its count at, off the same button.
---@param row table An aura container.
---@param groupKey string
---@return number?
local function StackRatioOn(row, groupKey)
	local button = assert(row._groups[groupKey].buttons[1], "the group built a button")
	local stacks = assert(button._lastArgs.SetApplicationCount, "the button was given a count")[1]

	return stacks._stackRatio
end

fw.describe("Frame Auras - the countdown numbers on one row", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.Buffs.EnableNumbers = true
		options.Debuffs.EnableNumbers = true
		db.DisableNumbers = false
		ResetFills()
		partyAuras:Refresh()
	end)

	fw.it("drops them on the row that asked and leaves the other one counting", function()
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = true
		options.Buffs.EnableNumbers = false

		local fresh = NewRaidFrame(26)

		partyAuras:Refresh()
		acm.tickAll(400)

		local buffs = assert(GroupRowOn(fresh, PARTY_BUFF_GROUP), "the frame got a buff row")
		local debuffs = assert(DebuffRow(fresh), "and a debuff row")

		assert(NumbersHiddenOn(buffs, PARTY_BUFF_GROUP) == true, "the row that asked loses its numbers")
		assert(NumbersHiddenOn(debuffs, DEBUFF_GROUP) == false,
			"and the row beside it keeps them, which is the whole point of a per-row switch")
		-- The switch is over the countdown alone. The count is a separate overlay, and a stack of
		-- three with no number on it says nothing.
		assert(StackAlphaOn(buffs, PARTY_BUFF_GROUP) == 1, "the stack count is still drawn")

		options.Buffs.EnableNumbers = true
		DropRaidFrame(26)
	end)

	fw.it("hides them whenever either switch says so", function()
		options.Debuffs.Enabled = true
		db.DisableNumbers = true

		local fresh = NewRaidFrame(27)

		partyAuras:Refresh()
		acm.tickAll(400)

		local debuffs = assert(DebuffRow(fresh), "the frame got a debuff row")

		assert(options.Debuffs.EnableNumbers == true, "the row asked for its numbers")
		assert(NumbersHiddenOn(debuffs, DEBUFF_GROUP) == true, "and the global switch takes them anyway")

		db.DisableNumbers = false
		options.Debuffs.EnableNumbers = false
		partyAuras:Refresh()
		acm.tickAll(400)

		assert(NumbersHiddenOn(debuffs, DEBUFF_GROUP) == true,
			"the row's own switch holds them off once the global one is gone")

		options.Debuffs.EnableNumbers = true
		partyAuras:Refresh()
		acm.tickAll(400)

		assert(NumbersHiddenOn(debuffs, DEBUFF_GROUP) == false, "and with neither set they come back")

		DropRaidFrame(27)
	end)

	fw.it("takes them out of the preview the switch is read against", function()
		options.Debuffs.Enabled = true

		module:StartTesting()

		assert(#fills > 0, "the debuff row previews something")
		assert(fills[1].HideNumbers == false, "the preview counts down like the live row")

		module:StopTesting()
		ResetFills()
		options.Debuffs.EnableNumbers = false
		module:StartTesting()

		assert(fills[1].HideNumbers == true, "and drops the numbers when the row does")

		options.Debuffs.EnableNumbers = true
		module:StopTesting()
	end)

end)

fw.describe("Frame Auras - how big the count on one row is", function()
	fw.before_each(function()
		module:StopTesting()
		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		partyAuras:Refresh()
	end)

	fw.it("draws it at the row's own share of the icon, the shared one being unreadable here", function()
		options.Buffs.Enabled = true
		options.Debuffs.Enabled = true

		local fresh = NewRaidFrame(28)

		partyAuras:Refresh()
		acm.tickAll(400)

		local buffs = assert(GroupRowOn(fresh, PARTY_BUFF_GROUP), "the frame got a buff row")
		local debuffs = assert(DebuffRow(fresh), "and a debuff row")
		local buffRatio = StackRatioOn(buffs, PARTY_BUFF_GROUP)
		local debuffRatio = StackRatioOn(debuffs, DEBUFF_GROUP)

		-- An icon here is a share of a party frame, so the shared ratio leaves a count of about six
		-- points.
		assert(buffRatio and buffRatio > SHARED_STACK_RATIO,
			"the buff row asks for a bigger count, got " .. tostring(buffRatio))
		assert(debuffRatio and debuffRatio > SHARED_STACK_RATIO,
			"and so does the debuff row, got " .. tostring(debuffRatio))

		DropRaidFrame(28)
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
-- its own icon cap. The describes after this one switch them on to test what will ship then.
-- This one has to come first, because a container is never destroyed, so once a later describe
-- has built the rows once, "nothing is built" could not be told from "something was built
-- earlier".
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

		-- The engine hands a group its buttons from the count it was declared with, so a group
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

fw.describe("Frame Auras - how big the count on the target row is", function()
	fw.before_each(function()
		module:StopTesting()
		targetAuras.Available = true
		options.TargetFocus.Enabled = true

		module:Refresh()
		acm.tickAll(400)
	end)

	fw.it("draws it at the row's own share of the icon, like the group rows do", function()
		local container = assert(BuffContainer(targetFrame), "the target frame got a buff row")
		local ratio = StackRatioOn(container, BUFF_GROUP)

		assert(ratio and ratio > SHARED_STACK_RATIO,
			"these icons are small enough to need their own ratio too, got " .. tostring(ratio))
	end)
end)

fw.describe("Frame Auras - the target preview rows", function()
	fw.before_each(function()
		module:StopTesting()
		targetAuras.Available = true
		options.TargetFocus.Enabled = true
		options.TargetFocus.PurgeGlow = false

		module:Refresh()
		acm.tickAll(400)
		ResetFills()
	end)

	fw.it("draws the whole icon budget, wrapped at the icons per row", function()
		options.TargetFocus.MaxIcons = 10
		options.TargetFocus.PerRow = 4

		module:StartTesting()

		local row = assert(RowOn(targetFrame), "the target frame got a preview row")

		assert(row:GetUsedSlotCount() == 10,
			"the budget above the line width still draws every icon, got " .. row:GetUsedSlotCount())
		assert(LinesIn(row) == 3, "and wraps them four to a line, got " .. LinesIn(row))

		module:StopTesting()
		options.TargetFocus.MaxIcons = 6
		options.TargetFocus.PerRow = 6
	end)

	fw.it("hangs every line off the left, the edge both live rows grow from", function()
		options.TargetFocus.MaxIcons = 10
		options.TargetFocus.PerRow = 4

		module:StartTesting()

		local row = assert(RowOn(targetFrame), "the target frame got a preview row")
		local starts = StartsIn(row, false)
		local _, _, _, firstX = row.Slots[1].Frame:GetPoint(1)

		assert(#starts == 3, "the budget wrapped onto three lines, got " .. #starts)
		assert(starts[1] == starts[2] and starts[2] == starts[3],
			"every line starts on the same edge, got " .. Listed(starts))
		assert(firstX == starts[1], "and slot 1 is the icon on it, got " .. firstX)

		module:StopTesting()
		options.TargetFocus.MaxIcons = 6
		options.TargetFocus.PerRow = 6
	end)

	---The preview row on the target frame that was handed a given spell, so the buff row can be
	---told from the debuff row beside it.
	---@param spellId number
	---@return IconSlotContainer?
	local function TargetRowWith(spellId)
		for _, fill in ipairs(fills) do
			if fill.Frame:GetParent() == targetFrame and Includes(fill.Spells, spellId) then
				return fill.Container
			end
		end

		return nil
	end

	fw.it("counts the purgeable buff leading the row against the budget", function()
		options.TargetFocus.MaxIcons = 9
		options.TargetFocus.PerRow = 9
		options.TargetFocus.PurgeGlow = true

		module:StartTesting()

		local buffs = assert(TargetRowWith(testSpells.FrameAuras.Purgeable),
			"the buff row leads with a purgeable buff")

		assert(buffs:GetUsedSlotCount() == 9,
			"the row ends on the icon the slider promised, got " .. buffs:GetUsedSlotCount())

		module:StopTesting()
		options.TargetFocus.PurgeGlow = false
		options.TargetFocus.MaxIcons = 6
		options.TargetFocus.PerRow = 6
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

	fw.it("switches an already-off container back on", function()
		blizzardAuras._enabled = false
		blizzardAuras._shown = false

		options.TargetFocus.Enabled = true
		module:Refresh()
		options.TargetFocus.Enabled = false
		module:Refresh()

		assert(blizzardAuras:IsEnabled(), "the container is tracking again")
		assert(blizzardAuras:IsShown(), "rather than left dark by the value it was found at")
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

-- The missing class buff mark, on a raid frame built here so nothing an earlier section drew can
-- be mistaken for it. Priest, because Power Word: Fortitude lands as one aura rather than thirteen.
local MARK_CLASS = "PRIEST"
local MARK_SPELL = 21562
-- A second id the same buff could land as, standing for one the client keeps to itself while auras
-- are secret.
local HIDDEN_SPELL = 99000002
local MARK_UNIT = "raid40"
local markFrame = NewRaidFrame(40)
-- Units the client says already carry the buff.
local buffed = {}

_G.C_UnitAuras.GetUnitAuraBySpellID = function(unit, spellId)
	if buffed[unit] and spellId == MARK_SPELL then
		return {}
	end

	return nil
end

---The mark drawn on a frame, or nil when the module never built one there. Marks are created once
---and kept for the session, so a frame that has been marked before keeps its own.
---@param frame table
---@return table?
local function MarkOn(frame)
	for _, candidate in ipairs(acm.frames) do
		if candidate._type ~= "AuraContainer" and candidate.Icon and candidate:GetParent() == frame then
			return candidate
		end
	end

	return nil
end

---@param frame table
---@return boolean
local function Marked(frame)
	local mark = MarkOn(frame)

	return mark ~= nil and mark:IsShown() == true
end

---@param instanceType string
local function MoveTo(instanceType)
	env.instanceType = instanceType
	env.inInstance = instanceType ~= "none"
	moduleUtil:InvalidateWorldState()
end

fw.describe("Frame Auras - where the missing class buff mark shows", function()
	fw.before_each(function()
		module:StopTesting()

		options.Buffs.Enabled = false
		options.Debuffs.Enabled = false
		options.TargetFocus.Enabled = false
		options.ClassBuff.Enabled = true
		options.ClassBuff.InstancesOnly = true

		wow.setUnitClass("player", MARK_CLASS)
		buffed[MARK_UNIT] = nil
		-- Reset here so one failing case cannot poison the next.
		acm.restricted = false
		_G.UnitIsDeadOrGhost = nil
		classBuffs[MARK_CLASS].Auras[HIDDEN_SPELL] = nil
		_G.C_Housing = nil
		MoveTo("none")

		module:Refresh()
	end)

	fw.it("leaves the open world unmarked", function()
		assert(not Marked(markFrame), "nobody is reminded about a group buff out in the world")
	end)

	fw.it("marks a member who is missing the buff inside a dungeon", function()
		MoveTo("party")
		module:Refresh()

		assert(Marked(markFrame), "the mark is up where the group is about to pull")
	end)

	fw.it("marks a member missing the buff a warrior brings", function()
		wow.setUnitClass("player", "WARRIOR")
		MoveTo("party")
		module:Refresh()

		assert(Marked(markFrame), "Battle Shout is a group buff like the rest, so a warrior is read")
	end)

	fw.it("counts a house as the open world", function()
		-- A house loads as an instanced map, so the instance type on its own would put the mark up
		-- in one.
		_G.C_Housing = {
			IsOnNeighborhoodMap = function()
				return false
			end,
			IsInsideHouseOrPlot = function()
				return true
			end,
		}

		MoveTo("party")
		module:Refresh()

		_G.C_Housing = nil

		assert(not Marked(markFrame), "there is nothing to pull in a house")
	end)

	fw.it("leaves a member who already has the buff alone inside a dungeon", function()
		buffed[MARK_UNIT] = true
		MoveTo("party")
		module:Refresh()

		assert(not Marked(markFrame), "a buffed member is not marked just because the zone changed")
	end)

	fw.it("takes the mark down again on the way out", function()
		MoveTo("party")
		module:Refresh()
		MoveTo("none")
		module:Refresh()

		assert(not Marked(markFrame), "the mark goes with the dungeon rather than sticking")
	end)

	fw.it("marks the open world when the player asks for it everywhere", function()
		options.ClassBuff.InstancesOnly = false
		module:Refresh()

		assert(Marked(markFrame), "the switch is what holds the mark back, not the module")
	end)

	fw.it("keeps the mark at the size it last measured when the frame stops answering", function()
		local screenWidth, screenHeight = _G.UIParent:GetWidth(), _G.UIParent:GetHeight()
		local frameWidth, frameHeight = markFrame:GetWidth(), markFrame:GetHeight()
		local realGetHeight = markFrame.GetHeight

		-- Every other test in this file measures against a sizeless screen, so all three changes
		-- below have to come back however this one ends.
		_G.UIParent:SetSize(1920, 1080)
		markFrame:SetSize(100, 200)

		local ok, err = pcall(function()
			MoveTo("party")
			module:Refresh()

			local measured = MarkOn(markFrame):GetHeight()

			assert(measured > 0 and measured ~= FALLBACK_ICON_SIZE,
				"measured against the frame's real height, got " .. tostring(measured))

			markFrame.GetHeight = function()
				return 0
			end

			module:Refresh()

			assert(MarkOn(markFrame):GetHeight() == measured,
				"kept the size it last measured rather than the fallback, got "
				.. tostring(MarkOn(markFrame):GetHeight()))
		end)

		markFrame.GetHeight = realGetHeight
		markFrame:SetSize(frameWidth, frameHeight)
		_G.UIParent:SetSize(screenWidth, screenHeight)

		assert(ok, err)
	end)

	fw.it("previews the mark in the open world", function()
		module:StartTesting()

		assert(Marked(markFrame), "a player who opened the preview asked to see it where they stand")

		module:StopTesting()

		assert(not Marked(markFrame), "and the preview leaves nothing behind on the way out")
	end)

	fw.it("marks a member missing the buff inside an arena", function()
		acm.restricted = true
		MoveTo("arena")
		module:Refresh()

		assert(Marked(markFrame), "this buff stays readable all match, so the mark is drawn")
	end)

	fw.it("leaves a buffed member alone inside an arena", function()
		acm.restricted = true
		buffed[MARK_UNIT] = true
		MoveTo("arena")
		module:Refresh()

		assert(not Marked(markFrame), "the answer is read rather than assumed missing")
	end)

	fw.it("marks nobody in an arena when one of the buff's ids is hidden", function()
		classBuffs[MARK_CLASS].Auras[HIDDEN_SPELL] = true

		acm.restricted = true
		MoveTo("arena")
		module:Refresh()

		local marked = Marked(markFrame)

		classBuffs[MARK_CLASS].Auras[HIDDEN_SPELL] = nil

		assert(not marked, "silence the client never broke must not mark the whole group")
	end)

	fw.it("marks a member the client will not say is alive", function()
		-- Unit identity stays secret for the whole match, which is what this read comes back as.
		local secret = wow.markSecret({})

		_G.UnitIsDeadOrGhost = function()
			return secret
		end

		acm.restricted = true
		MoveTo("arena")
		module:Refresh()

		assert(Marked(markFrame), "one unreadable read must not cost the mark a whole match")
	end)

	fw.it("leaves a dead member unmarked", function()
		_G.UnitIsDeadOrGhost = function()
			return true
		end

		MoveTo("party")
		module:Refresh()

		assert(not Marked(markFrame), "a group buff is not what a corpse is short of")
	end)
end)

DropRaidFrame(40)

-- The mark gives up on a buff carrying an id off the readable list, so a class entry that forgets
-- one costs that class its mark for a whole match with nothing to show for it.
fw.describe("Frame Auras - the class buffs the mark reads", function()
	fw.it("keeps every id a class buff can land as on the readable list", function()
		for class, buff in pairs(classBuffs) do
			for spellId in pairs(buff.Auras) do
				assert(readableAuraIds[spellId], "the " .. class .. " buff can land as " .. spellId
					.. ", which the client hides while auras are secret")
			end
		end
	end)

	fw.it("brings a buff from exactly the classes that have one", function()
		local expected = { DRUID = true, EVOKER = true, MAGE = true, PRIEST = true, SHAMAN = true,
			WARRIOR = true }

		for class in pairs(classBuffs) do
			assert(expected[class], "an unexpected class buff snuck in for " .. class)
		end

		for class in pairs(expected) do
			assert(classBuffs[class], "the " .. class .. " class buff went missing")
		end
	end)
end)
