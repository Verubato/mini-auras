-- The shared background walker's lane model. The failures this guards against: the per-tick
-- budget is addon-wide, so however many modules queue a sweep at once, the total background
-- cost per tick stays flat; one lane replacing or abandoning its run must never touch another
-- lane's; and the end-of-tick stop check must not consume a busy lane's round-robin turn.

local fw = require("Framework")
local tickerMock = require("TickerMock")

tickerMock.Install()

local addon = { Core = {} }
assert(loadfile("src/Core/Pooling/Sweep.lua"))("MiniAuras", addon)
local sweep = addon.Core.Sweep

local function Items(count)
	local queue = {}

	for index = 1, count do
		queue[index] = { id = index }
	end

	return queue
end

local function Collector()
	local seen = {}

	return seen, function(item)
		seen[#seen + 1] = item.id
	end
end

fw.describe("Sweep - shared budget across lanes", function()
	fw.before_each(tickerMock.Reset)

	fw.it("a lone lane gets the whole budget and the ticker stops on drain", function()
		local lane = sweep:New()
		local seen, collect = Collector()

		lane:Run(Items(5), collect)

		tickerMock.Tick(1)
		assert(#seen == 3, "the whole per-tick budget for a lone lane")

		tickerMock.Tick(2)
		assert(#seen == 5, "queue drained")
		assert(tickerMock.ActiveCount() == 0, "ticker stopped with nothing left to do")
	end)

	fw.it("a capped lane takes one slot a tick, whatever else the budget has free", function()
		-- What the pre-creation fills hold: building a frame is a hundred restyles, so a lane
		-- doing it must not be handed the whole tick just because nothing else wants it.
		local lane = sweep:New(1)
		local seen, collect = Collector()

		lane:Run(Items(4), collect)

		tickerMock.Tick(1)
		assert(#seen == 1, "the cap let the lane take more than its slot")

		tickerMock.Tick(3)
		assert(#seen == 4, "the rest still drain, one tick apart")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a tick that spends its time budget stops handing out slots", function()
		-- Items vary by two orders of magnitude: a restyle is nothing, building a container full
		-- of buttons is ten milliseconds. Without this a tick chained three of the expensive kind.
		local lane = sweep:New()
		local seen = {}

		lane:Run(Items(4), function(item)
			seen[#seen + 1] = item.id
			tickerMock.Advance(2)
		end)

		tickerMock.Tick(1)
		assert(#seen == 1, "the tick kept going after its budget was spent")

		tickerMock.Tick(3)
		assert(#seen == 4, "the rest still drain, one tick apart")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a cheap item does not open the door to an expensive one", function()
		-- The budget cannot split an item, so a tick that has already spent some of it must not
		-- start one it knows is dear. Without this a run of cheap no-op turns kept letting a
		-- container build in behind them, and the tick came out at fifteen milliseconds.
		local cheap = sweep:New()
		local dear = sweep:New()
		local cheapSeen, collectCheap = Collector()
		local dearSeen = {}

		cheap:Run(Items(6), collectCheap)
		dear:Run(Items(6), function(item)
			dearSeen[#dearSeen + 1] = item.id
			tickerMock.Advance(9)
		end)

		-- The first tick has no history to go on, so the dear lane gets a turn and shows what its
		-- items cost. From there it only ever runs as the first item of a tick.
		for _ = 1, 8 do
			local before = #dearSeen

			tickerMock.Tick(1)
			assert(#dearSeen - before <= 1, "two dear items landed in the same tick")
		end

		assert(#dearSeen > 1, "the dear lane made no progress")
		assert(#cheapSeen > 1, "the cheap lane stopped draining around it")

		tickerMock.Tick(10)
		assert(tickerMock.ActiveCount() == 0, "both lanes drained")
	end)

	fw.it("an item can ask to be handed back until it is finished", function()
		-- What the display prewarms need: building a container is too big for one slot, so the
		-- item comes back for its next piece rather than the lane moving on.
		local lane = sweep:New(1)
		local seen = {}
		local parts = {}

		lane:Run(Items(2), function(item)
			seen[#seen + 1] = item.id
			parts[item.id] = (parts[item.id] or 0) + 1

			if parts[item.id] < 2 then
				return sweep.Verdict.Unfinished
			end
		end)

		tickerMock.Tick(4)

		assert(#seen == 4, "each item ran twice, got " .. #seen)
		assert(seen[1] == 1 and seen[2] == 1 and seen[3] == 2 and seen[4] == 2,
			"an unfinished item finishes before the next one starts")
		assert(tickerMock.ActiveCount() == 0, "the ticker stopped once both were done")
	end)

	fw.it("two lanes split the same budget instead of doubling it", function()
		local laneA = sweep:New()
		local laneB = sweep:New()
		local seenA, collectA = Collector()
		local seenB, collectB = Collector()

		laneA:Run(Items(4), collectA)
		laneB:Run(Items(4), collectB)

		tickerMock.Tick(1)
		assert(#seenA + #seenB == 3, "the budget is addon-wide, not per lane")
		assert(#seenA >= 1 and #seenB >= 1, "and it is split between them rather than spent on one")

		tickerMock.Tick(3)
		assert(#seenA == 4 and #seenB == 4, "both drain, just over more ticks")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a third busy lane is not starved by the stop check", function()
		-- The end-of-tick "should the ticker stop" question must peek without advancing the
		-- round-robin cursor; asking through the consuming lookup ate one lane's turn per tick,
		-- so with three busy lanes the third never ran until the others drained.
		local seen = {}

		for index = 1, 3 do
			local lane = sweep:New()
			local laneSeen = {}
			seen[index] = laneSeen

			lane:Run(Items(2), function(item)
				laneSeen[#laneSeen + 1] = item.id
			end)
		end

		tickerMock.Tick(1)
		assert(#seen[1] >= 1 and #seen[2] >= 1 and #seen[3] >= 1,
			"a tick's slots must reach all three lanes")

		tickerMock.Tick(2)
		assert(#seen[1] == 2 and #seen[2] == 2 and #seen[3] == 2, "everything drains")
	end)

	fw.it("one lane abandoning leaves the other running", function()
		local laneA = sweep:New()
		local laneB = sweep:New()
		local seenB, collectB = Collector()

		laneA:Run(Items(4), function()
			return false
		end)
		laneB:Run(Items(3), collectB)

		tickerMock.Tick(5)
		assert(#seenB == 3, "the abandoning lane took its own queue down, not its neighbour's")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a lane's Run replaces only its own queue", function()
		local laneA = sweep:New()
		local laneB = sweep:New()
		local seenA, collectA = Collector()
		local seenB, collectB = Collector()

		laneA:Run(Items(6), collectA)
		laneB:Run(Items(3), collectB)
		tickerMock.Tick(1)

		-- However the tick's slots fell between the two lanes, the replaced run is finished here.
		local beforeReplace = #seenA
		local replaced, collectReplaced = Collector()
		laneA:Run(Items(2), collectReplaced)

		tickerMock.Tick(6)
		assert(#seenA == beforeReplace, "the replaced run never resumed")
		assert(#replaced == 2, "the replacement ran from its start")
		assert(#seenB == 3, "the other lane was untouched")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a processFn replacing its own lane's run keeps the replacement", function()
		-- The abandon check must compare against the queue the item came from: a processFn may
		-- Run a replacement on its own lane and then return false to kill the old run, and
		-- stopping the lane afterwards would silently destroy the queue it just installed.
		local lane = sweep:New()
		local replaced, collectReplaced = Collector()
		local sawOldRun = false

		lane:Run(Items(3), function()
			sawOldRun = true
			lane:Run(Items(2), collectReplaced)

			return false
		end)

		tickerMock.Tick(3)
		assert(sawOldRun, "the old run's first item fired")
		assert(#replaced == 2, "the replacement survived the abandoning return")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("an empty queue neither starts a ticker nor disturbs the others", function()
		local lane = sweep:New()
		local seen, collect = Collector()

		lane:Run(Items(0), collect)

		assert(tickerMock.ActiveCount() == 0, "nothing to do, nothing scheduled")
		assert(#seen == 0)
	end)
end)
