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

-- How many items each tick processes across ALL lanes, and how often ticks run. Three is what
-- keeps a lane capped at one item (the pre-creation fills, which build frames) moving at that
-- rate while a couple of restyle lanes are also draining; past that, a login where every module
-- fills at once starts to show.
local ITEMS_PER_TICK = 3
local TICK_INTERVAL = 0.1
-- What a tick may spend before it stops handing out slots. Items vary by two orders of magnitude
-- (a restyle against building a container full of buttons), so a flat count alone let one tick
-- chain three of the expensive kind into a 30ms frame. The first item of a tick always runs -
-- nothing here can split one - so this is what stops the second and third.
local TICK_BUDGET_MS = 1

-- Every lane ever created. Lanes are one per consumer per session and never removed; a drained
-- lane costs one has-work check per scan.
local lanes = {}
local ticker = nil
-- Round-robin cursors into lanes, persisted across ticks so a busy lane cannot starve the rest.
-- One per class of lane, because urgent lanes are picked from before the others and would
-- otherwise all read the same position.
local cursor = 1
local urgentCursor = 1
-- What each lane has taken in the tick being run, so a lane that caps itself cannot be handed
-- the whole budget by the round robin. Cleared at the top of every tick.
local takenThisTick = {}
-- How much of the tick being run is gone, and whether anything has run in it yet. Read by the
-- round robin: the budget cannot split an item, so the only way to keep a tick short is to not
-- start one that is going to overrun it.
local spentThisTick = 0
local tickIsEmpty = true
-- TEMPORARY warm-up progress, for telling by eye when the background build has finished rather
-- than watching a CPU total stop climbing. Items queued and items completed across every lane; the
-- denominator moves as modules queue more, so the percentage can stall rather than run backwards.
local queuedTotal = 0
local doneTotal = 0
local nextMilestone = 10
local warmStarted
-- Off unless asked for with /miniauras warm: the addon prints nothing on a clean load, and this is
-- a diagnostic rather than something a player wants in their chat every zone change.
local reporting = false

---@class Sweep
local M = {}
M.__index = M

addon.Core.Sweep = M

---What a processFn can tell the lane about the item it just saw, beyond finishing it (return
---nothing) or abandoning the run (return false).
---@enum SweepVerdict
M.Verdict = {
	-- The item is not finished: hand it back on this lane's next turn rather than moving on. For
	-- work that cannot fit in one slot, so the tick budget applies between its parts.
	Unfinished = "unfinished",
}

---@param lane Sweep
---@return boolean
local function LaneHasWork(lane)
	return lane.Queue ~= nil and lane.Queue[lane.Next] ~= nil
end

---Whether the round robin may hand this lane another item this tick.
---@param lane Sweep
---@return boolean
local function LaneCanRun(lane)
	if not LaneHasWork(lane) then
		return false
	end

	local cap = lane.MaxPerTick

	if cap and (takenThisTick[lane] or 0) >= cap then
		return false
	end

	-- Past the first item, a lane whose items have been costing more than the tick has left waits
	-- for the next one. The first item always runs, or a lane whose items are dearer than the
	-- whole budget would never run at all.
	if tickIsEmpty then
		return true
	end

	return lane.AvgMs == nil or lane.AvgMs <= TICK_BUDGET_MS - spentThisTick
end

---@param lane Sweep
local function StopLane(lane)
	lane.Queue = nil
	lane.ProcessFn = nil
	lane.Ctx = nil
end

---The next lane with something to do, advancing the cursor past it; nil once a full circle
---finds nothing. Urgent lanes go first: their items are things already on screen waiting to be
---finished, where the rest is work being done ahead of anyone asking for it.
---@return Sweep?
local function NextLaneWithWork()
	for _ = 1, #lanes do
		local lane = lanes[urgentCursor]
		urgentCursor = urgentCursor % #lanes + 1

		if lane.Urgent and LaneCanRun(lane) then
			return lane
		end
	end

	for _ = 1, #lanes do
		local lane = lanes[cursor]
		cursor = cursor % #lanes + 1

		if LaneCanRun(lane) then
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
	for lane in pairs(takenThisTick) do
		takenThisTick[lane] = nil
	end

	local started = debugprofilestop()

	spentThisTick = 0
	tickIsEmpty = true

	for _ = 1, ITEMS_PER_TICK do
		local lane = NextLaneWithWork()

		if not lane then
			break
		end

		local queue = lane.Queue
		local item = queue[lane.Next]
		lane.Next = lane.Next + 1
		takenThisTick[lane] = (takenThisTick[lane] or 0) + 1
		tickIsEmpty = false

		local itemStarted = debugprofilestop()
		local verdict = lane.ProcessFn(item, lane.Ctx)

		-- What this lane's items have been costing, weighted towards the recent ones: a lane's
		-- work changes shape as it goes (a container, then its groups, then a run of no-ops).
		local ms = debugprofilestop() - itemStarted

		lane.AvgMs = lane.AvgMs and (lane.AvgMs * 0.7 + ms * 0.3) or ms

		-- Not finished: give the item its place back, so it completes before anything newer and
		-- the tick budget is weighed between its parts.
		if verdict == M.Verdict.Unfinished then
			lane.Next = lane.Next - 1
		else
			-- Counted on completion, not on being handed out: an unfinished item comes back.
			doneTotal = doneTotal + 1
		end

		local abandoned = verdict == false

		-- Only while the run is still the one this item came from: a processFn may Run a
		-- replacement on its own lane, and stopping then would silently kill the new queue.
		if lane.Queue == queue and (abandoned or not LaneHasWork(lane)) then
			StopLane(lane)
		end

		spentThisTick = debugprofilestop() - started

		if spentThisTick >= TICK_BUDGET_MS then
			break
		end
	end

	M:ReportProgress()

	if ticker and not AnyLaneHasWork() then
		ticker:Cancel()
		ticker = nil
	end
end

---TEMPORARY. Says how far the background warm-up has got, at each tenth, and once more when every
---lane runs dry. Called from the tick; nothing else should.
function M:ReportProgress()
	if not reporting or queuedTotal <= 0 then
		return
	end

	warmStarted = warmStarted or GetTime()

	local percent = doneTotal / queuedTotal * 100

	while percent >= nextMilestone and nextMilestone <= 90 do
		addon.Framework:Notify("Warming: %d%% (%d of %d)", nextMilestone, doneTotal, queuedTotal)
		nextMilestone = nextMilestone + 10
	end

	if AnyLaneHasWork() then
		return
	end

	addon.Framework:Notify("Warming: done, %d items in %.1fs", doneTotal, GetTime() - warmStarted)

	-- Reset for the next burst, which is whatever a zone change or a roster forming queues next.
	queuedTotal = 0
	doneTotal = 0
	nextMilestone = 10
	warmStarted = nil
end

---TEMPORARY. Turns the warm-up progress messages on or off, and says which it did.
---@return boolean on
function M:ToggleProgressReporting()
	reporting = not reporting

	return reporting
end

---@param maxPerTick number? Most items this lane may take from one tick. Without it the lane can
---take the whole shared budget, which is right for restyles and too much for anything that
---creates frames.
---@param urgent boolean? Serve this lane before the others. For work something on screen is
---waiting on, which must not queue behind work nobody has asked for yet.
---@return Sweep A lane of the shared walker; hold one per consumer.
function M:New(maxPerTick, urgent)
	local lane = setmetatable({ MaxPerTick = maxPerTick, Urgent = urgent }, M)
	lanes[#lanes + 1] = lane

	return lane
end

---Starts this lane over, replacing any run of its own still in flight; the old queue is
---dropped, never resumed. Other lanes are untouched. processFn(item, ctx) runs per item and
---returns false to abandon the whole run ("cannot do this right now"), or Verdict.Unfinished to
---be handed the same item again on this lane's next turn.
---@param queue any[] Items to visit, in order. The lane owns the array from here on.
---@param processFn fun(item: any, ctx: any): boolean|string|nil
---@param ctx any?
function M:Run(queue, processFn, ctx)
	-- Whatever the old run still owed is never done now, so it leaves the denominator with it.
	if LaneHasWork(self) then
		queuedTotal = queuedTotal - (#self.Queue - self.Next + 1)
	end

	queuedTotal = queuedTotal + #queue

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

---Adds one item to the end of this lane's run, starting a run if it is idle. For work that turns
---up a piece at a time rather than as a set, where Run would throw away what is still queued.
---@param item any
---@param processFn fun(item: any, ctx: any): boolean|string|nil Used only when starting a run.
---@param ctx any?
function M:Append(item, processFn, ctx)
	queuedTotal = queuedTotal + 1

	if LaneHasWork(self) then
		self.Queue[#self.Queue + 1] = item

		return
	end

	queuedTotal = queuedTotal - 1
	self:Run({ item }, processFn, ctx)
end

function M:Stop()
	StopLane(self)
end

---@class Sweep
---@field Queue any[]?
---@field Next number?
---@field ProcessFn (fun(item: any, ctx: any): boolean|string|nil)?
---@field Ctx any?
---@field MaxPerTick number?
---@field Urgent boolean?
---@field AvgMs number? What this lane's items have been costing, for the round robin's guess at
---whether one more fits in what is left of a tick.
