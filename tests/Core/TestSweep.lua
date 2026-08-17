-- The shared background walker's lane model. The failures this guards against: the per-tick
-- budget is addon-wide, so however many modules queue a sweep at once, the total background
-- cost per tick stays flat; one lane replacing or abandoning its run must never touch another
-- lane's; and the end-of-tick stop check must not consume a busy lane's round-robin turn.

local fw = require("Framework")
local tickerMock = require("TickerMock")

tickerMock.Install()

local addon = { Core = {} }
assert(loadfile("src/Core/Display/Sweep.lua"))("MiniAuras", addon)
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
		assert(#seen == 2, "two items per tick for a lone lane")

		tickerMock.Tick(2)
		assert(#seen == 5, "queue drained")
		assert(tickerMock.ActiveCount() == 0, "ticker stopped with nothing left to do")
	end)

	fw.it("two lanes split the same budget instead of doubling it", function()
		local laneA = sweep:New()
		local laneB = sweep:New()
		local seenA, collectA = Collector()
		local seenB, collectB = Collector()

		laneA:Run(Items(4), collectA)
		laneB:Run(Items(4), collectB)

		tickerMock.Tick(1)
		assert(#seenA + #seenB == 2, "the budget is addon-wide, not per lane")
		assert(#seenA == 1 and #seenB == 1, "and it is split fairly between them")

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

		tickerMock.Tick(2)
		assert(#seen[1] >= 1 and #seen[2] >= 1 and #seen[3] >= 1,
			"four slots over two ticks must reach all three lanes")

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

		local replaced, collectReplaced = Collector()
		laneA:Run(Items(2), collectReplaced)

		tickerMock.Tick(6)
		assert(#seenA == 1, "the replaced run never resumed")
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
