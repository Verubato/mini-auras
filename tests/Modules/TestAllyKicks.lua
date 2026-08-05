-- Team Kick Tracker: the roster it builds, the casts it credits, and the order it puts the bars
-- in. Each area is a silent-failure class:
--
--   * The roster decides who gets a bar at all. A spec with no interrupt must not produce one,
--     and the player must not appear twice when a raid roster carries them under a raid token.
--   * Cast credit runs through unit-filtered UNIT_SPELLCAST_SUCCEEDED, including the pet token
--     that a Warlock's Spell Lock arrives on. Miss that and the bar never counts down.
--   * Sorting by readiness is the whole point of the display, and "hide when all ready" must
--     not hide a bar that is still counting down.

local fw = require("Framework")
local wow = require("WowApi")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local addon = env.addon
local options = db.Modules.AllyKickTrackerModule

-- Spec IDs the tracker resolves each unit to; a unit missing here falls back to its class.
local specByUnit = {}
-- Units that UnitIsUnit should treat as the local player, so a raid token can alias them.
local playerAliases = { player = true }

addon.Core.InspectorFacade = {
	GetUnitSpecId = function(_, unit)
		return specByUnit[unit]
	end,
}
addon.Core.Inspector = {
	Init = function() end,
	RegisterCallback = function() end,
}

_G.UnitIsUnit = function(a, b)
	if a == b then
		return true
	end

	return b == "player" and playerAliases[a] == true
end

env.loadModule("src/Core/Kicks/KickData.lua")
env.loadModule("src/Core/Display/BarTextures.lua")
env.loadModule("src/Modules/AllyKicks/Tracker.lua")
env.loadModule("src/Modules/AllyKicks/Display.lua")
env.loadModule("src/Modules/AllyKicks/Module.lua")

local module = addon.Modules.AllyKickTrackerModule
local tracker = addon.Modules.AllyKicks.Tracker

env.setModuleEnabled("AllyKickTrackerModule", true)
options.HideWhenReady = false
options.SortByReadiness = true
options.ExcludePlayer = false

module:Init()

-- The display's root is the only frame the module makes draggable.
local root
for _, frame in ipairs(acm.frames) do
	if frame._scripts and frame._scripts.OnDragStop then
		root = frame
		break
	end
end
assert(root, "the bar list has a draggable anchor")

-- The module's own event frame, which is what combat state arrives on.
local moduleEvents = assert(acm.lastFrameForEvent("PLAYER_REGEN_DISABLED"), "module event frame")

local SPEC = {
	ElementalShaman = 262,
	RestoShaman = 264,
	FireMage = 63,
	HolyPriest = 257,
	Assassination = 259,
	Arms = 71,
	Affliction = 265,
}

local SPELL = {
	WindShear = 57994,
	Counterspell = 2139,
	Kick = 1766,
	SpellLock = 132409,
	SkullBash = 106839,
	Frostbolt = 116,
}

---Puts a roster in place and rebuilds the module against it.
---@param members table[]  { Unit, Class, Spec }
local function SetRoster(members)
	wipe(env.friendlyUnits)
	wipe(specByUnit)

	for _, member in ipairs(members) do
		env.friendlyUnits[#env.friendlyUnits + 1] = member.Unit
		specByUnit[member.Unit] = member.Spec
		wow.setUnitClass(member.Unit, member.Class)
	end

	module:Refresh()
end

local function ClearCooldowns()
	tracker:ClearCooldowns()
	module:Refresh()
end

---The frame carrying the cast registration that covers this unit.
---@param unit string
---@return table?
local function CastFrameFor(unit)
	for _, frame in ipairs(acm.frames) do
		local registered = frame._eventUnits and frame._eventUnits.UNIT_SPELLCAST_SUCCEEDED

		if registered and (registered[1] == unit or registered[2] == unit) then
			return frame
		end
	end
end

---@param unit string  the token the cast arrives on, which is the pet's for Spell Lock
---@param spellId number
local function Cast(unit, spellId)
	local frame = assert(CastFrameFor(unit), "no cast registration covering " .. unit)

	frame:TriggerEvent("UNIT_SPELLCAST_SUCCEEDED", unit, "cast-1", spellId)
end

---The names on the visible bars, in the order they are stacked.
---@return string[]
local function BarNames()
	local names = {}

	for _, frame in ipairs(acm.frames) do
		if frame._type == "StatusBar" and frame:IsVisible() then
			local nameText = frame._createdFontStrings[1]
			local args = nameText and nameText._lastArgs.SetText

			names[#names + 1] = args and args[1]
		end
	end

	return names
end

---The frame driving the repaint loop, which only carries a script while it is running.
---@return table?
local function TickFrame()
	for _, frame in ipairs(acm.frames) do
		if frame._scripts and frame._scripts.OnUpdate then
			return frame
		end
	end
end

---@param unit string
---@return AllyKickEntry?
local function EntryFor(unit)
	for _, entry in ipairs(tracker:GetEntries()) do
		if entry.Unit == unit then
			return entry
		end
	end
end

fw.describe("AllyKicks - roster", function()
	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
	end)

	fw.it("tracks only group members whose spec has an interrupt", function()
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
			{ Unit = "party2", Class = "PRIEST", Spec = SPEC.HolyPriest },
		})

		assert(#tracker:GetEntries() == 2, "the healer with no interrupt gets no entry")
		assert(EntryFor("player") and EntryFor("party1"), "both interrupters are tracked")
		assert(EntryFor("player").SpellId == SPELL.WindShear, "the spec's own interrupt is used")
	end)

	fw.it("falls back to the class interrupt while a spec is unknown", function()
		SetRoster({ { Unit = "party1", Class = "ROGUE" } })

		local entry = assert(EntryFor("party1"), "an unknown spec still gets a bar")
		assert(entry.SpellId == SPELL.Kick, "the class fallback names the interrupt")
		assert(entry.Cooldown == 15, "and carries a cooldown to count down from")
	end)

	fw.it("does not track the player twice from a raid roster", function()
		playerAliases = { player = true, raid1 = true }

		SetRoster({
			{ Unit = "raid1", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "raid2", Class = "MAGE", Spec = SPEC.FireMage },
		})

		assert(#tracker:GetEntries() == 2, "one entry each, not three")
	end)

	fw.it("drops the player's own bar when they are excluded", function()
		options.ExcludePlayer = true

		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
		})

		assert(#tracker:GetEntries() == 1 and EntryFor("party1"), "only the teammate is tracked")

		options.ExcludePlayer = false
	end)

	fw.it("keeps a running cooldown across a roster change", function()
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
		})

		Cast("party1", SPELL.Counterspell)
		local startedAt = EntryFor("party1").StartTime

		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
			{ Unit = "party2", Class = "ROGUE", Spec = SPEC.Assassination },
		})

		assert(EntryFor("party1").StartTime == startedAt, "a new member must not reset the others")
	end)
end)

fw.describe("AllyKicks - unresolved specs", function()
	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
	end)

	fw.it("watches a member it cannot name an interrupt for", function()
		-- A Druid with no spec resolved: the class alone never says which interrupt they have,
		-- since Balance kicks with Solar Beam and Restoration not at all.
		SetRoster({ { Unit = "party1", Class = "DRUID" } })

		assert(#tracker:GetEntries() == 0, "no bar until there is something to put on it")
		assert(tracker:IsWatched("party1"), "but their casts are still listened for")
	end)

	fw.it("adds the bar the moment they press it", function()
		SetRoster({ { Unit = "party1", Class = "DRUID" } })

		Cast("party1", SPELL.SkullBash)

		local entry = assert(EntryFor("party1"), "the cast is proof enough")
		assert(entry.SpellId == SPELL.SkullBash, "tracking what they actually pressed")
		assert(entry.StartTime == 1000, "and it goes straight onto cooldown")
		assert(entry.Cooldown == 15, "with Skull Bash's cooldown")
	end)

	fw.it("credits a pet cast from an owner with no bar yet", function()
		SetRoster({ { Unit = "party1", Class = "WARLOCK" } })
		wipe(specByUnit)
		module:Refresh()

		Cast("partypet1", SPELL.SpellLock)

		assert(EntryFor("party1"), "the felhunter's cast belongs to its owner")
	end)

	fw.it("still ignores casts from outside the group", function()
		SetRoster({ { Unit = "party1", Class = "DRUID" } })

		local frame = assert(CastFrameFor("party1"), "a watcher exists")
		frame:TriggerEvent("UNIT_SPELLCAST_SUCCEEDED", "party4", "cast-9", SPELL.Kick)

		assert(EntryFor("party4") == nil, "an unwatched unit gets no bar")
	end)
end)

fw.describe("AllyKicks - cast credit", function()
	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
			{ Unit = "party2", Class = "WARLOCK", Spec = SPEC.Affliction },
		})
		-- A cooldown deliberately survives a roster rebuild, so it has to be cleared by hand
		-- for each case to start from everything ready.
		ClearCooldowns()
	end)

	fw.it("starts the cooldown when a tracked member interrupts", function()
		Cast("party1", SPELL.Counterspell)

		local entry = EntryFor("party1")
		assert(entry.StartTime == 1000, "the cooldown starts now")
		assert((entry.Duration or entry.Cooldown) == 20, "for the spec's cooldown")
	end)

	fw.it("ignores casts that are not interrupts", function()
		Cast("party1", SPELL.Frostbolt)

		assert(EntryFor("party1").StartTime == 0, "a filler cast leaves the bar ready")
	end)

	fw.it("credits a pet-cast interrupt to its owner", function()
		Cast("partypet2", SPELL.SpellLock)

		assert(EntryFor("party2").StartTime == 1000, "Spell Lock arrives on the pet, not the caster")
	end)

	fw.it("clears every cooldown on request", function()
		Cast("party1", SPELL.Counterspell)
		tracker:ClearCooldowns()

		assert(EntryFor("party1").StartTime == 0, "a fresh match starts with everything up")
	end)
end)

fw.describe("AllyKicks - secret spell ids", function()
	---@param unit string  the unit whose cast was cut short
	---@param interruptedBy string?  GUID of the interrupter
	local function Interrupted(unit, interruptedBy)
		local frame = assert(acm.lastFrameForEvent("UNIT_SPELLCAST_INTERRUPTED"), "interrupt watcher")

		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", unit, "cast-3", 12345, interruptedBy)
	end

	---A cast whose spell id the client refuses to let us read, which is every group member's on 12.1.
	---@param unit string
	local function SecretCast(unit)
		local frame = assert(CastFrameFor(unit), "no cast registration covering " .. unit)

		frame:TriggerEvent("UNIT_SPELLCAST_SUCCEEDED", unit, "cast-3", wow.markSecret({}))
	end

	---A second interrupter, so the ambiguity being tested is between allies. The local player is
	---never guessed at: their own casts are readable, so their kicks are known outright.
	local function TwoAllies()
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
			{ Unit = "party2", Class = "ROGUE", Spec = SPEC.Assassination },
		})
		ClearCooldowns()
	end

	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
		wipe(env.enemies)
		wipe(env.unitTokens)
		env.enemies.nameplate1 = true
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
		})
		ClearCooldowns()
	end)

	fw.it("survives a cast id it is not allowed to read", function()
		SecretCast("party1")

		assert(EntryFor("party1").StartTime == 0, "a cast alone says nothing - it may not be a kick")
	end)

	fw.it("starts the cooldown when an interrupt names the caster", function()
		env.unitTokens["guid-party1"] = "party1"

		Interrupted("nameplate1", "guid-party1")

		local entry = EntryFor("party1")
		assert(entry.StartTime == 1000, "the interrupter is read straight off the event")
		assert((entry.Duration or entry.Cooldown) == 20, "with their spec's cooldown")
	end)

	fw.it("falls back to elimination when the guid names nobody", function()
		Interrupted("nameplate1", "guid-unknown")

		assert(EntryFor("party1").StartTime == 1000, "the only ally who could have done it")
	end)

	fw.it("credits the only ally who could have done it", function()
		Interrupted("nameplate1", "guid-unknown")

		assert(EntryFor("party1").StartTime == 1000, "one ally with an interrupt up, so it was theirs")
	end)

	fw.it("ignores a cast that merely stopped rather than being interrupted", function()
		-- A channel running its course, or a cast its owner cancelled. These arrive constantly in
		-- a dungeon and carry no interrupter; treating them as kicks credited the group with one
		-- every couple of seconds.
		local frame = assert(acm.lastFrameForEvent("UNIT_SPELLCAST_CHANNEL_STOP"), "interrupt watcher")

		frame:TriggerEvent("UNIT_SPELLCAST_CHANNEL_STOP", "nameplate1", "cast-4", 12345, nil)

		assert(EntryFor("party1").StartTime == 0, "no interrupter, so nothing happened")
	end)

	fw.it("will not credit a member whose interrupt is still down", function()
		Interrupted("nameplate1", "guid-unknown")
		assert(EntryFor("party1").StartTime == 1000, "first one lands")

		-- They are no longer a candidate, so the next interrupt has to belong to somebody else.
		wow.advanceTime(5)
		Interrupted("nameplate1", "guid-unknown")

		assert(EntryFor("party1").StartTime == 1000, "the running cooldown is not restarted")
	end)

	fw.it("does not credit an ally for the player's own kick", function()
		-- The interrupt arrives right behind the player's cast, and the client repeats it under
		-- every token the mob holds. Each repeat used to be taken as a fresh kick to guess at.
		wow.advanceTime(30)
		Cast("player", SPELL.WindShear)

		Interrupted("nameplate1", "guid-unknown")
		Interrupted("target", "guid-unknown")

		assert(EntryFor("player").StartTime > 0, "the player's own kick still counts down")
		assert(EntryFor("party1").StartTime == 0, "and the ally who cast nearby is left alone")
	end)

	fw.it("guesses at nobody when two allies could have done it", function()
		TwoAllies()

		Interrupted("nameplate1", "guid-unknown")

		assert(EntryFor("party1").StartTime == 0 and EntryFor("party2").StartTime == 0,
			"either of them could have done it, so neither is credited")
	end)

	fw.it("does not guess when a cooldown just started", function()
		wow.advanceTime(30)
		Cast("player", SPELL.WindShear)

		-- The same kick reported twice, not a second one from somebody else.
		Interrupted("nameplate1", "guid-unknown")

		assert(EntryFor("party1").StartTime == 0, "the mage is not credited for the player's kick")
	end)

	fw.it("does not double-start the local player's own cooldown", function()
		env.unitTokens["guid-player"] = "player"

		Cast("player", SPELL.WindShear)
		local started = EntryFor("player").StartTime

		wow.advanceTime(0.1)
		Interrupted("nameplate1", "guid-player")

		assert(EntryFor("player").StartTime == started, "the interrupt is the same kick reported twice")
	end)
end)

fw.describe("AllyKicks - raid markers", function()
	---The tracker's own interrupt watcher, which listens for any unit's cast being cut short.
	---@return table
	local function InterruptFrame()
		return assert(acm.lastFrameForEvent("UNIT_SPELLCAST_INTERRUPTED"), "interrupt watcher")
	end

	---@param unit string  the unit whose cast was interrupted
	local function Interrupted(unit)
		-- A real interrupt always carries an interrupter; without one the event is just a cast
		-- that stopped, which the tracker ignores. This GUID names nobody, so the marker is
		-- tested on its own rather than alongside an attribution.
		InterruptFrame():TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", unit, "cast-2", 12345, "guid-nobody")
	end

	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
		wipe(env.raidTargets)
		wipe(env.enemies)
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
		})
		ClearCooldowns()
	end)

	fw.it("marks the cooldown when the interrupt lands after the cast", function()
		env.enemies.nameplate1 = true
		env.raidTargets.nameplate1 = 8

		Cast("party1", SPELL.Counterspell)
		Interrupted("nameplate1")

		assert(EntryFor("party1").Marker == 8, "the skull the mage kicked")
		assert(EntryFor("player").Marker == nil, "and nobody else's bar takes it")
	end)

	fw.it("marks a cooldown the interrupt itself started", function()
		env.enemies.nameplate1 = true
		env.raidTargets.nameplate1 = 3

		-- No cast to go on, so the interrupt is attributed by elimination and the marker has to
		-- reach the bar that attribution just created.
		Interrupted("nameplate1")

		assert(EntryFor("party1").Marker == 3, "the marker lands on the bar it started")
	end)

	fw.it("ignores an interrupt landing on an ally", function()
		env.raidTargets.party2 = 5

		Cast("party1", SPELL.Counterspell)
		Interrupted("party2")

		assert(EntryFor("party1").Marker == nil, "an ally being kicked is not our doing")
	end)

	fw.it("ignores a marker that arrives too late to be the same interrupt", function()
		env.enemies.nameplate1 = true
		env.raidTargets.nameplate1 = 2

		Cast("party1", SPELL.Counterspell)
		wow.advanceTime(3)
		Interrupted("nameplate1")

		assert(EntryFor("party1").Marker == nil, "three seconds later is a different fight")
	end)

	fw.it("drops the old marker when the interrupt is pressed again", function()
		env.enemies.nameplate1 = true
		env.raidTargets.nameplate1 = 8

		Cast("party1", SPELL.Counterspell)
		Interrupted("nameplate1")
		assert(EntryFor("party1").Marker == 8)

		wow.advanceTime(30)
		Cast("party1", SPELL.Counterspell)

		assert(EntryFor("party1").Marker == nil, "a new press with no marker shows none")
	end)
end)

fw.describe("AllyKicks - the player's own cooldown", function()
	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
		-- Each case installs its own; the default client has none of these problems.
		_G.C_Spell.GetSpellCooldown = nil
		SetRoster({ { Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman } })
		ClearCooldowns()
	end)

	fw.it("uses the client's exact cooldown when it is readable", function()
		_G.C_Spell.GetSpellCooldown = function()
			return { startTime = 990, duration = 9, isEnabled = true }
		end

		Cast("player", SPELL.WindShear)

		local entry = EntryFor("player")
		assert(entry.StartTime == 990, "the real start time wins over now")
		assert(entry.Duration == 9, "as does the real, talent-aware duration")
	end)

	fw.it("falls back to the spec cooldown when the client returns secrets", function()
		-- 12.1 hands these back as secret numbers: readable, but comparing or adding to one is a
		-- Lua error, which used to take the whole cast handler down with it.
		_G.C_Spell.GetSpellCooldown = function()
			return {
				startTime = wow.markSecret({}),
				duration = wow.markSecret({}),
				isEnabled = true,
			}
		end

		Cast("player", SPELL.WindShear)

		local entry = EntryFor("player")
		assert(entry.StartTime == 1000, "the cooldown still starts, timed from the cast")
		assert(entry.Duration == 12, "using Wind Shear's cooldown from the spec data")
	end)

	fw.it("falls back when the client reports a global cooldown instead", function()
		_G.C_Spell.GetSpellCooldown = function()
			return { startTime = 999, duration = 1.5, isEnabled = true }
		end

		Cast("player", SPELL.WindShear)

		assert(EntryFor("player").Duration == 12, "1.5s is the GCD, not the interrupt")
	end)
end)

fw.describe("AllyKicks - display", function()
	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
		options.HideWhenReady = false
		options.SortByReadiness = true
		options.MaxBars = 5
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
			{ Unit = "party2", Class = "ROGUE", Spec = SPEC.Assassination },
		})
		ClearCooldowns()
	end)

	fw.it("puts ready interrupts first and the longest wait last", function()
		-- Counterspell is 20s and Kick is 15s, so casting the rogue's second still leaves it
		-- ready sooner than the mage's.
		Cast("party1", SPELL.Counterspell)
		Cast("party2", SPELL.Kick)
		module:Refresh()

		local names = BarNames()
		assert(#names == 3, "three bars, got " .. #names)
		assert(names[1] == "player", "the ready interrupt leads, got " .. tostring(names[1]))
		assert(names[2] == "party2", "then the shorter cooldown, got " .. tostring(names[2]))
		assert(names[3] == "party1", "then the longer one, got " .. tostring(names[3]))
	end)

	fw.it("keeps group order when sorting is off", function()
		options.SortByReadiness = false
		Cast("player", SPELL.WindShear)
		module:Refresh()

		local names = BarNames()
		assert(names[1] == "player", "the player stays first despite being on cooldown")
	end)

	fw.it("caps the bars at the configured maximum", function()
		options.MaxBars = 2
		module:Refresh()

		assert(#BarNames() == 2, "a raid-sized roster must not become a wall of bars")
	end)

	fw.it("hides the bars out of combat when asked to", function()
		options.HideOutOfCombat = true
		moduleEvents:TriggerEvent("PLAYER_REGEN_ENABLED")
		assert(not root:IsShown(), "out of combat, so nothing on screen")

		moduleEvents:TriggerEvent("PLAYER_REGEN_DISABLED")
		assert(root:IsShown(), "combat brings them back")

		-- Out-of-combat hiding wins: a cooldown running as the fight ends still goes away.
		Cast("party1", SPELL.Counterspell)
		moduleEvents:TriggerEvent("PLAYER_REGEN_ENABLED")
		assert(not root:IsShown(), "and dropping combat hides them again")

		options.HideOutOfCombat = false
		moduleEvents:TriggerEvent("PLAYER_REGEN_DISABLED")
		module:Refresh()
	end)

	fw.it("hides each bar whose interrupt is ready when asked to", function()
		options.HideWhenReady = true
		module:Refresh()
		assert(#BarNames() == 0, "everything is ready, so there is nothing to show")
		assert(not root:IsShown(), "and the list goes with it")

		Cast("party1", SPELL.Counterspell)

		local names = BarNames()
		assert(#names == 1 and names[1] == "party1", "only the member on cooldown is listed")
		assert(root:IsShown(), "a running cooldown brings the list back")
	end)

	fw.it("drops a bar from the list as its cooldown ends", function()
		options.HideWhenReady = true
		Cast("party1", SPELL.Counterspell)
		assert(#BarNames() == 1, "on cooldown, so listed")

		local frame = assert(TickFrame(), "the repaint loop is running")
		wow.advanceTime(60)
		frame._scripts.OnUpdate(frame, 0.05)

		assert(#BarNames() == 0, "back up, so gone from the list")
	end)

	fw.it("hides everything while the module is disabled", function()
		env.setModuleEnabled("AllyKickTrackerModule", false)
		module:Refresh()

		assert(not root:IsShown(), "a disabled module draws nothing")
		assert(#BarNames() == 0, "and leaves no bars behind")

		env.setModuleEnabled("AllyKickTrackerModule", true)
		module:Refresh()
	end)

	fw.it("colours the fill by class and leaves the name white", function()
		Cast("party1", SPELL.Counterspell)
		module:Refresh()

		local mage = _G.RAID_CLASS_COLORS.MAGE

		for _, frame in ipairs(acm.frames) do
			if frame._type == "StatusBar" and frame:IsVisible() then
				local name = frame._createdFontStrings[1]
				local shown = name._lastArgs.SetText and name._lastArgs.SetText[1]

				if shown == "party1" then
					-- Full strength even while it counts down: nothing about the colour says
					-- unavailable, only how much of the bar is left.
					assert(frame._color[1] == mage.r and frame._color[2] == mage.g,
						"the mage's bar is the mage colour")
					assert(name._lastArgs.SetTextColor[1] == 1, "and the name stays white")
					return
				end
			end
		end

		error("no bar found for the mage")
	end)

	fw.it("stays draggable without test mode", function()
		assert(root:IsMovable(), "the bars can be repositioned as they are")
		assert(root._mouseEnabled, "and take the mouse to do it")
		assert(root._scripts.OnDragStop, "with the move saved when it is dropped")
	end)

	fw.it("locking hands the mouse back", function()
		options.Locked = true
		module:Refresh()

		assert(not root:IsMovable(), "a locked bar cannot be dragged")
		assert(not root._mouseEnabled, "and clicks pass through to whatever is behind it")

		options.Locked = false
		module:Refresh()
		assert(root:IsMovable(), "unlocking gives it back")
	end)

	fw.it("shows a preview roster in test mode", function()
		module:StartTesting()
		assert(#BarNames() == 3, "test mode previews every state at once")
		assert(root:IsShown(), "and keeps the anchor up to be dragged")

		module:StopTesting()
		assert(#tracker:GetEntries() > 0, "the live roster comes back afterwards")
	end)
end)

fw.describe("AllyKicks - refresh loop", function()
	---@param frame table
	---@param ticks number
	local function Tick(frame, ticks)
		for _ = 1, ticks do
			wow.advanceTime(0.05)
			frame._scripts.OnUpdate(frame, 0.05)
		end
	end

	---The name and countdown font strings of every visible bar.
	---@return table[]
	local function BarText()
		local rows = {}

		for _, frame in ipairs(acm.frames) do
			if frame._type == "StatusBar" and frame:IsVisible() then
				rows[#rows + 1] = {
					Name = frame._createdFontStrings[1],
					Countdown = frame._createdFontStrings[2],
					Icon = frame._parent._createdTextures[1],
				}
			end
		end

		return rows
	end

	fw.before_each(function()
		wow.setTime(1000)
		playerAliases = { player = true }
		options.HideWhenReady = false
		SetRoster({
			{ Unit = "player", Class = "SHAMAN", Spec = SPEC.ElementalShaman },
			{ Unit = "party1", Class = "MAGE", Spec = SPEC.FireMage },
		})
		ClearCooldowns()
	end)

	fw.it("only touches what actually moved on each repaint", function()
		Cast("party1", SPELL.Counterspell)

		local frame = assert(TickFrame(), "a cast starts the repaint loop")
		local before = {}

		for index, row in ipairs(BarText()) do
			before[index] = {
				Name = row.Name._calls.SetText or 0,
				Countdown = row.Countdown._calls.SetText or 0,
				Icon = row.Icon._calls.SetTexture or 0,
			}
		end

		-- A second of ticking at 20 fps: 20 repaints, one whole-second boundary.
		Tick(frame, 20)

		for index, row in ipairs(BarText()) do
			assert((row.Name._calls.SetText or 0) == before[index].Name, "names must not be rewritten")
			assert((row.Icon._calls.SetTexture or 0) == before[index].Icon, "icons must not be reapplied")

			local countdowns = (row.Countdown._calls.SetText or 0) - before[index].Countdown
			assert(countdowns <= 2, "countdown rewritten " .. countdowns .. " times in a second")
		end
	end)

	fw.it("stops once every interrupt is back", function()
		Cast("party1", SPELL.Counterspell)

		local frame = assert(TickFrame(), "the loop is running")

		wow.advanceTime(60)
		frame._scripts.OnUpdate(frame, 0.05)

		assert(frame._scripts.OnUpdate == nil, "nothing left to animate, so no per-frame script")
	end)

	fw.it("comes back for the next cast", function()
		Cast("party1", SPELL.Counterspell)

		local frame = assert(TickFrame(), "the loop is running")
		wow.advanceTime(60)
		frame._scripts.OnUpdate(frame, 0.05)

		Cast("player", SPELL.WindShear)
		assert(TickFrame(), "a later cast restarts it")
	end)
end)

-- Left until last: a learned cooldown deliberately outlives ClearCooldowns and roster rebuilds,
-- so each case gets its own member and nothing after this measures a mage whose Counterspell
-- has been trimmed.
fw.describe("AllyKicks - cooldown learning", function()
	---@param unit string
	local function LoneMage(unit)
		wow.setTime(1000)
		playerAliases = { player = true }
		SetRoster({ { Unit = unit, Class = "MAGE", Spec = SPEC.FireMage } })
		ClearCooldowns()
	end

	fw.it("shortens the estimate when a member presses it again early", function()
		LoneMage("party1")

		Cast("party1", SPELL.Counterspell)
		wow.setTime(1012)
		Cast("party1", SPELL.Counterspell)

		local entry = EntryFor("party1")
		assert(entry.Cooldown == 12, "a talent-trimmed cooldown is learned, got " .. entry.Cooldown)
		assert(entry.BaseCooldown == 20, "and the book value is kept to bound it")
	end)

	fw.it("ignores a gap too short to be a real cooldown", function()
		LoneMage("party2")

		Cast("party2", SPELL.Counterspell)
		wow.setTime(1005)
		Cast("party2", SPELL.Counterspell)

		-- 5s of a 20s interrupt is a cast we missed, not a cooldown we had wrong.
		assert(EntryFor("party2").Cooldown == 20, "the estimate holds")
	end)

	fw.it("never lets the estimate grow back", function()
		LoneMage("party3")

		Cast("party3", SPELL.Counterspell)
		wow.setTime(1012)
		Cast("party3", SPELL.Counterspell)
		wow.setTime(1040)
		Cast("party3", SPELL.Counterspell)

		assert(EntryFor("party3").Cooldown == 12, "a late press says nothing about the cooldown")
	end)
end)
