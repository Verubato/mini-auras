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
		assert(workerMock.ActiveCount() == 0, "both lanes drained and the worker stopped")
	end)

	fw.it("an empty free list wakes no worker", function()
		-- An item Acquire failed to unpark would still be here for the sweep to hand over.
		local instance = PoolWithParked(1)
		local _, collect = Collector()

		instance:Acquire()
		instance:RefreshFree(collect)

		assert(workerMock.ActiveCount() == 0, "nothing to sweep, nothing scheduled")
	end)
end)

fw.describe("Pool - reuse under pressure", function()
	fw.before_each(workerMock.Reset)

	---@param instance Pool
	---@param count number
	---@return table[] taken In the order the pool handed them over.
	local function AcquireMany(instance, count)
		local taken = {}

		for index = 1, count do
			taken[index] = instance:Acquire()
		end

		return taken
	end

	---@param items table[]
	---@return boolean
	local function AllDistinct(items)
		local seen = {}

		for _, item in ipairs(items) do
			if seen[item] then
				return false
			end

			seen[item] = true
		end

		return true
	end

	fw.it("builds on the spot once the free list runs dry", function()
		local instance = PoolWithParked(3)
		local taken = AcquireMany(instance, 5)

		assert(AllDistinct(taken), "a burst past the free list handed one item out twice")
		assert(#instance.Free == 0, "nothing is left parked, got " .. #instance.Free)
		assert(instance.Created == 5, "the two extras count as builds, got " .. instance.Created)
	end)

	fw.it("takes the whole set back and hands it out again without building", function()
		local instance = PoolWithParked(3)
		local taken = AcquireMany(instance, 5)

		for _, item in ipairs(taken) do
			instance:Release(item)
		end

		assert(#instance.Free == 5, "every released item is parked, got " .. #instance.Free)

		local again = AcquireMany(instance, 5)

		assert(AllDistinct(again), "the second round handed one item out twice")
		assert(instance.Created == 5, "the second round built nothing, got " .. instance.Created)
	end)

	fw.it("never hands a live item to a second caller", function()
		local instance = PoolWithParked(2)
		local first = instance:Acquire()

		instance:Release(first)

		assert(instance:Acquire() == first, "the parked item comes back")
		assert(instance:Acquire() ~= first, "and not again while somebody is holding it")
	end)

	fw.it("takes a matched item off the free list, so a repeat match builds instead", function()
		local instance = PoolWithParked(2)
		local function MatchAny()
			return true
		end

		local first = instance:AcquireMatching(MatchAny)
		local second = instance:AcquireMatching(MatchAny)
		local third = instance:AcquireMatching(MatchAny)

		assert(first ~= second, "two matching acquires must not share one item")
		assert(third ~= first and third ~= second, "an empty free list builds rather than repeats")
		assert(instance.Created == 3, "one build once the parked pair ran out, got " .. instance.Created)
	end)
end)
