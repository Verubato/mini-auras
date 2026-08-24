-- Trinkets: which frame the arena trinket icons end up hanging off.
--
-- The anchors are taken from whatever party frames are on screen at the time. In an arena that
-- moment is the loading screen, and a frame addon builds, sorts and swaps its own frames well
-- after it - some only replace the client's once their own are up. An anchor taken too early
-- points at a frame nobody shows any more, and since a SetPoint follows the frame it was given,
-- the icon then sits at that frame's position for the whole match. That is the report this file
-- exists for: trinket icons out of place on entering an arena, back where they belong after a
-- reload.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()

-- The tracker reads cooldowns straight off the client; nothing here is about the durations.
_G.C_PvP.GetArenaCrowdControlDuration = function()
	return nil
end

env.inInstance = true
env.instanceType = "arena"
env.invalidateWorldState()
env.setModuleEnabled("Trinkets", true)

env.loadModule("src/Core/Trinkets/TrinketsTracker.lua")
env.addon.Core.TrinketsTracker:Init()

env.loadModule("src/Modules/Trinkets/Display.lua")
env.loadModule("src/Modules/Trinkets/Module.lua")

local trinkets = env.addon.Modules.TrinketsModule
local iconSlotContainer = env.addon.Core.IconSlotContainer
local containers = {}

-- Every container the module builds, so a test can ask which frame each one is on without the
-- display having to hand its watchers out.
local realNew = iconSlotContainer.New
iconSlotContainer.New = function(self, ...)
	local container = realNew(self, ...)
	containers[#containers + 1] = container

	return container
end

trinkets:Init()

---The frame a container is anchored to, or nil when it has been unanchored.
---@param container table
---@return table?
local function AnchorOf(container)
	if container.Frame:GetNumPoints() == 0 then
		return nil
	end

	local _, relativeTo = container.Frame:GetPoint(1)

	return relativeTo
end

---How many of the module's containers are anchored to the given frame.
---@param frame table
---@return number
local function CountOn(frame)
	local count = 0

	for _, container in ipairs(containers) do
		if AnchorOf(container) == frame then
			count = count + 1
		end
	end

	return count
end

local first = env.addUnitFrame("party1", "TrinketAnchorA")
local second = env.addUnitFrame("party1", "TrinketAnchorB")

second:Hide()

fw.describe("Trinkets - the frame the icon hangs off", function()
	fw.it("takes the party frame that is on screen", function()
		trinkets:Refresh()

		fw.eq(CountOn(first), 1, "one icon on the frame that was up")
		fw.eq(CountOn(second), 0, "and none on the frame nobody is showing")
	end)

	fw.it("moves to the frame that replaces it, without waiting for a reload", function()
		-- The frame addon's own frames arrive and the ones the icons were given go away. No
		-- roster change and no zone change: the only thing that announces this is the unit
		-- frame hook.
		first:Hide()
		second:Show()

		env.unitFrameHooks.OnUpdateVisible(second)

		fw.eq(CountOn(second), 1, "the icon followed the frame that is on screen now")
		fw.eq(CountOn(first), 0, "and left nothing behind on the frame that went away")
	end)

	fw.it("reuses the container it parked rather than building another", function()
		local built = #containers

		first:Show()
		second:Hide()
		env.unitFrameHooks.OnUpdateVisible(first)

		fw.eq(CountOn(first), 1, "back on the first frame")
		fw.eq(#containers, built, "no container was built for a frame already seen once")
	end)

	fw.it("ignores the frame churn of a raid, where nothing is on screen anyway", function()
		env.instanceType = "party"
		env.invalidateWorldState()

		local built = #containers
		local newFrame = env.addUnitFrame("party2", "TrinketAnchorC")

		env.unitFrameHooks.OnUpdateVisible(newFrame)

		fw.eq(#containers, built, "no anchors taken outside an arena")
		fw.eq(CountOn(newFrame), 0, "and nothing hung on the new frame")

		env.instanceType = "arena"
		env.invalidateWorldState()
	end)
end)

fw.describe("Trinkets - the arena's own cooldown feed", function()
	fw.it("retakes the anchors, so a set from the loading screen is replaced", function()
		-- The tracker fires with no unit when its arena gate opens and on every match-state
		-- change after it. By then every frame addon has had its chance to build, which makes
		-- this the last line of defence for a set of anchors taken too early. Nothing else here
		-- announces the swap: no roster change, no zone change, no unit frame hook.
		local swapped = env.addUnitFrame("party1", "TrinketAnchorD")

		first:Hide()

		env.addon.Core.TrinketsTracker:Refresh()

		fw.eq(CountOn(swapped), 1, "the icon is on the frame that is actually up")
		fw.eq(CountOn(first), 0, "and off the one that is not")
	end)
end)
