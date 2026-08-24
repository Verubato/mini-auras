-- Enemy kick tracker: the observer watches the arena team's cast events and the display turns
-- each confirmed interrupt into a timed icon. The wiring between the two is what these cover -
-- an interrupt that produces no icon, or one cast producing several, is invisible in game until
-- someone is watching the bar during a match.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db

-- The player's own spec drives IsEnabledForPlayer; Always sidesteps it for most of these.
local options = db.Modules.EnemyKickTracker
options.Enabled.Always = true

env.loadModule("src/Modules/EnemyKickTracker/Observer.lua")
env.loadModule("src/Modules/EnemyKickTracker/Display.lua")
env.loadModule("src/Modules/EnemyKickTracker/Module.lua")

local module = assert(env.addon.Modules.EnemyKickTrackerModule, "module registered")
local display = assert(env.addon.Modules.EnemyKickTracker.Display, "display registered")

env.inInstance = true
env.instanceType = "arena"
env.invalidateWorldState()

module:Init()

-- The module hears no world event of its own any more: entering an arena reaches it as the
-- addon-wide Refresh that PLAYER_ENTERING_WORLD drives.
local function enterWorld()
	module:Refresh()
end

---The frame the observer registered the given unit's cast events on. RegisterUnitEvent records
---the token as the event's value, so the registration itself identifies the frame.
local function castFrameFor(unit)
	for i = #acm.frames, 1, -1 do
		local frame = acm.frames[i]
		if frame._events and frame._events.UNIT_SPELLCAST_INTERRUPTED == unit then
			return frame
		end
	end
end

---Icons currently on the bar. The container hides every slot frame it is not using, so the shown
---ones are exactly the live kicks.
local function usedSlots()
	local count = 0
	for _, frame in ipairs(acm.frames) do
		if frame._name and frame._name:match("^MiniAuras_Slot_") and frame:IsShown() then
			count = count + 1
		end
	end
	return count
end

fw.describe("EnemyKickTracker - arena gating", function()
	fw.it("registers the arena team's cast events on entering an arena", function()
		enterWorld()

		for _, unit in ipairs({ "player", "party1", "party2" }) do
			assert(castFrameFor(unit), "no cast frame watching " .. unit)
		end
	end)

	fw.it("drops them again outside an arena", function()
		local frame = castFrameFor("player")
		env.inInstance = false
		env.instanceType = "none"
		env.invalidateWorldState()
		enterWorld()

		assert(not frame._events.UNIT_SPELLCAST_INTERRUPTED, "cast events must not stay live in the world")

		env.inInstance = true
		env.instanceType = "arena"
		env.invalidateWorldState()
		enterWorld()
		assert(castFrameFor("player"), "and come back on re-entry")
	end)
end)

fw.describe("EnemyKickTracker - interrupt to icon", function()
	local function castFrame()
		return assert(castFrameFor("player"), "player cast frame")
	end

	fw.before_each(function()
		module:Refresh()
		display:Clear()
	end)

	fw.it("an interrupted cast puts one icon on the bar", function()
		local frame = castFrame()
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")

		local before = usedSlots()
		-- arg 4 is interruptedBy; without it this is an ordinary cast ending.
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-1", 0, "arena1")
		assert(usedSlots() == before + 1, "expected one icon, got " .. (usedSlots() - before))
	end)

	fw.it("the repeat events for the same cast do not stack more icons", function()
		local frame = castFrame()
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-2", 0, "arena1")

		local after = usedSlots()
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-2", 0, "arena1")
		frame:TriggerEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "cast-2", 0, "arena1")
		assert(usedSlots() == after, "one cast must only ever produce one icon")
	end)

	fw.it("a cast that simply finished is not an interrupt", function()
		local frame = castFrame()
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")

		local before = usedSlots()
		-- No interruptedBy: the cast ran to completion, or the channel ended normally.
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-3", 0, nil)
		frame:TriggerEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "cast-3", 0, nil)
		assert(usedSlots() == before, "a clean cast end must not draw a kick")
	end)

	fw.it("an ally being interrupted counts too", function()
		local frame = assert(castFrameFor("party2"), "party2 cast frame")
		frame:TriggerEvent("UNIT_SPELLCAST_START", "party2")

		local before = usedSlots()
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "party2", "cast-4", 0, "arena2")
		assert(usedSlots() == before + 1, "the whole arena team is watched, not just the player")
	end)
end)

fw.describe("EnemyKickTracker - lifecycle", function()
	fw.it("test mode fills the bar and leaving it empties the bar again", function()
		display:Clear()
		local before = usedSlots()

		module:StartTesting()
		assert(usedSlots() > before, "test mode previews some kicks")

		module:StopTesting()
		assert(usedSlots() == before, "and clears them on the way out")
	end)

	fw.it("test mode swallows live interrupts rather than mixing them in", function()
		module:StartTesting()
		local preview = usedSlots()

		local frame = assert(castFrameFor("player"), "player cast frame")
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-5", 0, "arena1")
		assert(usedSlots() == preview, "a real kick must not land on top of the preview")

		module:StopTesting()
	end)

	fw.it("switching every spec toggle off tears the bar down", function()
		local frame = assert(castFrameFor("player"), "player cast frame")
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-6", 0, "arena1")
		assert(usedSlots() > 0, "something on the bar to tear down")

		options.Enabled.Always = false
		options.Enabled.Caster = false
		options.Enabled.Healer = false
		module:Refresh()
		assert(usedSlots() == 0, "the icons went with it")
		assert(not frame._events.UNIT_SPELLCAST_INTERRUPTED, "and the events were unregistered")

		options.Enabled.Always = true
		module:Refresh()
		assert(castFrameFor("player"), "re-enabling brings the events back")
	end)

	fw.it("reported no misuse through the whole run", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
