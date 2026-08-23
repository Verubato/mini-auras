---@type string, Addon
local _, addon = ...

-- Staggered background walker shared by the display caches: a queue of parked items is run
-- through a callback a few at a time, so a look change converges on frames nobody can see
-- without billing any single frame for the lot. Sweeps are warm-ups by contract: whoever owns
-- the items must also correct them lazily on use, because a run can be replaced or abandoned at
-- any point, and callers re-validate each item in the callback - the world moves while it runs.
--
-- Each consumer holds its own lane (New), but the budget is addon-wide: one worker spends it
-- across every lane with work, round-robin, so the total background cost stays flat no matter how
-- many modules queue a sweep at once. A lane's Run only ever replaces that lane's own queue.
--
-- The walker rides a frame's OnUpdate rather than a timer, for two reasons. A budget in
-- milliseconds only means anything against the frame it is spent in, and a frame is the only place
-- to read that. Throughput then follows the headroom the machine actually has, instead of being
-- pinned to whatever interval a timer was given.
--
-- A loading screen is not a window this can use, which was measured rather than assumed. There is
-- no LOADING_SCREEN_ENABLED at login, and the prepared set is queued from the refresh that
-- PLAYER_ENTERING_WORLD drives, which lands a few milliseconds before the screen lifts. A timer
-- put on the queues there got one turn in and found the screen already gone. Anything wanting that
-- window has to be queued earlier, not walked faster.

-- The biggest slice of a frame the walker takes on, beyond the one item it is already part way
-- through. Small on purpose. Most of what the lanes carry is well under a millisecond, and a slice
-- this size still gets a run of that through; the dear items cannot be cut up at all, since
-- declaring an aura group allocates its whole batch of buttons in one engine call, so the slice's
-- real job is to stop two of those landing in the same frame.
local FRAME_BUDGET_MS = 2
-- What the on-demand lanes may spend per second. Three times the background rate, because their
-- items are things already on screen waiting to be finished.
local URGENT_MS_PER_SECOND = 60
-- What the background lanes may spend per second. They are preparing displays nobody has asked for
-- yet, so this one number is what the addon costs in ordinary play.
local BACKGROUND_MS_PER_SECOND = 20
-- The most of any frame the on-demand lanes may claim while a background lane is also waiting.
-- Without it a busy on-demand lane takes every frame, and the background lanes are exactly the ones
-- nothing else will ever come back for. With nothing waiting the share does not bind at all.
local URGENT_FRAME_SHARE = 0.5
-- How fast a lane's remembered worst item fades, per item it runs. A lane's work changes shape as
-- it goes - a container, then its groups, then a run of no-ops - so one that has stopped being
-- expensive earns its way back to sharing a frame over the next few dozen items.
local PEAK_DECAY = 0.9

-- Every lane ever created. Lanes are one per consumer per session and never removed; a drained
-- lane costs one has-work check per scan.
local lanes = {}
-- The frame the walker rides, built on first use: an addon whose modules are all switched off
-- never sweeps and never needs one. Hidden whenever no lane has work, so an idle session runs no
-- script at all.
local worker = nil
-- Round-robin cursors into lanes, persisted across frames so a busy lane cannot starve the rest.
-- One per class of lane, because the two classes are walked in passes of their own.
local cursor = 1
local urgentCursor = 1
-- Milliseconds each class has banked and not yet spent. Held as credit rather than granted per
-- frame because an item cannot be split: a lane runs one whenever any credit is left and the
-- overrun is carried into the frames after it, so the average holds however dear the items are.
-- Neither ever banks more than one frame's slice, or a quiet minute would buy one enormous frame.
local urgentCredit = 0
local credit = 0
-- When the frame being run began and how much of it is gone. The slice cannot split an item, so
-- the only way to keep a frame short is to not start one that is going to overrun it.
local frameStarted = 0
local spentThisFrame = 0
-- Whether the pass being run has started anything yet. Its first item always runs, or a lane whose
-- items cost more than the whole slice would never run at all.
local passIsEmpty = true

---@class Sweep
local M = {}
M.__index = M

addon.Core.Sweep = M

---What a processFn can tell the lane about the item it just saw, beyond finishing it (return
---nothing) or abandoning the run (return false).
---@enum SweepVerdict
M.Verdict = {
	-- The item is not finished: hand it back on this lane's next turn rather than moving on. For
	-- work that cannot fit in one slot, so the budget applies between its parts.
	Unfinished = "unfinished",
}

---@param lane Sweep
---@return boolean
local function LaneHasWork(lane)
	return lane.Queue ~= nil and lane.Queue[lane.Next] ~= nil
end

---Whether the round robin may hand this lane an item in what is left of the frame.
---@param lane Sweep
---@param remainingMs number
---@return boolean
local function LaneCanRun(lane, remainingMs)
	if not LaneHasWork(lane) then
		return false
	end

	-- The pass's first item runs whatever it costs, or a lane whose items are dearer than the whole
	-- slice would never run at all. What stops the next pass taking a second one is the slice
	-- itself: an item that overran it leaves nothing under the limit for anyone to start with.
	-- Measured live, one group declaration is about four milliseconds against a two millisecond
	-- slice, so in practice a frame carries one of them.
	if passIsEmpty then
		return true
	end

	-- Weighed against the worst this lane has been lately rather than its average: a lane part way
	-- through a run of cheap no-op turns averages cheap right up until its next real container
	-- build, which is what used to let three of those land in one frame. A lane that has never run
	-- counts as dear for the same reason.
	return lane.PeakMs ~= nil and lane.PeakMs <= remainingMs
end

---@param lane Sweep
local function StopLane(lane)
	lane.Queue = nil
	lane.ProcessFn = nil
	lane.Ctx = nil
end

---The next lane of one class with something to do, advancing that class's cursor past it; nil
---once a full circle finds nothing.
---@param urgent boolean Which class of lane this pass is serving.
---@param remainingMs number
---@return Sweep?
local function NextLaneWithWork(urgent, remainingMs)
	for _ = 1, #lanes do
		local lane

		if urgent then
			lane = lanes[urgentCursor]
			urgentCursor = urgentCursor % #lanes + 1
		else
			lane = lanes[cursor]
			cursor = cursor % #lanes + 1
		end

		if (lane.Urgent == true) == urgent and LaneCanRun(lane, remainingMs) then
			return lane
		end
	end

	return nil
end

---A peek that leaves the cursors alone, for the stop check and for weighing one class against the
---other. Asking through NextLaneWithWork would consume a busy lane's turn and starve it for the
---whole sweep.
---@param urgent boolean? Only lanes of this class; either class when left out.
---@return boolean
local function AnyLaneHasWork(urgent)
	for _, lane in ipairs(lanes) do
		if (urgent == nil or (lane.Urgent == true) == urgent) and LaneHasWork(lane) then
			return true
		end
	end

	return false
end

---What the on-demand pass may spend of a frame: its share while a background lane is waiting, and
---the lot when none is.
---@param allowanceMs number
---@return number
local function UrgentAllowance(allowanceMs)
	if not AnyLaneHasWork(false) then
		return allowanceMs
	end

	return math.min(allowanceMs, FRAME_BUDGET_MS * URGENT_FRAME_SHARE)
end

---Hands out slots to one class of lane until its own allowance or the frame's slice is gone,
---whichever comes first.
---@param urgent boolean
---@param allowanceMs number What this class has left to spend.
---@return number spent by this pass
local function RunPass(urgent, allowanceMs)
	local before = spentThisFrame
	local limit = math.min(before + allowanceMs, FRAME_BUDGET_MS)

	passIsEmpty = true

	while spentThisFrame < limit do
		local lane = NextLaneWithWork(urgent, limit - spentThisFrame)

		if not lane then
			break
		end

		local queue = lane.Queue
		local item = queue[lane.Next]
		lane.Next = lane.Next + 1
		passIsEmpty = false

		local itemStarted = debugprofilestop()
		local verdict = lane.ProcessFn(item, lane.Ctx)
		local ms = debugprofilestop() - itemStarted

		lane.PeakMs = math.max(ms, (lane.PeakMs or 0) * PEAK_DECAY)

		local abandoned = verdict == false

		-- Not finished: give the item its place back, so it completes before anything newer and
		-- the budget is weighed between its parts. Only into the queue it came from; a processFn
		-- that replaced its own lane's run would otherwise push the new queue's cursor off the
		-- front of it.
		if verdict == M.Verdict.Unfinished and lane.Queue == queue then
			lane.Next = lane.Next - 1
		end

		-- Only while the run is still the one this item came from: a processFn may Run a
		-- replacement on its own lane, and stopping then would silently kill the new queue.
		if lane.Queue == queue and (abandoned or not LaneHasWork(lane)) then
			StopLane(lane)
		end

		spentThisFrame = debugprofilestop() - frameStarted
	end

	return spentThisFrame - before
end

---@param elapsed number Seconds since the last frame, which is what the credit buys.
local function OnUpdate(_, elapsed)
	-- Nothing is drawn behind a loading screen, so anything spent there is charged to the frame the
	-- screen drops on. No credit accrues either: a two minute zone-in must not buy a hitch.
	if addon:IsLoadingScreenUp() then
		return
	end

	urgentCredit = math.min(urgentCredit + elapsed * URGENT_MS_PER_SECOND, FRAME_BUDGET_MS)
	credit = math.min(credit + elapsed * BACKGROUND_MS_PER_SECOND, FRAME_BUDGET_MS)

	frameStarted = debugprofilestop()
	spentThisFrame = 0

	urgentCredit = urgentCredit - RunPass(true, UrgentAllowance(urgentCredit))
	credit = credit - RunPass(false, credit)

	if not AnyLaneHasWork() then
		worker:Hide()
	end
end

---Puts the worker back on the clock, building it the first time anything sweeps.
local function Wake()
	if not worker then
		worker = CreateFrame("Frame")
		worker:SetScript("OnUpdate", OnUpdate)
	end

	worker:Show()
end

---@param urgent boolean? Spend the on-demand allowance rather than the background one, ahead of
---the background lanes. For work something on screen is waiting on, which must not be paced by
---what work nobody has asked for yet has left.
---@return Sweep A lane of the shared walker; hold one per consumer.
function M:New(urgent)
	local lane = setmetatable({ Urgent = urgent }, M)
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
	self.Queue = queue
	self.Next = 1
	self.ProcessFn = processFn
	self.Ctx = ctx

	if #queue == 0 then
		StopLane(self)
		return
	end

	Wake()
end

---Adds one item to the end of this lane's run, starting a run if it is idle. For work that turns
---up a piece at a time rather than as a set, where Run would throw away what is still queued.
---@param item any
---@param processFn fun(item: any, ctx: any): boolean|string|nil Used only when starting a run.
---@param ctx any?
function M:Append(item, processFn, ctx)
	if LaneHasWork(self) then
		self.Queue[#self.Queue + 1] = item

		return
	end

	self:Run({ item }, processFn, ctx)
end

---Whether this lane still has queued items to get through.
---@return boolean
function M:HasWork()
	return LaneHasWork(self)
end

function M:Stop()
	StopLane(self)
end

---@class Sweep
---@field Queue any[]?
---@field Next number?
---@field ProcessFn (fun(item: any, ctx: any): boolean|string|nil)?
---@field Ctx any?
---@field Urgent boolean?
---@field PeakMs number? The worst this lane's items have cost lately, for the round robin's guess
---at whether one more fits in what is left of a frame.
