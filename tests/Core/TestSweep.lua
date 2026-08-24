-- The shared background walker's lane model. The failures this guards against:
--   * a frame spends a millisecond budget rather than a count of items, so a lane of cheap items
--     drains many at once while a lane of dear ones takes a frame each,
--   * a lane is weighed by the worst item it has run lately, so a stretch of cheap ones cannot
--     let a dear one in behind them,
--   * one lane replacing or abandoning its run must never touch another lane's,
--   * the stop check must not consume a busy lane's round-robin turn,
--   * only one item may overrun a frame however many passes want one,
--   * nothing may be spent behind a loading screen, where the client charges it to the frame the
--     screen drops on.

local fw = require("Framework")
local workerMock = require("WorkerMock")

workerMock.Install()

local addon = workerMock.Addon()
assert(loadfile("src/Core/Pooling/Sweep.lua"))("MiniAuras", addon)
local sweep = addon.Core.Sweep

-- Eight of these spend a frame's whole slice, so a test can say where its frame ends.
local CHEAP_MS = 0.25
-- More than half a slice, so a lane that has run one cannot fit another behind it. Stands in for
-- the one item that really costs anything here: an aura group, declared with its whole batch of
-- buttons in a single engine call.
local DEAR_MS = 1.25
-- Seconds of frame that buy a millisecond of background credit, for the tests that watch the rate
-- hold over many frames rather than what one frame carries.
local TRICKLE_ELAPSED = 0.05
-- Barely any credit a frame, for telling the two allowances apart: the on-demand one buys three
-- times what the background one does.
local STARVED_ELAPSED = 0.01
-- Dearer than a whole frame slice, which is what a container build really is. One of these may
-- overrun a frame. A second one may not follow it.
local OVERRUN_MS = 3

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
			workerMock.Advance(ms)
		end
	end
end

-- Every lane this suite builds. Lanes are never removed from the walker, so one left with work
-- queued would spend the next test's frames on it.
local createdLanes = {}

---@param urgent boolean?
---@return Sweep
local function NewLane(urgent)
	local lane = sweep:New(urgent)
	createdLanes[#createdLanes + 1] = lane

	return lane
end

-- A lane of one free item, for putting the walker into a known state between tests: the background
-- credit is carried across frames on purpose, so a test that left it overdrawn would otherwise
-- decide how much the next one gets.
local idleLane = NewLane()

fw.describe("Sweep - a time budget shared across the lanes", function()
	fw.before_each(function()
		workerMock.Reset()

		for _, lane in ipairs(createdLanes) do
			lane:Stop()
		end

		-- One free frame: it puts the worker back to sleep, takes any burst down with it, and
		-- leaves the background credit refilled to its cap.
		idleLane:Run({ 1 }, function() end)
		workerMock.Frame()
	end)

	fw.it("a lane of cheap items drains several a frame and the worker stops on drain", function()
		local lane = NewLane()
		local seen, collect = Collector(CHEAP_MS)

		lane:Run(Items(12), collect)

		workerMock.Frame()
		assert(#seen == 8, "a frame runs cheap items until the credit is gone, got " .. #seen)

		workerMock.Frame()
		assert(#seen == 12, "queue drained")
		assert(workerMock.ActiveCount() == 0, "worker stopped with nothing left to do")
	end)

	fw.it("a lane whose items cost more than the budget takes one a frame", function()
		-- Building a container full of buttons outweighs a whole background frame on its own. It
		-- has to run anyway, so it runs as the frame's first item, with nothing chained behind it.
		local lane = NewLane()
		local seen, collect = Collector(5)

		lane:Run(Items(3), collect)

		workerMock.Frame()
		assert(#seen == 1, "an item dearer than the budget was not left alone in its frame")

		workerMock.Frames(2)
		assert(#seen == 3, "the rest still drain, a frame apart")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("the background rate holds however dear a lane's items are", function()
		-- The whole point of spending credit rather than capping each frame: an item cannot be
		-- split, so one that overruns has to be paid for out of the frames after it. Twenty
		-- milliseconds of credit buys twenty milliseconds of work, in items of any size.
		local lane = NewLane()
		local seen, collect = Collector(DEAR_MS)

		lane:Run(Items(20), collect)

		workerMock.Frames(20, TRICKLE_ELAPSED)

		-- A second of credit plus the slice already banked, in items of a millisecond and a
		-- quarter.
		assert(#seen == 17, "a second of trickle spent more than its allowance, got " .. #seen)
		assert(workerMock.ActiveCount() == 1, "the rest is still queued")
	end)

	fw.it("a cheap stretch does not open the door to a lane's dear items", function()
		-- The regression the whole design exists for. A lane is weighed by the worst it has seen
		-- lately, not its average: an average sits near the cheap no-op turns it has just done and
		-- barely moves when the first real container build lands, leaving room for the next one
		-- behind it, which is how one frame came out at fifteen milliseconds.
		local lane = NewLane()
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
			workerMock.Advance(item.cost)
		end)

		for _ = 1, 6 do
			local before = #seen

			workerMock.Frame()

			local dear = 0

			for index = before + 1, #seen do
				if seen[index].cost == DEAR_MS then
					dear = dear + 1
				end
			end

			assert(dear == 0 or #seen - before == 1,
				"a dear item shared its frame with " .. (#seen - before - 1) .. " others")
		end

		assert(#seen == 12, "the lane drained, got " .. #seen)
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("a dear lane never doubles up, and a cheap one keeps draining around it", function()
		local cheap = NewLane()
		local dear = NewLane()
		local cheapSeen, collectCheap = Collector(CHEAP_MS)
		local dearSeen, collectDear = Collector(DEAR_MS)
		local shared = false

		cheap:Run(Items(12), collectCheap)
		dear:Run(Items(4), collectDear)

		for _ = 1, 8 do
			local beforeDear = #dearSeen
			local beforeCheap = #cheapSeen

			workerMock.Frame()

			assert(#dearSeen - beforeDear <= 1, "two dear items landed in the same frame")

			shared = shared or (#dearSeen > beforeDear and #cheapSeen > beforeCheap)
		end

		assert(shared, "the cheap lane never got the rest of a frame a dear item started")
		assert(#dearSeen == 4 and #cheapSeen == 12, "both lanes drained")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("a lane that has never run waits for a frame of its own", function()
		-- Until a lane has shown what its items cost it counts as dear, because the one thing it
		-- must not do is turn out to be a container build halfway through someone else's frame.
		local first = NewLane()
		local second = NewLane()
		local seenFirst, collectFirst = Collector(DEAR_MS)
		local seenSecond, collectSecond = Collector(DEAR_MS)

		first:Run(Items(2), collectFirst)
		second:Run(Items(2), collectSecond)

		workerMock.Frame()
		assert(#seenFirst + #seenSecond == 1, "the untried lane took a slot on trust")

		workerMock.Frames(3)
		assert(#seenFirst == 2 and #seenSecond == 2, "and both drain over the frames after it")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("an item can ask to be handed back until it is finished", function()
		-- What the display prewarms need: building a container is too big for one slot, so the
		-- item comes back for its next piece rather than the lane moving on, and the budget is
		-- weighed between the pieces.
		local lane = NewLane()
		local seen = {}
		local parts = {}

		lane:Run(Items(2), function(item)
			seen[#seen + 1] = item.id
			parts[item.id] = (parts[item.id] or 0) + 1
			workerMock.Advance(DEAR_MS)

			if parts[item.id] < 2 then
				return sweep.Verdict.Unfinished
			end
		end)

		workerMock.Frames(4)

		assert(#seen == 4, "each item ran twice, got " .. #seen)
		assert(seen[1] == 1 and seen[2] == 1 and seen[3] == 2 and seen[4] == 2,
			"an unfinished item finishes before the next one starts")
		assert(workerMock.ActiveCount() == 0, "the worker stopped once both were done")
	end)

	fw.it("an urgent lane spends an allowance of its own, not the background one", function()
		-- What the on-demand displays hold: a plate is on screen waiting for its groups, while the
		-- ordinary lanes are preparing spares nobody has asked for. The plate must not be paced by
		-- what those spares have left.
		local spare = NewLane()
		local urgent = NewLane(true)
		local seenSpare, collectSpare = Collector(DEAR_MS)
		local seenUrgent, collectUrgent = Collector(DEAR_MS)

		spare:Run(Items(30), collectSpare)
		urgent:Run(Items(30), collectUrgent)

		-- Frames thin enough that both lanes are living off their allowance rather than the slice.
		workerMock.Frames(40, STARVED_ELAPSED)

		assert(#seenUrgent >= #seenSpare * 2,
			"the on-demand lane ran " .. #seenUrgent .. " to the background lane's " .. #seenSpare)

		workerMock.Frames(40)
		assert(#seenUrgent == 30 and #seenSpare == 30, "both drain")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("two urgent lanes take turns rather than the older one taking everything", function()
		-- Every module with something on screen holds an urgent lane, so picking the first one in
		-- the list every time would hand every frame to whichever module loaded first.
		local first = NewLane(true)
		local second = NewLane(true)
		local seenFirst, collectFirst = Collector(DEAR_MS)
		local seenSecond, collectSecond = Collector(DEAR_MS)

		first:Run(Items(4), collectFirst)
		second:Run(Items(4), collectSecond)

		-- Two frames, not one: an untried lane only ever gets the first slot of a pass, so the
		-- second of them cannot show until the first has said what its items cost.
		workerMock.Frames(2)
		assert(#seenFirst > 0 and #seenSecond > 0, "one urgent lane took every frame")

		workerMock.Frames(6)
		assert(#seenFirst == 4 and #seenSecond == 4, "and both drain")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("a third busy lane is not starved by the stop check", function()
		-- The end-of-frame "should the worker stop" question must peek without advancing the
		-- round-robin cursor. Asking through the consuming lookup ate one lane's turn per frame,
		-- so with three busy lanes the third never ran until the others drained.
		local seen = {}

		for index = 1, 3 do
			local lane = NewLane()
			local laneSeen = {}
			seen[index] = laneSeen

			lane:Run(Items(2), function(item)
				laneSeen[#laneSeen + 1] = item.id
				workerMock.Advance(DEAR_MS)
			end)
		end

		workerMock.Frames(3)
		assert(#seen[1] >= 1 and #seen[2] >= 1 and #seen[3] >= 1,
			"three frames must reach all three lanes")

		workerMock.Frames(4)
		assert(#seen[1] == 2 and #seen[2] == 2 and #seen[3] == 2, "everything drains")
	end)

	fw.it("one lane abandoning leaves the other running", function()
		local laneA = NewLane()
		local laneB = NewLane()
		local seenB, collectB = Collector(DEAR_MS)

		laneA:Run(Items(4), function()
			return false
		end)
		laneB:Run(Items(3), collectB)

		workerMock.Frames(5)
		assert(#seenB == 3, "the abandoning lane took its own queue down, not its neighbour's")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("a lane's Run replaces only its own queue", function()
		local laneA = NewLane()
		local laneB = NewLane()
		local seenA, collectA = Collector(DEAR_MS)
		local seenB, collectB = Collector(DEAR_MS)

		laneA:Run(Items(6), collectA)
		laneB:Run(Items(3), collectB)
		workerMock.Frame()

		-- Whichever lane the frame fell to, the replaced run is finished here.
		local beforeReplace = #seenA
		local replaced, collectReplaced = Collector(DEAR_MS)
		laneA:Run(Items(2), collectReplaced)

		workerMock.Frames(6)
		assert(#seenA == beforeReplace, "the replaced run never resumed")
		assert(#replaced == 2, "the replacement ran from its start")
		assert(#seenB == 3, "the other lane was untouched")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("a processFn replacing its own lane's run keeps the replacement", function()
		-- The abandon check must compare against the queue the item came from: a processFn may
		-- Run a replacement on its own lane and then return false to kill the old run, and
		-- stopping the lane afterwards would silently destroy the queue it just installed.
		local lane = NewLane()
		local replaced, collectReplaced = Collector(DEAR_MS)
		local sawOldRun = false

		lane:Run(Items(3), function()
			sawOldRun = true
			lane:Run(Items(2), collectReplaced)

			return false
		end)

		workerMock.Frames(3)
		assert(sawOldRun, "the old run's first item fired")
		assert(#replaced == 2, "the replacement survived the abandoning return")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("an empty queue neither wakes the worker nor disturbs the others", function()
		local lane = NewLane()
		local seen, collect = Collector()

		lane:Run(Items(0), collect)

		assert(workerMock.ActiveCount() == 0, "nothing to do, nothing scheduled")
		assert(#seen == 0)
	end)

	fw.it("nothing is spent behind a loading screen", function()
		-- No frame is being drawn, so the client charges whatever runs here to the frame the screen
		-- drops on, which is the one frame the pacing exists to protect.
		local lane = NewLane()
		local seen, collect = Collector(CHEAP_MS)

		lane:Run(Items(12), collect)
		workerMock.SetLoadingScreen(true)

		workerMock.Frames(5)
		assert(#seen == 0, "the screen was up and " .. #seen .. " items ran anyway")

		workerMock.SetLoadingScreen(false)
		workerMock.Frame()
		assert(#seen == 8, "and the queue picks up where it left off, got " .. #seen)

		lane:Stop()
	end)

	fw.it("only one item may overrun a frame, whichever pass it came from", function()
		-- The slice is what keeps a frame short, so the two passes have to weigh against each
		-- other: an urgent container build followed by a background one that started because its
		-- own pass looked empty would put both in the frame the pacing exists to protect.
		local spare = NewLane()
		local urgent = NewLane(true)
		local seenSpare, collectSpare = Collector(OVERRUN_MS)
		local seenUrgent, collectUrgent = Collector(OVERRUN_MS)

		spare:Run(Items(4), collectSpare)
		urgent:Run(Items(4), collectUrgent)

		workerMock.Frame()

		assert(#seenSpare + #seenUrgent == 1,
			"one frame carried " .. (#seenSpare + #seenUrgent) .. " items dearer than its slice")

		workerMock.Frames(12)
		assert(#seenSpare == 4 and #seenUrgent == 4, "both still drain")
		assert(workerMock.ActiveCount() == 0)
	end)
end)
