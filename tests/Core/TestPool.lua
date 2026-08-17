-- Background sweep over a pool's parked items (RefreshFree). The failure this guards against:
-- parked containers keep the look they were released with, and under 12.1 restriction a reuse
-- can only match that baked look, so the sweep is what keeps a prewarmed pool useful after a
-- settings change. The sweep must never touch an item somebody has since acquired.

local fw = require("Framework")
local tickerMock = require("TickerMock")

tickerMock.Install()

local addon = { Core = {} }
-- Sweep first: Pool imports it at file scope, exactly like the TOC orders them.
assert(loadfile("src/Core/Sweep.lua"))("MiniAuras", addon)
assert(loadfile("src/Core/Pool.lua"))("MiniAuras", addon)
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

local function Collector()
	local seen = {}

	return seen, function(item)
		seen[#seen + 1] = item.id
	end
end

fw.describe("Pool - RefreshFree", function()
	fw.before_each(tickerMock.Reset)

	fw.it("sweeps every parked item a couple per tick, then stops", function()
		local instance = PoolWithParked(5)
		local seen, collect = Collector()

		instance:RefreshFree(collect)

		tickerMock.Tick(1)
		assert(#seen == 2, "two items per tick")

		tickerMock.Tick(2)
		assert(#seen == 5, "the whole free list visited")
		assert(tickerMock.ActiveCount() == 0, "sweep ticker stopped once the queue drained")

		tickerMock.Tick(3)
		assert(#seen == 5, "a finished sweep does nothing more")
	end)

	fw.it("visits the newest items first and honours the cap", function()
		-- Acquire and AcquireMatching take from the newest end, so a capped sweep must spend its
		-- budget on the items the next acquires will actually reach for.
		local instance = PoolWithParked(5)
		local seen, collect = Collector()

		instance:RefreshFree(collect, nil, 2)
		tickerMock.Tick(5)

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
		tickerMock.Tick(5)

		assert(#seen == 1, "nothing visited past the refusal")
		assert(tickerMock.ActiveCount() == 0, "an abandoned sweep does not keep ticking")
	end)

	fw.it("skips items acquired after the sweep began", function()
		local instance = PoolWithParked(4)
		local seen, collect = Collector()

		instance:RefreshFree(collect)

		-- Acquire takes the newest parked item, which is also the sweep's first stop.
		local taken = instance:Acquire()
		assert(taken.id == 4, "acquire hands out the newest item")

		tickerMock.Tick(5)
		assert(#seen == 3, "the acquired item was passed over")
		assert(seen[1] == 3, "the remaining parked items still swept")
	end)

	fw.it("a later sweep replaces the one in flight", function()
		local instance = PoolWithParked(4)
		local first, collectFirst = Collector()
		local second, collectSecond = Collector()

		instance:RefreshFree(collectFirst)
		tickerMock.Tick(1)
		assert(#first == 2, "first sweep under way")

		instance:RefreshFree(collectSecond)
		tickerMock.Tick(5)

		assert(#first == 2, "replaced sweep never resumed")
		assert(#second == 4, "replacement started over")
		assert(tickerMock.ActiveCount() == 0, "one ticker served both sweeps and stopped")
	end)

	fw.it("caller-owned lanes let two owners sweep one pool without clobbering", function()
		-- The pool's default lane is last-writer-wins by design; owners that share a pool (the
		-- CustomAuras shape pools) pass their own lane so a second owner's sweep cannot replace
		-- the first's mid-run.
		local instance = PoolWithParked(6)
		local seenA, collectA = Collector()
		local seenB, collectB = Collector()

		instance:RefreshFree(collectA, nil, 3, sweep:New())
		instance:RefreshFree(collectB, nil, 3, sweep:New())
		tickerMock.Tick(6)

		assert(#seenA == 3, "the first owner's sweep ran to completion")
		assert(#seenB == 3, "alongside the second owner's")
		assert(tickerMock.ActiveCount() == 0)
	end)

	fw.it("an empty free list starts no ticker", function()
		local instance = NewItemPool()
		local seen, collect = Collector()

		instance:RefreshFree(collect)

		assert(tickerMock.ActiveCount() == 0, "nothing to sweep, nothing scheduled")
		assert(#seen == 0)
	end)
end)
