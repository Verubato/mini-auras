-- Ally Kick Tracker: the interrupts it records and the rows it draws from them. Each area is a
-- silent-failure class:
--
--   * Nothing about the interrupter can be read on 12.1 - the GUID, the name it resolves to, the
--     class and the interrupted spell are all secret. Reading, comparing or keying a table by one
--     is a Lua error that takes the whole handler down, so the tests feed secrets in deliberately
--     and assert the row still gets drawn.
--   * The client repeats one interrupt under several tokens. Miss the dedup and one kick becomes
--     a screenful of rows.
--   * A cast that merely ended fires the same events with no interrupter. Treat one as a kick and
--     the list fills up on its own in any dungeon.

local fw = require("Framework")
local wow = require("WowApi")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local addon = env.addon
local options = db.Modules.AllyKickTrackerModule

-- The spec the player resolves to, which decides whether they get an own row and which interrupt
-- it shows. Unresolved by default, so most of the file exercises the history rows alone.
local playerSpec

addon.Core.InspectorFacade = {
	GetUnitSpecId = function()
		return playerSpec
	end,
}
addon.Core.Inspector = {
	Init = function() end,
	RegisterCallback = function() end,
}

_G.UnitIsUnit = function(a, b)
	return a == b
end

env.loadModule("src/Core/Kicks/KickData.lua")
env.loadModule("src/Core/Display/BarTextures.lua")
env.loadModule("src/Modules/AllyKicks/Observer.lua")
env.loadModule("src/Modules/AllyKicks/Display.lua")
env.loadModule("src/Modules/AllyKicks/Module.lua")

local module = addon.Modules.AllyKickTrackerModule
local observer = addon.Modules.AllyKicks.Observer

-- Mirrors the observer's own constant, which is no longer an option.
local RECORD_DURATION = 15
local WIND_SHEAR = 57994
local ELEMENTAL_SHAMAN = 262

env.setModuleEnabled("AllyKickTrackerModule", true)
options.MaxBars = 5
options.ShowOwnCooldown = false
options.HideOutOfCombat = false

module:Init()

-- The display's root is the only frame the module makes draggable.
local root
for _, frame in ipairs(acm.frames) do
	if frame._scripts and frame._scripts.OnDragStop then
		root = frame
		break
	end
end
assert(root, "the row list has a draggable anchor")

-- The module's own event frame, which is what combat state arrives on.
local moduleEvents = assert(acm.lastFrameForEvent("PLAYER_REGEN_DISABLED"), "module event frame")

---The observer's watcher, which listens for any unit's cast being cut short.
---@return table
local function InterruptFrame()
	return assert(acm.lastFrameForEvent("UNIT_SPELLCAST_INTERRUPTED"), "interrupt watcher")
end

---Fires an interrupt on a unit. Defaults mirror a dungeon on 12.1, where every one of these
---arrives as a secret value.
---@param unit string
---@param overrides table?
local function Interrupted(unit, overrides)
	overrides = overrides or {}

	local guid = overrides.Guid or wow.markSecret({})
	local spellId = overrides.SpellId ~= nil and overrides.SpellId or wow.markSecret({})

	if overrides.Name ~= nil then
		env.unitNames[guid] = overrides.Name
	end

	if overrides.Class ~= nil then
		env.unitClasses[guid] = overrides.Class
	end

	if overrides.Marker ~= nil then
		env.raidTargets[unit] = overrides.Marker
	end

	InterruptFrame():TriggerEvent(overrides.Event or "UNIT_SPELLCAST_INTERRUPTED",
		unit, "cast-1", spellId, overrides.InterruptedBy ~= false and guid or nil)
end

---The status bars currently on screen, top row first.
---@return table[]
local function VisibleBars()
	local bars = {}

	for _, frame in ipairs(acm.frames) do
		if frame._type == "StatusBar" and frame:IsVisible() then
			bars[#bars + 1] = frame
		end
	end

	return bars
end

---What each visible row put on its name font string.
---@return any[]
local function RowNames()
	local names = {}

	for _, bar in ipairs(VisibleBars()) do
		local nameText = bar._createdFontStrings[1]
		local args = nameText and nameText._lastArgs.SetText

		names[#names + 1] = args and args[1]
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

---@param seconds number
local function Advance(seconds)
	wow.advanceTime(seconds)

	local frame = TickFrame()

	if frame then
		frame._scripts.OnUpdate(frame, seconds)
	end
end

---The observer's own-cast watcher, which listens to the player and their pet only.
---@return table
local function CastFrame()
	for _, frame in ipairs(acm.frames) do
		local units = frame._eventUnits and frame._eventUnits.UNIT_SPELLCAST_SUCCEEDED

		if units and units[1] == "player" then
			return frame
		end
	end

	error("no own-cast watcher")
end

---@param spellId number
local function Cast(spellId)
	CastFrame():TriggerEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", spellId)
end

local function Reset()
	wow.setTime(1000)
	playerSpec = nil
	wipe(env.enemies)
	wipe(env.raidTargets)
	wipe(env.unitNames)
	wipe(env.unitClasses)
	env.enemies.nameplate1 = true
	env.enemies.nameplate2 = true
	options.MaxBars = 5
	-- Off by default here so the history rows are the only thing under test; the own row
	-- has its own block below.
	options.ShowOwnCooldown = false
	options.HideOutOfCombat = false
	env.setModuleEnabled("AllyKickTrackerModule", true)
	observer:Clear()
	module:Refresh()
end

fw.describe("AllyKicks - recording", function()
	fw.before_each(Reset)

	fw.it("records an interrupt whose every field is secret", function()
		-- The whole point of the module on 12.1: nothing here can be read, and a row still lands.
		Interrupted("nameplate1")

		assert(#observer:GetRecords() == 1, "one interrupt, one row")
		assert(#VisibleBars() == 1, "and it is on screen")
	end)

	fw.it("ignores a cast that merely stopped rather than being interrupted", function()
		-- A channel running its course, or a cast its owner cancelled. These arrive constantly in
		-- a dungeon and carry no interrupter.
		Interrupted("nameplate1", { Event = "UNIT_SPELLCAST_CHANNEL_STOP", InterruptedBy = false })

		assert(#observer:GetRecords() == 0, "no interrupter, so nothing happened")
	end)

	fw.it("ignores an interrupt on a friendly unit", function()
		-- Allies get interrupted too, and their attacker's kick is not our group's.
		env.enemies.nameplate1 = false

		Interrupted("nameplate1")

		assert(#observer:GetRecords() == 0, "an enemy kicking our healer is not an ally kick")
	end)

	fw.it("ignores tokens that are not nameplates", function()
		-- The same kick arrives under the mob's nameplate, your target and your soft target. Only
		-- one token can be counted, and nothing shared between them is readable to tell them apart.
		env.enemies.target = true

		Interrupted("target")

		assert(#observer:GetRecords() == 0, "target is a repeat of the nameplate event")
	end)

	fw.it("collapses the repeats of one kick into a single row", function()
		Interrupted("nameplate1")
		Interrupted("nameplate1")
		Interrupted("nameplate1", { Event = "UNIT_SPELLCAST_CHANNEL_STOP" })

		assert(#observer:GetRecords() == 1, "one kick, however many times it is reported")
	end)

	fw.it("keeps two kicks on different mobs in the same instant", function()
		Interrupted("nameplate1")
		Interrupted("nameplate2")

		assert(#observer:GetRecords() == 2, "two mobs kicked at once is two interrupts")
	end)

	fw.it("records the same mob again once the repeat window has passed", function()
		Interrupted("nameplate1")
		wow.advanceTime(5)
		Interrupted("nameplate1")

		assert(#observer:GetRecords() == 2, "a second kick on the same mob is its own row")
	end)

	fw.it("clears the list on entering a new zone", function()
		Interrupted("nameplate1")
		assert(#observer:GetRecords() == 1, "recorded")

		moduleEvents:TriggerEvent("PLAYER_ENTERING_WORLD")

		assert(#observer:GetRecords() == 0, "last zone's kicks are not carried in")
		assert(#VisibleBars() == 0, "and the rows go with them")
	end)
end)

fw.describe("AllyKicks - drawing a secret kicker", function()
	fw.before_each(Reset)

	fw.it("draws the name it is not allowed to read", function()
		local name = wow.markSecret({})

		Interrupted("nameplate1", { Name = name })

		local shown = RowNames()
		assert(#shown == 1, "one row")
		assert(shown[1] == name, "the secret name is handed to SetText untouched")
	end)

	fw.it("colours the row from a class token it is not allowed to read", function()
		-- RAID_CLASS_COLORS cannot be indexed by a secret, so the colour has to come from the API
		-- call; what it returns is secret too, and only a setter may be given it.
		Interrupted("nameplate1", { Class = wow.markSecret({}) })

		local bar = VisibleBars()[1]
		assert(bar._color, "a colour was applied")
		assert(issecretvalue(bar._color[1]), "and it is the secret one the client handed back")
	end)

	fw.it("falls back to a neutral colour when the class did not resolve", function()
		Interrupted("nameplate1", { Class = false })

		local bar = VisibleBars()[1]
		assert(bar._color and not issecretvalue(bar._color[1]), "a readable neutral fill")
	end)

	fw.it("paints a raid marker whose index is secret", function()
		-- The FrameXML helper works the tex coords out arithmetically, which throws on a secret;
		-- the sprite-sheet setter takes the index straight to the C side instead.
		local marker = wow.markSecret({})

		Interrupted("nameplate1", { Marker = marker })

		local painted
		for _, frame in ipairs(acm.frames) do
			for _, texture in ipairs(frame._createdTextures or {}) do
				local args = texture._lastArgs.SetSpriteSheetCell

				if args and args[1] == marker then
					painted = true
				end
			end
		end

		assert(painted, "the secret marker index went to the sprite-sheet setter")
	end)

	fw.it("draws the interrupted spell's icon, secret or not", function()
		local icon = wow.markSecret({})

		env.unitNames["guid-1"] = "Thrall"
		_G.C_Spell.GetSpellTexture = function()
			return icon
		end

		Interrupted("nameplate1", { Guid = "guid-1" })

		local drawn
		for _, frame in ipairs(acm.frames) do
			for _, texture in ipairs(frame._createdTextures or {}) do
				local args = texture._lastArgs.SetTexture

				if args and args[1] == icon then
					drawn = true
				end
			end
		end

		assert(drawn, "the secret texture is handed to SetTexture untouched")
	end)
end)

fw.describe("AllyKicks - the list", function()
	fw.before_each(Reset)

	fw.it("puts the newest interrupt at the top", function()
		Interrupted("nameplate1", { Guid = "guid-a", Name = "First" })
		wow.advanceTime(1)
		Interrupted("nameplate2", { Guid = "guid-b", Name = "Second" })

		local names = RowNames()
		assert(names[1] == "Second", "newest first, got " .. tostring(names[1]))
		assert(names[2] == "First", "then the older one, got " .. tostring(names[2]))
	end)

	fw.it("caps the rows at the configured maximum", function()
		options.MaxBars = 2
		module:Refresh()

		for index = 1, 4 do
			Interrupted("nameplate1", { Guid = "guid-" .. index })
			wow.advanceTime(1)
		end

		assert(#VisibleBars() == 2, "a busy pull must not become a wall of rows")
	end)

	fw.it("drops a row once its lifetime is up", function()
		Interrupted("nameplate1")
		assert(#VisibleBars() == 1, "on screen")

		Advance(RECORD_DURATION + 1)

		assert(#VisibleBars() == 0, "gone once it expired")
		assert(not root:IsShown(), "and the list goes with it")
	end)

	fw.it("keeps the older rows when only the oldest expires", function()
		Interrupted("nameplate1", { Guid = "guid-a", Name = "Older" })
		wow.advanceTime(10)
		Interrupted("nameplate2", { Guid = "guid-b", Name = "Newer" })

		Advance(6)

		local names = RowNames()
		assert(#names == 1 and names[1] == "Newer", "only the expired row leaves")
	end)

	fw.it("hides the rows out of combat when asked to", function()
		Interrupted("nameplate1")
		options.HideOutOfCombat = true

		moduleEvents:TriggerEvent("PLAYER_REGEN_ENABLED")
		assert(not root:IsShown(), "out of combat, so nothing on screen")

		moduleEvents:TriggerEvent("PLAYER_REGEN_DISABLED")
		assert(root:IsShown(), "combat brings them back")
	end)

	fw.it("hides everything while the module is disabled", function()
		Interrupted("nameplate1")
		env.setModuleEnabled("AllyKickTrackerModule", false)
		module:Refresh()

		assert(not root:IsShown(), "a disabled module draws nothing")
		assert(#VisibleBars() == 0, "and leaves no rows behind")
		assert(not observer:IsWatching(), "and stops listening")

		env.setModuleEnabled("AllyKickTrackerModule", true)
		module:Refresh()
		assert(observer:IsWatching(), "enabling it starts the watcher again")
	end)

	fw.it("stops listening for interrupts while disabled", function()
		-- Unregistered rather than merely ignored: a disabled module costs nothing per event.
		env.setModuleEnabled("AllyKickTrackerModule", false)
		module:Refresh()

		assert(acm.lastFrameForEvent("UNIT_SPELLCAST_INTERRUPTED") == nil,
			"no frame is still registered for the interrupt event")
		assert(acm.lastFrameForEvent("UNIT_SPELLCAST_CHANNEL_STOP") == nil,
			"nor for the channel one")
	end)
end)

fw.describe("AllyKicks - the player's own row", function()
	fw.before_each(function()
		Reset()
		-- The player's own spec, class, interrupt and cooldown are all readable; theirs is the one
		-- row the client will actually answer for.
		playerSpec = ELEMENTAL_SHAMAN
		wow.setUnitClass("player", "SHAMAN")
		options.ShowOwnCooldown = true
		_G.C_Spell.GetSpellCooldown = nil
		module:Refresh()
	end)

	fw.it("shows a ready row before anything has happened", function()
		local bars = VisibleBars()
		assert(#bars == 1, "the own row is up from the start, got " .. #bars)

		local time = bars[1]._createdFontStrings[2]
		assert(time._lastArgs.SetText[1] == "Ready", "and it reads as ready")
	end)

	fw.it("counts down from the player's own cast", function()
		Cast(WIND_SHEAR)

		local time = VisibleBars()[1]._createdFontStrings[2]
		assert(time._lastArgs.SetText[1] == "12", "Wind Shear's 12s for Elemental")
	end)

	fw.it("uses the client's exact cooldown when it is readable", function()
		_G.C_Spell.GetSpellCooldown = function()
			return { startTime = 1000, duration = 9, isEnabled = true }
		end

		Cast(WIND_SHEAR)

		local time = VisibleBars()[1]._createdFontStrings[2]
		assert(time._lastArgs.SetText[1] == "9", "the real, talent-aware duration wins")
	end)

	fw.it("falls back to the spec cooldown when the client returns secrets", function()
		-- 12.1 hands these back as secret numbers: readable, but comparing or adding to one is an
		-- error that would take the cast handler down with it.
		_G.C_Spell.GetSpellCooldown = function()
			return {
				startTime = wow.markSecret({}),
				duration = wow.markSecret({}),
				isEnabled = true,
			}
		end

		Cast(WIND_SHEAR)

		local time = VisibleBars()[1]._createdFontStrings[2]
		assert(time._lastArgs.SetText[1] == "12", "the cooldown still runs, on the spec's number")
	end)

	fw.it("goes back to ready once the cooldown ends", function()
		Cast(WIND_SHEAR)
		Advance(13)

		local bars = VisibleBars()
		assert(#bars == 1, "the row stays put rather than expiring like a history one")

		local time = bars[1]._createdFontStrings[2]
		assert(time._lastArgs.SetText[1] == "Ready", "and reads as ready again")
	end)

	fw.it("sits above the interrupts that were recorded", function()
		Interrupted("nameplate1", { Guid = "guid-a", Name = "Someone" })

		local names = RowNames()
		assert(#names == 2, "own row plus the one recorded, got " .. #names)
		assert(names[1] == "player", "the player leads, got " .. tostring(names[1]))
		assert(names[2] == "Someone", "then the history, got " .. tostring(names[2]))
	end)

	fw.it("is left out when the option is off", function()
		options.ShowOwnCooldown = false
		module:Refresh()

		assert(#VisibleBars() == 0, "nothing recorded and no own row, so nothing on screen")
	end)

	fw.it("shows nothing for a spec with no interrupt", function()
		-- Holy Priest. A resolved spec with no interrupt is authoritative rather than guessed at.
		playerSpec = 257
		wow.setUnitClass("player", "PRIEST")
		module:Refresh()

		assert(#VisibleBars() == 0, "a healer has no interrupt to count down")
	end)

	fw.it("stops the repaint loop once it is ready again", function()
		Cast(WIND_SHEAR)
		assert(TickFrame(), "counting down, so the loop runs")

		Advance(13)

		assert(not TickFrame(), "a static ready row needs no repainting")
	end)
end)

fw.describe("AllyKicks - test mode", function()
	fw.before_each(function()
		Reset()
		module:StopTesting()
	end)

	fw.it("shows a readable preview whose rows do not expire", function()
		module:StartTesting()

		local names = RowNames()
		assert(#names == 3, "three preview rows, got " .. #names)

		for _, name in ipairs(names) do
			assert(name ~= nil and not issecretvalue(name), "the preview has to be readable")
		end

		-- Long enough that a real row would have gone.
		Advance(30)
		assert(#VisibleBars() == 3, "the preview stays put while it is being positioned")

		module:StopTesting()
	end)

	fw.it("returns to the real rows when it stops", function()
		module:StartTesting()
		module:StopTesting()

		assert(#VisibleBars() == 0, "nothing recorded, so nothing shown")
	end)
end)
