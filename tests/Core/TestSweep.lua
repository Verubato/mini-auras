-- The shared background walker's lane model. The failures this guards against: a tick spends a
-- millisecond budget rather than a count of items, so a lane of cheap items drains many at once
-- while a lane of dear ones takes a tick each; a lane is weighed by the worst item it has run
-- lately, so a stretch of cheap ones cannot let a dear one in behind them; one lane replacing or
-- abandoning its run must never touch another lane's; and the end-of-tick stop check must not
-- consume a busy lane's round-robin turn.

local fw = require("Framework")
local tickerMock = require("TickerMock")

tickerMock.Install()

local addon = { Core = {} }
assert(loadfile("src/Core/Pooling/Sweep.lua"))("MiniAuras", addon)
local sweep = addon.Core.Sweep

-- Eight of these spend a whole tick's budget exactly, so a test can say where its tick ends.
local CHEAP_MS = 0.25
-- More than half the budget, so a lane that has run one cannot fit another in the same tick.
local DEAR_MS = 1.25

local function Items(count)
	local queue = {}

	for index = 1, count do
		queue[index] = { id = index }
	end

	return queue
end

---@param ms number? What each item spends of the mock clock; free by default.
local function Collector(ms)
	local seen = {}

	return seen, function(item)
		seen[#seen + 1] = item.id

		if ms then
			tickerMock.Advance(ms)
		end
	end
end

fw.describe("Sweep - a time budget shared across the lanes", function()
	fw.before_each(tickerMock.Reset)

	fw.it("a lane of cheap items drains several a tick and the ticker stops on drain", function()
		local lane = sweep:New()
		local seen, collect = Collector(CHEAP_MS)

		lane:Run(Items(12), collect)

		tickerMock.Tick(1)
		assert(#seen == 8, "a tick runs cheap items until the budget is gone, got " .. #seen)

		tickerMock.Tick(1)
		assert(#seen == 12, "queue drained")
		assert(tickerMock.ActiveCount() == 0, "ticker stopped with nothing left to do")
	end)

	fw.it("a lane whose items cost more than the budget takes one a tick", function()
		-- Building a container full of buttons outweighs the whole tick on its own. It has to run
		-- anyway, so it runs as the tick's first item, with nothing chained behind it.
		local lane = sweep:New()
		local seen, collect = Collector(3)

		lane:Run(Items(3), collect)

		tickerMock.Tick(1)
		assert(#seen == 1, "an item dearer than the budget was not left alone in its tick")

		tickerMock.Tick(2)
		assert(#seen == 3, "the rest still drain, a tick apart")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a cheap stretch does not open the door to a lane's dear items", function()
		-- The regression the whole design exists for. A lane is weighed by the worst it has seen
		-- lately, not its average: an average sits near the cheap no-op turns it has just done and
		-- barely moves when the first real container build lands, leaving room for the next one
		-- behind it, which is how one tick came out at fifteen milliseconds.
		local lane = sweep:New()
		local queue = {}

		for index = 1, 8 do
			queue[index] = { cost = CHEAP_MS }
		end

		for index = 9, 12 do
			queue[index] = { cost = DEAR_MS }
		end

		local seen = {}

		lane:Run(queue, function(item)
			seen[#seen + 1] = item
			tickerMock.Advance(item.cost)
		end)

		for _ = 1, 6 do
			local before = #seen

			tickerMock.Tick(1)

			local dear = 0

			for index = before + 1, #seen do
				if seen[index].cost == DEAR_MS then
					dear = dear + 1
				end
			end

			assert(dear == 0 or #seen - before == 1,
				"a dear item shared its tick with " .. (#seen - before - 1) .. " others")
		end

		assert(#seen == 12, "the lane drained, got " .. #seen)
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a dear lane never doubles up, and a cheap one keeps draining around it", function()
		local cheap = sweep:New()
		local dear = sweep:New()
		local cheapSeen, collectCheap = Collector(CHEAP_MS)
		local dearSeen, collectDear = Collector(DEAR_MS)
		local shared = false

		cheap:Run(Items(12), collectCheap)
		dear:Run(Items(4), collectDear)

		for _ = 1, 8 do
			local beforeDear = #dearSeen
			local beforeCheap = #cheapSeen

			tickerMock.Tick(1)

			assert(#dearSeen - beforeDear <= 1, "two dear items landed in the same tick")

			shared = shared or (#dearSeen > beforeDear and #cheapSeen > beforeCheap)
		end

		assert(shared, "the cheap lane never got the rest of a tick a dear item started")
		assert(#dearSeen == 4 and #cheapSeen == 12, "both lanes drained")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("a lane that has never run waits for a tick of its own", function()
		-- Until a lane has shown what its items cost it counts as dear, because the one thing it
		-- must not do is turn out to be a container build halfway through someone else's tick.
		local first = sweep:New()
		local second = sweep:New()
		local seenFirst, collectFirst = Collector(CHEAP_MS)
		local seenSecond, collectSecond = Collector(CHEAP_MS)

		first:Run(Items(4), collectFirst)
		second:Run(Items(4), collectSecond)

		tickerMock.Tick(1)
		assert(#seenFirst + #seenSecond == 4, "one lane's whole queue, got "
			.. #seenFirst + #seenSecond)
		assert(#seenFirst == 0 or #seenSecond == 0, "the untried lane took a slot on trust")

		tickerMock.Tick(1)
		assert(#seenFirst == 4 and #seenSecond == 4, "and it drains in the next tick")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("an item can ask to be handed back until it is finished", function()
		-- What the display prewarms need: building a container is too big for one slot, so the
		-- item comes back for its next piece rather than the lane moving on, and the budget is
		-- weighed between the pieces.
		local lane = sweep:New()
		local seen = {}
		local parts = {}

		lane:Run(Items(2), function(item)
			seen[#seen + 1] = item.id
			parts[item.id] = (parts[item.id] or 0) + 1
			tickerMock.Advance(DEAR_MS)

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

	fw.it("an urgent lane goes before the others", function()
		-- What the on-demand displays hold: a plate is on screen waiting for its groups, while
		-- the ordinary lanes are preparing spares nobody has asked for.
		local spare = sweep:New()
		local urgent = sweep:New(true)
		local seenSpare, collectSpare = Collector(DEAR_MS)
		local seenUrgent, collectUrgent = Collector(DEAR_MS)

		spare:Run(Items(6), collectSpare)
		urgent:Run(Items(3), collectUrgent)

		tickerMock.Tick(3)
		assert(#seenUrgent == 3, "the urgent lane took every tick, got " .. #seenUrgent)
		assert(#seenSpare == 0, "while the ordinary one waited")

		tickerMock.Tick(6)
		assert(#seenSpare == 6, "which drains once there is nothing urgent left")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("two urgent lanes take turns rather than the older one taking everything", function()
		-- Every module with something on screen holds an urgent lane, so picking the first one in
		-- the list every time would hand every tick to whichever module loaded first.
		local first = sweep:New(true)
		local second = sweep:New(true)
		local seenFirst, collectFirst = Collector(DEAR_MS)
		local seenSecond, collectSecond = Collector(DEAR_MS)

		first:Run(Items(4), collectFirst)
		second:Run(Items(4), collectSecond)

		tickerMock.Tick(2)
		assert(#seenFirst == 1 and #seenSecond == 1, "one urgent lane took both ticks")

		tickerMock.Tick(6)
		assert(#seenFirst == 4 and #seenSecond == 4, "and both drain")
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
				tickerMock.Advance(DEAR_MS)
			end)
		end

		tickerMock.Tick(3)
		assert(#seen[1] == 1 and #seen[2] == 1 and #seen[3] == 1,
			"three ticks must reach all three lanes")

		tickerMock.Tick(3)
		assert(#seen[1] == 2 and #seen[2] == 2 and #seen[3] == 2, "everything drains")
	end)

	fw.it("one lane abandoning leaves the other running", function()
		local laneA = sweep:New()
		local laneB = sweep:New()
		local seenB, collectB = Collector(DEAR_MS)

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
		local seenA, collectA = Collector(DEAR_MS)
		local seenB, collectB = Collector(DEAR_MS)

		laneA:Run(Items(6), collectA)
		laneB:Run(Items(3), collectB)
		tickerMock.Tick(1)

		-- Whichever lane the tick fell to, the replaced run is finished here.
		local beforeReplace = #seenA
		local replaced, collectReplaced = Collector(DEAR_MS)
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
		local replaced, collectReplaced = Collector(DEAR_MS)
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
