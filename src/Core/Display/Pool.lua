---@type string, Addon
local _, addon = ...

-- Generic object pool with staggered pre-creation. Nothing here knows about auras or frames -
-- an "item" is whatever createFn returns (a single display, a bundle of displays, a table of
-- widgets), and resetFn parks one for reuse.
--
-- Pre-creation is staggered on a timer so login doesn't hitch, and the expensive objects this
-- pool exists for (12.1 AuraContainers) are therefore never built mid-combat in practice.
-- Acquire falls back to on-demand creation if demand outruns the pool, at the cost of a frame
-- spike, rather than failing.
--
-- Pre-creation does NOT start on its own: modules Init unconditionally, so a pool that filled
-- itself would build a screen's worth of objects for a module the user has switched off. Call
-- Prewarm from the module's enable path instead (it is idempotent and cheap to repeat).

-- How many items each pre-creation tick builds, and how often ticks run. Two per tenth of a
-- second fills a 40-item pool in ~2s without a visible hitch.
local ITEMS_PER_TICK = 2
local TICK_INTERVAL = 0.1

---@class Pool
local M = {}
M.__index = M

addon.Core.Pool = M

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
---@param ... any Passed to createFn.
---@return table item
function M:Acquire(...)
	local item = table.remove(self.Free)

	if not item then
		item = self.Create(...)
	end

	return item
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
---@param targetCount number?
function M:Prewarm(targetCount)
	if targetCount and targetCount > self.Target then
		self.Target = targetCount
	end

	if self.Ticker or self.Created >= self.Target then
		return
	end

	self.Ticker = C_Timer.NewTicker(TICK_INTERVAL, function()
		if self.Created >= self.Target then
			self.Ticker:Cancel()
			self.Ticker = nil
			return
		end

		for _ = 1, ITEMS_PER_TICK do
			if self.Created < self.Target then
				self.Created = self.Created + 1
				local item = self.Create()
				self.Reset(item)
				self.Free[#self.Free + 1] = item
			end
		end
	end)
end

---@class Pool
---@field Create fun(): table
---@field Reset fun(item: table)
---@field Free table[]
---@field Target number
---@field Created number
---@field Ticker table?
