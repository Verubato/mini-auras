---@type string, Addon
local _, addon = ...
local sweep = addon.Core.Sweep

-- Generic object pool with staggered pre-creation. Nothing here knows about auras or frames: an
-- item is whatever createFn returns, and resetFn parks one for reuse.

---@class Pool
local M = {}
M.__index = M

addon.Core.Pool = M

---Whether an item is still parked. The free list is small and this runs a couple of times per
---tick, so a linear scan beats bookkeeping on every acquire and release.
---@param pool Pool
---@param item table
---@return boolean
local function IsFree(pool, item)
	for _, freeItem in ipairs(pool.Free) do
		if freeItem == item then
			return true
		end
	end

	return false
end

---Builds one pre-created item, from the walker. The pool is asked what it still owes at fire
---time: a fill runs over seconds, and acquires during it have already counted towards the target.
---@param _ any The queue slot, which carries nothing.
---@param pool Pool
---@return boolean? keepGoing
local function BuildOne(_, pool)
	if pool.Created >= pool.Target then
		return false
	end

	pool.Created = pool.Created + 1

	local produce = pool.ArgsFn
	local item = produce and pool.Create(produce(pool.ArgsCtx)) or pool.Create()

	pool.Reset(item)
	pool.Free[#pool.Free + 1] = item
end

---@param createFn fun(...): table Builds one item, from whatever Acquire was given.
---@param resetFn fun(item: table) Parks an item (disable, hide, unanchor).
---@param preallocateCount number Initial pre-creation target.
---@return Pool
function M:New(createFn, resetFn, preallocateCount)
	local instance = setmetatable({}, M)

	instance.Create = createFn
	instance.Reset = resetFn
	instance.Free = {}
	instance.Target = preallocateCount or 0
	instance.Created = 0

	return instance
end

---Arguments are forwarded to createFn, and only reach it when the pool is empty and an item
---has to be built on the spot. That is the one moment a caller can influence how an item is
---made, which matters for anything that cannot be changed afterwards.
---
---Demand outrunning the pool costs a frame spike here rather than failing the acquire.
---@param ... any Passed to createFn.
---@return table item
function M:Acquire(...)
	local item = table.remove(self.Free)

	if not item then
		-- Counted like a pre-created one. Created is how many the pool has ever built, not how
		-- many are sitting free, so a burst that outran the pool must not leave Prewarm still
		-- owing the full target and building a second set on top of the ones in circulation.
		self.Created = self.Created + 1
		item = self.Create(...)
	end

	return item
end

---Acquire that only reuses a free item the matcher accepts, building fresh otherwise even when
---free items remain. For the moments an item's baked-in make-up cannot be corrected after the
---fact, where plain Acquire's any-free-item answer would hand back one that cannot be fixed up.
---Most recently released items are tried first, like Acquire takes them.
---@param matchFn fun(item: table, ...): boolean
---@param ... any Passed to matchFn alongside each candidate, and to createFn on a build.
---@return table item
function M:AcquireMatching(matchFn, ...)
	local free = self.Free

	for index = #free, 1, -1 do
		local item = free[index]

		if matchFn(item, ...) then
			table.remove(free, index)

			return item
		end
	end

	self.Created = self.Created + 1

	return self.Create(...)
end

---@param item table
function M:Release(item)
	self.Reset(item)
	self.Free[#self.Free + 1] = item
end

---Starts (or resumes) staggered pre-creation. Safe to call on every enable: it no-ops once the
---pool is full or while a fill is already running. Pass targetCount to raise the target when
---demand grows (e.g. the user enables a second bar, doubling displays per nameplate); it never
---lowers it, since the extra items are already built.
---
---Filling is staggered through the shared background walker so login does not hitch, and one
---walker for the whole addon means the pools take turns rather than every module filling at once.
---Call this from the module's enable path. A pool never fills itself, because modules Init
---unconditionally and one that did would build a screen's worth of objects for a module the user
---has switched off.
---@param targetCount number?
---@param argsFn (fun(argsCtx: any): ...)? Produces createFn's arguments for each item a fill
---builds, called at build time so the values come out fresh rather than captured, since the fill
---is staggered over seconds, longer than any shared scratch survives. The latest pair given wins
---for the items still to come; without one ever given, createFn is called bare.
---@param argsCtx any? Handed to argsFn, so callers can pass a hoisted function and its context
---instead of allocating a closure per call.
function M:Prewarm(targetCount, argsFn, argsCtx)
	if targetCount and targetCount > self.Target then
		self.Target = targetCount
	end

	if argsFn then
		self.ArgsFn = argsFn
		self.ArgsCtx = argsCtx
	end

	local owed = self.Target - self.Created

	if owed <= 0 then
		return
	end

	if not self.FillSweep then
		self.FillSweep = sweep:New()
	end

	-- One queue slot per item still owed, re-counted here rather than resumed: a repeat call is
	-- what raises the target, and what the pool owes may have shrunk since the last one (an
	-- acquire that outran the fill counts as a build).
	local queue = {}

	for index = 1, owed do
		queue[index] = index
	end

	self.FillSweep:Run(queue, BuildOne, self)
end

---Walks the parked items through refreshFn in the background, on the same paced walker as the
---pre-creation fill, so a look change converges onto the free list while nothing it holds is on
---screen. The sweep visits newest items first, the same end Acquire and AcquireMatching take
---from, so a sweep capped by maxItems spends its visits on exactly the items the next acquires
---will reach for. A later call on the same lane replaces a sweep still in flight, and refreshFn
---returning false abandons the sweep ("cannot restyle right now"). Either way the acquire path
---remains the guarantee, and this is only a warm-up.
---@param refreshFn fun(item: table, refreshCtx: any): boolean? Returns false to abandon the sweep.
---@param refreshCtx any? Handed back to refreshFn, like Prewarm's argsCtx.
---@param maxItems number? Cap on items visited; defaults to the whole free list.
---@param lane Sweep? A caller-owned lane, for consumers that share one pool but must not
---replace each other's sweeps (one lane per look-owner). Defaults to the pool's own lane.
function M:RefreshFree(refreshFn, refreshCtx, maxItems, lane)
	local free = self.Free
	local count = #free

	if maxItems and maxItems < count then
		count = maxItems
	end

	local queue = {}

	for index = 1, count do
		queue[index] = free[#free + 1 - index]
	end

	if not lane then
		if not self.Sweep then
			self.Sweep = sweep:New()
		end

		lane = self.Sweep
	end

	-- A closure per call rather than hoisted state on the pool: sweeps start at config-change
	-- frequency, and pool-level fn/ctx fields would let one caller silently retarget another's
	-- in-flight run.
	local pool = self
	lane:Run(queue, function(item)
		-- An item acquired since the sweep began belongs to someone now; touching it would
		-- fight its owner. It gets the current look through the acquire path instead.
		if not IsFree(pool, item) then
			return
		end

		return refreshFn(item, refreshCtx)
	end)
end

---@class Pool
---@field Create fun(): table
---@field Reset fun(item: table)
---@field Free table[]
---@field Target number
---@field Created number
---@field FillSweep Sweep?
---@field ArgsFn (fun(argsCtx: any): ...)?
---@field ArgsCtx any?
---@field Sweep Sweep?
