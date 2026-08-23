-- Crowd control and important auras, 12.1 container path: the containers built before any frame
-- has asked for one.
--
-- Both modules build one display per party or raid frame, and a display's groups cost a batch of
-- buttons the engine allocates on the spot and can never free. Nothing is built while a loading
-- screen is up, so a solo player logs in with none of them; the walker below is what has a party's
-- worth ready before the party forms.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
local acm = require("AuraContainerMock")

-- A crowd control display carries the one cc group; an important auras display carries that plus
-- the two spell-id-filtered helpful groups.
local CC_GROUPS = 1
local IMPORTANT_GROUPS = 3
-- What the undisturbed warm-up costs, measured, with a little headroom. Each module's lane takes a
-- tick of its own to start with, because a lane the walker has not seen run yet counts as dear
-- until it has shown what its items cost.
local WARMUP_TICKS = 4

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("CCModule", true)
env.setModuleEnabled("ImportantAurasModule", true)

env.addUnitFrame("party1", "CUF_Warmup")

env.loadModule("src/Modules/CrowdControl/Display.lua")
env.loadModule("src/Modules/CrowdControl/Module.lua")
local crowdControl = env.addon.Modules.CrowdControlModule
crowdControl:Init()

env.loadModule("src/Modules/ImportantAuras/Display.lua")
env.loadModule("src/Modules/ImportantAuras/Module.lua")
local importantAuras = env.addon.Modules.ImportantAurasModule
importantAuras:Init()

local ccOptions = db.Modules.CCModule.Default

---How many spares are waiting. A spare tracks nobody until a frame takes it, and the two modules
---are told apart by how many groups their displays carry.
---@param groupCount number
---@return number
local function spareCount(groupCount)
	local count = 0

	for _, container in ipairs(env.containersForUnit("none")) do
		if env.groupCount(container) == groupCount then
			count = count + 1
		end
	end

	return count
end

local function refreshBoth()
	crowdControl:Refresh()
	importantAuras:Refresh()
end

fw.describe("Unit frame auras - warming up ahead of a group", function()
	fw.it("warms nothing up while the modules are switched off", function()
		env.setModuleEnabled("CCModule", false)
		env.setModuleEnabled("PetCCModule", false)
		env.setModuleEnabled("ImportantAurasModule", false)

		local before = env.auraContainerCount()

		refreshBoth()
		acm.tickAll(400)

		assert(env.auraContainerCount() == before, "a switched-off module warmed containers up")
	end)

	fw.it("takes no longer for the refreshes that land while the walk is still going", function()
		env.setModuleEnabled("CCModule", true)
		env.setModuleEnabled("ImportantAurasModule", true)

		refreshBoth()
		acm.tickAll(1)

		-- A roster settling fires a burst of these, every one of them while the spares the first
		-- refresh asked for are still being built.
		for _ = 1, 5 do
			refreshBoth()
		end

		acm.tickAll(WARMUP_TICKS - 1)

		assert(spareCount(CC_GROUPS) == 4, "crowd control had " .. spareCount(CC_GROUPS)
			.. " spares after " .. WARMUP_TICKS .. " ticks, wanted 4")
		assert(spareCount(IMPORTANT_GROUPS) == 4, "important auras had " .. spareCount(IMPORTANT_GROUPS)
			.. " spares after " .. WARMUP_TICKS .. " ticks, wanted 4")
	end)

	fw.it("builds containers for the frames a group has yet to fill", function()
		env.setModuleEnabled("CCModule", true)
		env.setModuleEnabled("ImportantAurasModule", true)

		refreshBoth()
		acm.tickAll(400)

		-- One frame is on screen and five frames' worth are wanted, so each module holds four
		-- containers for units that are not there yet.
		assert(spareCount(CC_GROUPS) == 4,
			"crowd control warmed up " .. spareCount(CC_GROUPS) .. " spares, wanted 4")
		assert(spareCount(IMPORTANT_GROUPS) == 4,
			"important auras warmed up " .. spareCount(IMPORTANT_GROUPS) .. " spares, wanted 4")
	end)

	fw.it("hands a waiting spare to a frame that turns up", function()
		local before = env.auraContainerCount()
		local ccSpares = spareCount(CC_GROUPS)
		local importantSpares = spareCount(IMPORTANT_GROUPS)

		-- Somebody joined.
		env.addUnitFrame("party2", "CUF_Joined")

		refreshBoth()

		assert(env.auraContainerCount() == before,
			"the frame paid to build its own containers instead of taking the waiting ones")
		assert(spareCount(CC_GROUPS) == ccSpares - 1, "crowd control handed its spare over")
		assert(spareCount(IMPORTANT_GROUPS) == importantSpares - 1,
			"important auras handed its spare over")
		assert(#env.containersForUnit("party2") == 2, "and both of them track the new unit")
	end)

	fw.it("throws away the spares a budget change has reshaped", function()
		assert(spareCount(CC_GROUPS) > 0, "fixture: crowd control has spares waiting")

		-- A group's buttons are handed out from the count it was declared with, so a spare built
		-- to the old budget could never draw the new one.
		ccOptions.Icons.Count = (ccOptions.Icons.Count or 5) + 1

		crowdControl:Refresh()

		local before = env.auraContainerCount()

		env.addUnitFrame("party3", "CUF_Reshaped")

		crowdControl:Refresh()

		assert(env.auraContainerCount() == before + 1,
			"the frame was handed a spare built to the icon budget nobody is using any more")
	end)

	fw.it("nothing was reported through Notify", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
