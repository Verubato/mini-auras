-- The unit frame hooks are installed once and outlive the module going dormant, so the icons come
-- back on the raid frames in a battleground it was switched off for.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
local acm = require("AuraContainerMock")

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("ImportantAuras", true)

local held = env.addUnitFrame("party1", "CUF_ZoneGate")

env.loadModule("src/Modules/ImportantAuras/Display.lua")
env.loadModule("src/Modules/ImportantAuras/Module.lua")

local module = env.addon.Modules.ImportantAurasModule

module:Init()

-- The stub answers no for every frame, so the hooks would turn them all away.
env.addon.Core.Frames.IsFriendlyCuf = function()
	return true
end

---@param instanceType string
---@param inInstance boolean
---@param isRaid boolean
---@param restricted boolean Whether the client refuses aura styling, as it does all match.
local function Zone(instanceType, inInstance, isRaid, restricted)
	env.inInstance = inInstance
	env.instanceType = instanceType
	env.isRaid = isRaid
	acm.restricted = restricted
	env.invalidateWorldState()
	module:Refresh()
end

-- A battleground reports as a raid group, so the module reads its Raid options there.
local function EnterBattleground()
	db.Modules.ImportantAuras.Enabled.BattleGrounds = false
	Zone("pvp", true, true, true)
end

local function LeaveToWorld()
	db.Modules.ImportantAuras.Enabled.BattleGrounds = true
	Zone("none", false, false, false)
end

---Whether any container the frame's icons could be drawn through is on screen.
---@param frame table
---@return boolean
local function IconsShown(frame)
	for _, container in ipairs(env.containersForUnit(frame.unit)) do
		if container:IsShown() then
			return true
		end
	end

	return false
end

fw.describe("ImportantAuras - the zone gate", function()
	fw.before_each(function()
		-- The frame the mid-match test adds would otherwise be discovered by every test after it.
		for index = #env.unitFrames, 2, -1 do
			env.unitFrames[index] = nil
		end

		LeaveToWorld()
	end)

	fw.it("hides the icons on entering a battleground it is switched off for", function()
		assert(IconsShown(held), "fixture: the icons start on screen in the open world")

		EnterBattleground()

		assert(not IconsShown(held), "the battleground flag must take the icons away")
	end)

	fw.it("leaves them away when the frame is re-pointed mid match", function()
		EnterBattleground()

		env.unitFrameHooks.OnSetUnit(held, "party1")

		assert(not IconsShown(held), "a re-point must not put the icons back")
	end)

	fw.it("leaves them away when the frame is shown again mid match", function()
		EnterBattleground()

		env.unitFrameHooks.OnUpdateVisible(held)

		assert(not IconsShown(held), "a visibility pass must not put the icons back")
	end)

	fw.it("builds nothing for a frame that first gets its unit mid match", function()
		EnterBattleground()

		local joined = env.addUnitFrame("party2", "CUF_ZoneGateJoined")
		env.unitFrameHooks.OnSetUnit(joined, "party2")

		assert(#env.containersForUnit("party2") == 0, "a frame filling mid match must stay bare")
	end)

	-- The tests above only prove the hooks do nothing, and nothing else in the suite reaches either
	-- productive half. Without these two a guard widened to an unconditional return would pass.
	-- Called on the display rather than through the hook, whose own refresh would build the watcher
	-- either way and make the assertion tautological.
	fw.it("still takes a frame that gets its unit while the zone allows it", function()
		local joined = env.addUnitFrame("party4", "CUF_ZoneGateAllowed")
		assert(#env.containersForUnit("party4") == 0, "fixture: the frame starts bare")

		env.addon.Modules.ImportantAuras.Display:OnCufSetUnit(joined, "party4")

		assert(#env.containersForUnit("party4") > 0, "an enabled module must still take the frame")
	end)

	fw.it("still shows them when the frame comes back while the zone allows it", function()
		local container = env.containersForUnit(held.unit)[1]
		assert(container, "fixture: the frame starts with a container")

		-- Taken away by hand rather than by hiding the anchor, which would mark the styling stale
		-- and let the restyle put the icons back before the show is reached.
		container:Hide()

		env.unitFrameHooks.OnUpdateVisible(held)

		assert(container:IsShown(), "an enabled module must still follow the frame back on screen")
	end)

	fw.it("brings them back on leaving, so the gate does not strand them", function()
		EnterBattleground()
		LeaveToWorld()

		assert(IconsShown(held), "the icons must return once the zone allows them")
	end)
end)
