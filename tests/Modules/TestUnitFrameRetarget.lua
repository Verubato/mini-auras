-- CrowdControl + Auras, 12.1 container path: what happens when a raid frame is
-- recycled onto a different unit.
--
-- Both modules key their state on the ANCHOR frame, not the unit, because that is what raid frame
-- addons reuse. On the legacy path a unit change threw the watcher away and built a new one; on
-- 12.1 the container is kept and only re-pointed, which is cheaper but has two ways to go wrong
-- silently: the display keeps tracking the old unit (one player's crowd control drawn on another
-- player's frame), or the kick subscription stays behind on the old unit.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local auraFilters = env.addon.Core.AuraFilters

env.setModuleEnabled("CCModule", true)
env.setModuleEnabled("RaidFrameAurasModule", true)

local ccFrame = env.addUnitFrame("party1", "CUF_CC")
local fiFrame = env.addUnitFrame("party2", "CUF_FI")

env.loadModule("src/Modules/CrowdControl/Display.lua")
env.loadModule("src/Modules/CrowdControl/Module.lua")
local crowdControl = env.addon.Modules.CrowdControlModule
crowdControl:Init()

env.loadModule("src/Modules/RaidFrameAuras/Display.lua")
env.loadModule("src/Modules/RaidFrameAuras/Module.lua")
local raidFrameAurasModule = env.addon.Modules.RaidFrameAurasModule
raidFrameAurasModule:Init()

---The display a module built for a given anchor, identified by its group signature: crowd control
---displays carry a single cc group, auras displays carry a cc group plus one
---spell-id-filtered helpful group.
local function displayForUnit(unit, groupCount)
	for _, container in ipairs(env.containersForUnit(unit)) do
		if env.groupCount(container) == groupCount then
			return container
		end
	end
end

local function ccDisplay(unit)
	return displayForUnit(unit, 1)
end

local function fiDisplay(unit)
	return displayForUnit(unit, 2)
end

fw.describe("CrowdControlModule 12.1 - unit frame anchors", function()
	fw.it("builds one crowd-control display per anchor, tracking its unit", function()
		local display = assert(ccDisplay("party1"), "no display for the anchor's unit")
		assert(display:GetUnit() == "party1", "tracking the anchor's unit")
		assert(display._groups[auraFilters.GroupKey.CrowdControl], "the crowd control group")
		assert(display._enabled and display:IsShown(), "live")
	end)

	fw.it("a refresh does not build a second container for the same anchor", function()
		local before = env.auraContainerCount()
		crowdControl:Refresh()
		crowdControl:Refresh()
		assert(env.auraContainerCount() == before, "containers are reused across refreshes")
	end)

	fw.it("re-pointing the anchor moves the display and the kick subscription", function()
		local display = ccDisplay("party1")
		local containersBefore = env.auraContainerCount()
		local kickMark = #env.kickCalls

		-- The raid frame addon recycled this frame onto a different unit.
		ccFrame.unit = "party4"
		crowdControl:Refresh()

		assert(display:GetUnit() == "party4", "the same container now tracks the new unit")
		assert(ccDisplay("party4") == display, "no second display was created")
		assert(env.auraContainerCount() == containersBefore, "the old container was reused, not leaked")
		assert(ccDisplay("party1") == nil, "nothing is left drawing crowd control for the old unit")

		local left = env.kickCallsSince(kickMark, "party1")
		assert(#left == 1 and left[1].Action == "Unsubscribe",
			"the old unit's kick subscription is dropped")
		local joined = env.kickCallsSince(kickMark, "party4")
		local actions = {}
		for _, call in ipairs(joined) do
			actions[call.Action] = true
		end
		assert(actions.Watch and actions.Subscribe, "the new unit is watched and subscribed")
	end)

	fw.it("the display survives a disable/enable cycle on the same anchor", function()
		local display = ccDisplay("party4")

		env.setModuleEnabled("CCModule", false)
		env.setModuleEnabled("PetCCModule", false)
		crowdControl:Refresh()
		assert(not display._enabled and not display:IsShown(), "parked while the module is off")

		env.setModuleEnabled("CCModule", true)
		crowdControl:Refresh()
		assert(display._enabled and display:IsShown(), "live again")
		assert(display:GetUnit() == "party4", "still pointed at the right unit")
	end)
end)

fw.describe("RaidFrameAurasModule 12.1 - unit frame anchors", function()
	fw.it("budgets the four categories from the per-instance toggles", function()
		-- After a Refresh, not straight off Init: the module's ApplyInitialState only builds the
		-- entries (ApplyOptions runs on the addon-wide Refresh that follows), so a display created
		-- outside a refresh carries the full per-category budget until the next one.
		raidFrameAurasModule:Refresh()

		local display = assert(fiDisplay("party2"), "no display for the anchor's unit")
		local options = db.Modules.RaidFrameAurasModule.Default
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1

		-- One helpful group now covers both categories, so either toggle keeps it budgeted.
		local expected = {
			[auraFilters.GroupKey.CrowdControl] = options.ShowCC and maxIcons or 0,
			helpful = (options.ShowDefensives or options.ShowImportant) and maxIcons or 0,
		}
		for key, budget in pairs(expected) do
			local group = assert(display._groups[key], "missing group " .. key)
			assert(group.maxFrameCount == budget,
				("%s: expected budget %d, got %s"):format(key, budget, tostring(group.maxFrameCount)))
		end
		assert(#env.notifications == 0,
			"budgeting used group keys that exist: " .. table.concat(env.notifications, "; "))
	end)

	fw.it("a category toggle re-budgets only that category", function()
		local display = fiDisplay("party2")
		local options = db.Modules.RaidFrameAurasModule.Default
		options.ShowCC = true
		raidFrameAurasModule:Refresh()

		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		assert(display._groups[auraFilters.GroupKey.CrowdControl].maxFrameCount == maxIcons, "cc on")

		-- Both helpful toggles have to go off before the one helpful group is unbudgeted.
		options.ShowDefensives = false
		options.ShowImportant = false
		raidFrameAurasModule:Refresh()
		assert(display._groups.helpful.maxFrameCount == 0, "helpful off")
		assert(display._groups[auraFilters.GroupKey.CrowdControl].maxFrameCount == maxIcons, "cc untouched")

		options.ShowImportant = true
		options.ShowDefensives = true
		raidFrameAurasModule:Refresh()
	end)

	fw.it("re-pointing the anchor moves the display and the kick subscription", function()
		local display = fiDisplay("party2")
		local containersBefore = env.auraContainerCount()
		local kickMark = #env.kickCalls

		fiFrame.unit = "party5"
		raidFrameAurasModule:Refresh()

		assert(display:GetUnit() == "party5", "the same container now tracks the new unit")
		assert(fiDisplay("party5") == display, "no second display was created")
		assert(env.auraContainerCount() == containersBefore, "the old container was reused, not leaked")

		local left = env.kickCallsSince(kickMark, "party2")
		assert(#left == 1 and left[1].Action == "Unsubscribe", "the old unit's subscription is dropped")
	end)

	fw.it("the category budgets survive the re-point", function()
		-- The budgets live on the group specs, which the display keeps; a re-point that rebuilt
		-- them from defaults would quietly turn categories back on.
		local display = fiDisplay("party5")
		local options = db.Modules.RaidFrameAurasModule.Default
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1

		assert(display._groups[auraFilters.GroupKey.CrowdControl].maxFrameCount ==
			(options.ShowCC and maxIcons or 0), "cc budget intact")
		assert(display._groups.helpful.maxFrameCount ==
			((options.ShowDefensives or options.ShowImportant) and maxIcons or 0),
			"helpful budget intact")
	end)
end)

fw.describe("12.1 unit frame modules - no legacy fallout", function()
	fw.it("neither module ever constructed a legacy aura watcher", function()
		-- module_env's UnitAuraWatcher stub errors on construction, so reaching this point at all
		-- is the assertion; the explicit check keeps the intent visible.
		assert(env.addon.Core.UnitAuraWatcher, "the tripwire stub is installed")
	end)

	fw.it("nothing was reported through Notify", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
