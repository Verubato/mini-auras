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

addon.Core.InspectorFacade = {
	GetUnitSpecId = function()
		return nil
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

env.setModuleEnabled("AllyKickTrackerModule", true)
options.MaxBars = 5
options.RecordDuration = 15
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

local function Reset()
	wow.setTime(1000)
	wipe(env.enemies)
	wipe(env.raidTargets)
	wipe(env.unitNames)
	wipe(env.unitClasses)
	env.enemies.nameplate1 = true
	env.enemies.nameplate2 = true
	options.MaxBars = 5
	options.RecordDuration = 15
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

		Advance(options.RecordDuration + 1)

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

	fw.it("honours the configured lifetime", function()
		options.RecordDuration = 5
		module:Refresh()

		Interrupted("nameplate1")
		Advance(6)

		assert(#VisibleBars() == 0, "a shorter lifetime drops the row sooner")
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

fw.describe("AllyKicks - reporting", function()
	fw.before_each(Reset)

	fw.it("diagnoses without reading anything it may not", function()
		-- Diagnose prints a summary; with a secret name in the list, formatting one into the
		-- output would throw. It must report the timings only.
		Interrupted("nameplate1")

		wipe(env.notifications)
		module:Diagnose()

		assert(#env.notifications > 0, "it said something")
	end)

	fw.it("toggles the interrupt log", function()
		assert(module:ToggleDebug() == true, "on")
		assert(module:ToggleDebug() == false, "and off again")
	end)
end)
