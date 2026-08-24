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

env.setModuleEnabled("CrowdControl", true)
env.setModuleEnabled("ImportantAuras", true)

local ccFrame = env.addUnitFrame("party1", "CUF_CC")
local fiFrame = env.addUnitFrame("party2", "CUF_FI")

env.loadModule("src/Modules/CrowdControl/Display.lua")
env.loadModule("src/Modules/CrowdControl/Module.lua")
local crowdControl = env.addon.Modules.CrowdControlModule
crowdControl:Init()

env.loadModule("src/Modules/ImportantAuras/Display.lua")
env.loadModule("src/Modules/ImportantAuras/Module.lua")
local importantAurasModule = env.addon.Modules.ImportantAurasModule
importantAurasModule:Init()

---The display a module built for a given anchor, identified by its group signature: crowd control
---displays carry a single cc group, auras displays carry a cc group plus the two
---spell-id-filtered helpful groups.
-- A raid-frame display is created with none of its groups: they are declared by the background
-- walker, a group per turn, so a whole roster turning up does not build them all in one frame.
-- Reading one back means letting that walk run first.
local function settleGroups()
	require("AuraContainerMock").tickAll(40)
end

local function displayForUnit(unit, groupCount)
	settleGroups()

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
	return displayForUnit(unit, 3)
end

---The helpful icon budget. The two helpful groups are budgeted as a pair - they are split by
---category so each can take its own colour, not so they can be switched on separately.
local function helpfulBudget(display)
	local defensive = assert(display._groups.helpfuldef, "no defensive group")
	local important = assert(display._groups.helpfulimp, "no important group")

	assert(defensive.maxFrameCount == important.maxFrameCount,
		"the helpful groups must be budgeted as a pair")

	return defensive.maxFrameCount
end

---Runs one poller tick with the module's own Refresh counted, so a test can tell a per-unit update
---apart from one that went the long way round. The module-wide refresh a flip used to trigger is
---coalesced onto C_Timer.After, which this harness runs synchronously, so it lands inside the tick
---and is counted; nothing has to be flushed afterwards.
---@param module table
---@return number refreshes
local function tickCountingRefreshes(module)
	local acm = require("AuraContainerMock")
	local refreshes = 0
	local realRefresh = module.Refresh

	module.Refresh = function(...)
		refreshes = refreshes + 1
		return realRefresh(...)
	end

	acm.tickAll(1)
	module.Refresh = realRefresh

	return refreshes
end

fw.describe("Important auras - the login layout pass", function()
	fw.it("builds nothing while a loading screen is up", function()
		local fresh = env.addUnitFrame("party3", "CUF_Loading")

		-- Blizzard briefly shows every frame it pre-creates, pointed at "player", while it lays
		-- them out at login. Each one is visible and holds a unit that genuinely exists, so the
		-- ordinary tests pass for all forty-five of them; only the timing tells them apart.
		env.loadingScreenUp = true

		importantAurasModule:Refresh()

		assert(#env.containersForUnit("party3") == 0, "the layout pass builds nothing")

		env.loadingScreenUp = false

		importantAurasModule:Refresh()

		assert(#env.containersForUnit("party3") > 0, "and the pass after the screen builds it")

		env.unitFrames[#env.unitFrames] = nil
		fresh:Hide()
	end)

	-- Crowd control is the exception. It builds through the pass rather than waiting it out, and
	-- carries the containers the settling frames leave behind for it.
	fw.it("builds crowd control containers during it", function()
		local fresh = env.addUnitFrame("party4", "CUF_LoadingCC")
		local before = #env.containersForUnit("party4")

		env.loadingScreenUp = true

		crowdControl:Refresh()

		local built = #env.containersForUnit("party4")

		env.loadingScreenUp = false
		env.unitFrames[#env.unitFrames] = nil
		fresh:Hide()

		assert(built > before, "the layout pass built nothing")
	end)
end)

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

		env.setModuleEnabled("CrowdControl", false)
		env.setModuleEnabled("PetCrowdControl", false)
		crowdControl:Refresh()
		assert(not display._enabled and not display:IsShown(), "parked while the module is off")

		env.setModuleEnabled("CrowdControl", true)
		crowdControl:Refresh()
		assert(display._enabled and display:IsShown(), "live again")
		assert(display:GetUnit() == "party4", "still pointed at the right unit")
	end)
end)

fw.describe("ImportantAuras 12.1 - unit frame anchors", function()
	fw.it("budgets the four categories from the per-instance toggles", function()
		-- After a Refresh, not straight off Init: the module's ApplyInitialState only builds the
		-- entries (ApplyOptions runs on the addon-wide Refresh that follows), so a display created
		-- outside a refresh carries the full per-category budget until the next one.
		importantAurasModule:Refresh()

		local display = assert(fiDisplay("party2"), "no display for the anchor's unit")
		local options = db.Modules.ImportantAuras.Default
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1

		local cc = assert(display._groups[auraFilters.GroupKey.CrowdControl], "missing the cc group")
		assert(cc.maxFrameCount == (options.ShowCrowdControl and maxIcons or 0), "cc budget")

		-- Either helpful toggle keeps both helpful groups budgeted: a curated spell can sit in
		-- both categories, so the toggles pick the tracked ids rather than a budget each.
		assert(helpfulBudget(display) ==
			((options.ShowDefensives or options.ShowImportant) and maxIcons or 0), "helpful budget")
		assert(#env.notifications == 0,
			"budgeting used group keys that exist: " .. table.concat(env.notifications, "; "))
	end)

	fw.it("a category toggle re-budgets only that category", function()
		local display = fiDisplay("party2")
		local options = db.Modules.ImportantAuras.Default
		options.ShowCrowdControl = true
		importantAurasModule:Refresh()

		local maxIcons = tonumber(options.Icons.MaxIcons) or 1
		assert(display._groups[auraFilters.GroupKey.CrowdControl].maxFrameCount == maxIcons, "cc on")

		-- Both helpful toggles have to go off before the helpful groups are unbudgeted.
		options.ShowDefensives = false
		options.ShowImportant = false
		importantAurasModule:Refresh()
		assert(helpfulBudget(display) == 0, "helpful off")
		assert(display._groups[auraFilters.GroupKey.CrowdControl].maxFrameCount == maxIcons, "cc untouched")

		options.ShowImportant = true
		options.ShowDefensives = true
		importantAurasModule:Refresh()
	end)

	fw.it("re-pointing the anchor moves the display and the kick subscription", function()
		local display = fiDisplay("party2")
		local containersBefore = env.auraContainerCount()
		local kickMark = #env.kickCalls

		fiFrame.unit = "party5"
		importantAurasModule:Refresh()

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
		local options = db.Modules.ImportantAuras.Default
		local maxIcons = tonumber(options.Icons.MaxIcons) or 1

		assert(display._groups[auraFilters.GroupKey.CrowdControl].maxFrameCount ==
			(options.ShowCrowdControl and maxIcons or 0), "cc budget intact")
		assert(helpfulBudget(display) ==
			((options.ShowDefensives or options.ShowImportant) and maxIcons or 0),
			"helpful budget intact")
	end)
end)

fw.describe("unit frame modules - no fallout", function()
	fw.it("nothing was reported through Notify", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)

fw.describe("Unit frames nobody is on", function()
	-- Blizzard builds its party and raid frames for a full group and calls SetUnit on every one of
	-- them at login, so a solo player's frames alone were dozens of containers for units that are
	-- not there.
	fw.it("builds nothing for a frame whose unit is absent, and builds when one turns up", function()
		local frame = env.addUnitFrame("raid7", "CUF_Empty")

		env.missingUnits.raid7 = true
		crowdControl:Refresh()
		importantAurasModule:Refresh()
		settleGroups()

		assert(#env.containersForUnit("raid7") == 0, "a frame nobody is on got a display")

		env.missingUnits.raid7 = nil
		crowdControl:Refresh()
		importantAurasModule:Refresh()
		settleGroups()

		assert(#env.containersForUnit("raid7") > 0, "and the unit turning up is what builds it")

		frame:Hide()
	end)
end)

fw.describe("ImportantAuras 12.1 - a party member who turns hostile", function()
	local acm = require("AuraContainerMock")

	fw.it("drops the helpful budget when a duel starts", function()
		-- The frame was re-pointed by the tests above; party5 is who it holds now.
		env.enemies.party5 = nil
		importantAurasModule:Refresh()

		local display = assert(fiDisplay("party5"), "no display for the anchor's unit")

		assert(helpfulBudget(display) > 0, "buffs are tracked on a party member")

		-- A duel fires no event of its own, so the poller is the only thing that notices. It only
		-- scans tokens it holds a baseline for, which is what the module has to give it.
		env.enemies.party5 = true
		acm.tickAll(1)

		-- Spell-id filters are dropped on a unit you cannot assist, so the bare HELPFUL token
		-- would match every buff they have.
		assert(helpfulBudget(display) == 0,
			"the helpful group must be budgeted away while they are hostile")

		env.enemies.party5 = nil
		acm.tickAll(1)

		assert(helpfulBudget(display) > 0, "and come back when the duel ends")
	end)
end)

fw.describe("ImportantAuras 12.1 - a frame handed an enemy unit", function()
	local raidDisplay = env.addon.Modules.ImportantAuras.Display

	fw.it("drops the helpful budget when the frame is re-pointed at one", function()
		-- What mind control does: Blizzard re-points the FRIENDLY frames onto enemy units. The
		-- gate is per unit, so the answer moves without any option changing.
		env.enemies.party6 = true
		fiFrame.unit = "party6"
		importantAurasModule:Refresh()

		local display = assert(fiDisplay("party6"), "the container followed the frame")

		assert(helpfulBudget(display) == 0,
			"a unit you cannot assist gets no helpful group")
	end)

	fw.it("gives it back when the same unit becomes friendly again", function()
		local display = assert(fiDisplay("party6"))

		env.enemies.party6 = nil

		assert(raidDisplay:ReapplyUnitGates("party6"),
			"the gate's answer moved, so the module has work to do")
		assert(helpfulBudget(display) > 0, "and the buffs are tracked again")
	end)

	fw.it("says nothing changed for a faction event that moved nothing", function()
		-- PvP flagging fires this constantly in the open world; an unchanged answer must not
		-- drag the whole module through a refresh.
		assert(not raidDisplay:ReapplyUnitGates("party6"), "no work for an unchanged gate")
	end)

	fw.it("ignores a faction event for a unit nobody is watching", function()
		assert(not raidDisplay:ReapplyUnitGates("party40"), "not a unit on any frame")
	end)
end)

fw.describe("ImportantAuras 12.1 - a unit outside the visible world", function()
	fw.it("shows nothing at all for one", function()
		env.enemies.party6 = nil
		env.phased.party6 = nil
		importantAurasModule:Refresh()

		local display = assert(fiDisplay("party6"), "no display for the anchor's unit")
		local cc = auraFilters.GroupKey.CrowdControl

		assert(helpfulBudget(display) > 0, "tracked while they are in range")

		-- Nothing announces a unit walking out of range, so the poller is what notices, and it
		-- updates that unit alone rather than dragging the module through a refresh.
		env.phased.party6 = true

		assert(tickCountingRefreshes(importantAurasModule) == 0,
			"the flip updated the one unit instead of refreshing the module")

		-- Out there the engine stops evaluating the filters properly and both groups fill with
		-- unrelated auras, so neither is given any icons.
		assert(helpfulBudget(display) == 0, "no buffs from out of range")
		assert(display._groups[cc].maxFrameCount == 0, "and no debuffs either")
	end)

	fw.it("picks them back up when they come back", function()
		local display = assert(fiDisplay("party6"))

		env.phased.party6 = nil

		assert(tickCountingRefreshes(importantAurasModule) == 0, "and comes back the same cheap way")
		assert(helpfulBudget(display) > 0, "tracked again once they are back")
	end)
end)

fw.describe("CrowdControlModule 12.1 - a unit outside the visible world", function()
	local cc = auraFilters.GroupKey.CrowdControl

	fw.it("budgets that unit's icons away and leaves the other frames alone", function()
		ccFrame.unit = "party7"
		env.phased.party7 = nil
		crowdControl:Refresh()

		local display = assert(ccDisplay("party7"), "no display for the anchor's unit")

		assert(display._groups[cc].maxFrameCount > 0, "tracked while they are in range")

		-- Out there the engine stops evaluating the CROWD_CONTROL token and the group fills with
		-- unrelated debuffs, so it is given no icons at all.
		env.phased.party7 = true

		assert(tickCountingRefreshes(crowdControl) == 0,
			"the flip re-budgeted the one unit instead of refreshing the module")
		assert(display._groups[cc].maxFrameCount == 0, "no debuffs from out of range")
	end)

	fw.it("picks them back up when they come back", function()
		local display = assert(ccDisplay("party7"))

		env.phased.party7 = nil

		assert(tickCountingRefreshes(crowdControl) == 0, "and comes back the same cheap way")
		assert(display._groups[cc].maxFrameCount > 0, "tracked again once they are back")
	end)

	-- Watchers are keyed by anchor, so one unit can sit behind more than one frame - a raid frame
	-- and a focus frame, say. Stopping at the first match would leave the others showing the
	-- unfiltered auras the budget exists to suppress, which is why the walk updates every match.
	fw.it("updates every frame holding the unit, not just the first", function()
		local secondFrame = env.addUnitFrame("party7", "CUF_CC_SECOND")

		env.phased.party7 = nil
		crowdControl:Refresh()
		settleGroups()

		local displays = {}
		for _, container in ipairs(env.containersForUnit("party7")) do
			if env.groupCount(container) == 1 then
				displays[#displays + 1] = container
			end
		end

		assert(#displays == 2, "both anchors carry a crowd-control display, got " .. #displays)
		for _, display in ipairs(displays) do
			assert(display._groups[cc].maxFrameCount > 0, "tracked while they are in range")
		end

		env.phased.party7 = true

		assert(tickCountingRefreshes(crowdControl) == 0, "still no module refresh")
		for index, display in ipairs(displays) do
			assert(display._groups[cc].maxFrameCount == 0,
				"display " .. index .. " was left showing icons for a unit out of range")
		end

		env.phased.party7 = nil
		secondFrame.unit = nil
		crowdControl:Refresh()
	end)
end)
