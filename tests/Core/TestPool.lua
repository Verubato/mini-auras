-- Background sweep over a pool's parked items (RefreshFree). The failure this guards against:
-- parked containers keep the look they were released with, and under 12.1 restriction a reuse
-- can only match that baked look, so the sweep is what keeps a prewarmed pool useful after a
-- settings change. The sweep must never touch an item somebody has since acquired.

local fw = require("Framework")
local workerMock = require("WorkerMock")

workerMock.Install()

local addon = workerMock.Addon()
-- Sweep first: Pool imports it at file scope, exactly like the TOC orders them.
assert(loadfile("src/Core/Pooling/Sweep.lua"))("MiniAuras", addon)
assert(loadfile("src/Core/Pooling/Pool.lua"))("MiniAuras", addon)
local pool = addon.Core.Pool
local sweep = addon.Core.Sweep

local function NewItemPool()
	local counter = 0

	return pool:New(function()
		counter = counter + 1

		return { id = counter }
	end, function() end, 0)
end

---Builds a pool with `count` items parked in creation order, so item ids match free-list order
---(id `count` is the newest, the one Acquire takes first).
local function PoolWithParked(count)
	local instance = NewItemPool()
	local items = {}

	for index = 1, count do
		items[index] = instance:Acquire()
	end

	for index = 1, count do
		instance:Release(items[index])
	end

	return instance
end

---@param ms number? What each visit spends of the sweep's frame budget; free by default, which
---lets one frame drain the whole free list.
local function Collector(ms)
	local seen = {}

	return seen, function(item)
		seen[#seen + 1] = item.id

		if ms then
			workerMock.Advance(ms)
		end
	end
end

fw.describe("Pool - RefreshFree", function()
	fw.before_each(workerMock.Reset)

	fw.it("sweeps every parked item in the background, then stops", function()
		local instance = PoolWithParked(5)
		local seen, collect = Collector()

		instance:RefreshFree(collect)
		assert(#seen == 0, "the sweep ran inline instead of waiting for a frame")

		workerMock.Frames(1)
		assert(#seen == 5, "the whole free list visited, got " .. #seen)
		assert(workerMock.ActiveCount() == 0, "the sweep worker stopped once the queue drained")

		workerMock.Frames(3)
		assert(#seen == 5, "a finished sweep does nothing more")
	end)

	fw.it("visits the newest items first and honours the maxItems cap", function()
		-- Acquire and AcquireMatching take from the newest end, so a capped sweep must spend its
		-- visits on the items the next acquires will actually reach for.
		local instance = PoolWithParked(5)
		local seen, collect = Collector()

		instance:RefreshFree(collect, nil, 2)
		workerMock.Frames(5)

		assert(#seen == 2, "capped at two items")
		assert(seen[1] == 5 and seen[2] == 4, "the newest parked items, the next to be acquired")
	end)

	fw.it("abandons the sweep when refreshFn says so", function()
		local instance = PoolWithParked(4)
		local seen = {}

		instance:RefreshFree(function(item)
			if item.id == 3 then
				return false
			end

			seen[#seen + 1] = item.id
		end)
		workerMock.Frames(5)

		assert(#seen == 1, "nothing visited past the refusal")
		assert(workerMock.ActiveCount() == 0, "an abandoned sweep does not keep running")
	end)

	fw.it("skips items acquired after the sweep began", function()
		local instance = PoolWithParked(4)
		local seen, collect = Collector()

		instance:RefreshFree(collect)

		-- Acquire takes the newest parked item, which is also the sweep's first stop.
		local taken = instance:Acquire()
		assert(taken.id == 4, "acquire hands out the newest item")

		workerMock.Frames(5)
		assert(#seen == 3, "the acquired item was passed over")
		assert(seen[1] == 3, "the remaining parked items still swept")
	end)

	fw.it("a later sweep replaces the one in flight", function()
		local instance = PoolWithParked(4)
		-- Dear enough that the first sweep is still only one item in when it is replaced.
		local first, collectFirst = Collector(1.25)
		local second, collectSecond = Collector()

		instance:RefreshFree(collectFirst)
		workerMock.Frames(1)
		local beforeReplace = #first
		assert(beforeReplace > 0, "first sweep under way")

		instance:RefreshFree(collectSecond)
		workerMock.Frames(5)

		assert(#first == beforeReplace, "replaced sweep never resumed")
		assert(#second == 4, "replacement started over")
		assert(workerMock.ActiveCount() == 0, "one worker served both sweeps and stopped")
	end)

	fw.it("caller-owned lanes let two owners sweep one pool without clobbering", function()
		-- The pool's default lane is last-writer-wins by design. Owners that share a pool (the
		-- PersonalAuras shape pools) pass their own lane so a second owner's sweep cannot replace
		-- the first's mid-run.
		local instance = PoolWithParked(6)
		local seenA, collectA = Collector()
		local seenB, collectB = Collector()

		instance:RefreshFree(collectA, nil, 3, sweep:New())
		instance:RefreshFree(collectB, nil, 3, sweep:New())
		workerMock.Frames(6)

		assert(#seenA == 3, "the first owner's sweep ran to completion")
		assert(#seenB == 3, "alongside the second owner's")
		assert(workerMock.ActiveCount() == 0)
	end)

	fw.it("an empty free list wakes no worker", function()
		local instance = NewItemPool()
		local seen, collect = Collector()

		instance:RefreshFree(collect)

		assert(workerMock.ActiveCount() == 0, "nothing to sweep, nothing scheduled")
		assert(#seen == 0)
	end)
end)
