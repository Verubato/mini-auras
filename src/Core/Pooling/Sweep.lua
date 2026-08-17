---@type string, Addon
local _, addon = ...

-- Staggered background walker shared by the display caches: a queue of parked items is run
-- through a callback a couple at a time, so a look change converges on frames nobody can see
-- without billing any single frame for the lot. Sweeps are warm-ups by contract: whoever owns
-- the items must also correct them lazily on use, because a run can be replaced or abandoned at
-- any point, and callers re-validate each item in the callback - the world moves while it runs.
--
-- Each consumer holds its own lane (New), but the budget is addon-wide: one ticker spends
-- ITEMS_PER_TICK across every lane with work, round-robin, so the total background cost stays
-- flat no matter how many modules queue a sweep at once. A lane's Run only ever replaces that
-- lane's own queue.

-- How many items each tick processes across ALL lanes, and how often ticks run. Matches the
-- pre-creation fill in Core/Pooling/Pool: restyles are cheaper than creation, so the same pace
-- is comfortably invisible.
local ITEMS_PER_TICK = 2
local TICK_INTERVAL = 0.1

-- Every lane ever created. Lanes are one per consumer per session and never removed; a drained
-- lane costs one has-work check per scan.
local lanes = {}
local ticker = nil
-- Round-robin cursor into lanes, persisted across ticks so a busy lane cannot starve the rest.
local cursor = 1

---@class Sweep
local M = {}
M.__index = M

addon.Core.Sweep = M

---@param lane Sweep
---@return boolean
local function LaneHasWork(lane)
	return lane.Queue ~= nil and lane.Queue[lane.Next] ~= nil
end

---@param lane Sweep
local function StopLane(lane)
	lane.Queue = nil
	lane.ProcessFn = nil
	lane.Ctx = nil
end

---The next lane with something to do, advancing the cursor past it; nil once a full circle
---finds nothing.
---@return Sweep?
local function NextLaneWithWork()
	for _ = 1, #lanes do
		local lane = lanes[cursor]
		cursor = cursor % #lanes + 1

		if LaneHasWork(lane) then
			return lane
		end
	end

	return nil
end

---A peek that leaves the cursor alone, for the end-of-tick stop check. Asking through
---NextLaneWithWork there would consume a busy lane's turn and starve it for the whole sweep.
---@return boolean
local function AnyLaneHasWork()
	for _, lane in ipairs(lanes) do
		if LaneHasWork(lane) then
			return true
		end
	end

	return false
end

local function Tick()
	for _ = 1, ITEMS_PER_TICK do
		local lane = NextLaneWithWork()

		if not lane then
			break
		end

		local queue = lane.Queue
		local item = queue[lane.Next]
		lane.Next = lane.Next + 1

		local abandoned = lane.ProcessFn(item, lane.Ctx) == false

		-- Only while the run is still the one this item came from: a processFn may Run a
		-- replacement on its own lane, and stopping then would silently kill the new queue.
		if lane.Queue == queue and (abandoned or not LaneHasWork(lane)) then
			StopLane(lane)
		end
	end

	if ticker and not AnyLaneHasWork() then
		ticker:Cancel()
		ticker = nil
	end
end

---@return Sweep A lane of the shared walker; hold one per consumer.
function M:New()
	local lane = setmetatable({}, M)
	lanes[#lanes + 1] = lane

	return lane
end

---Starts this lane over, replacing any run of its own still in flight; the old queue is
---dropped, never resumed. Other lanes are untouched. processFn(item, ctx) runs per item and
---returns false to abandon the whole run ("cannot do this right now").
---@param queue table[] Items to visit, in order. The lane owns the array from here on.
---@param processFn fun(item: table, ctx: any): boolean?
---@param ctx any?
function M:Run(queue, processFn, ctx)
	self.Queue = queue
	self.Next = 1
	self.ProcessFn = processFn
	self.Ctx = ctx

	if #queue == 0 then
		StopLane(self)
		return
	end

	if not ticker then
		ticker = C_Timer.NewTicker(TICK_INTERVAL, Tick)
	end
end

function M:Stop()
	StopLane(self)
end

---@class Sweep
---@field Queue table[]?
---@field Next number?
---@field ProcessFn (fun(item: table, ctx: any): boolean?)?
---@field Ctx any?
