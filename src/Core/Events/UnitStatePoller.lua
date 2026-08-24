---@type string, Addon
local _, addon = ...
local units = addon.Utils.UnitUtil

-- The states that change with no event to announce them: a friendly unit turning attackable at a
-- duel, a unit leaving or re-entering the visible world, a unit becoming charmed, and whether the
-- player can assist it. All four decide what the engine does with an aura filter, so a display that
-- ignores them shows the wrong thing until something unrelated refreshes it.

---@class UnitStatePoller
local M = {}
addon.Core.UnitStatePoller = M

local POLL_INTERVAL = 0.25
-- Events that can only ever mean "read the states again now". Registered while the poll runs and
-- dropped with it, so an addon that watches nothing pays nothing for them.
--
-- None of them answers the question on its own, since they fire for units nothing watches and stay
-- silent when a unit walks out of range. They are not read for their payload: one just brings the
-- next poll forward a frame, turning a mind control landing on a plate from a quarter second of
-- wrong icons into one frame of them.
local WAKE_EVENTS = { "UNIT_FACTION", "UNIT_FLAGS", "UNIT_PHASE" }

-- Shared baselines, keyed by unit token and alive while any subscriber watches the token. Modules
-- watch overlapping sets, so a baseline per subscriber read the same unit three times a tick. Here
-- a token is read once and the flip is handed to every subscriber watching it.
--
-- Enemy status is read everywhere, not just outdoors where duels happen: mind control flips a unit
-- to the other team mid-arena, and that flip is the only signal a display gets that the identity
-- gate now answers the other way for it.
local enemyState = {}
local visibleState = {}
local charmedState = {}
-- Assistability is the identity gate: a spell-ID filter applies to helpful auras only on a unit the
-- player can assist, and to harmful auras only on one it cannot (see Core/Auras/AuraFilters). A unit
-- that changes sides keeps the groups it was built with, and one whose map the gate now skips falls
-- back to its filter string alone, which for the disarm group is every non-CC debuff it has.
local assistState = {}
-- Reference counted, so one subscriber dropping a token cannot strand another with a missing
-- baseline, which would read as a flip on the next poll.
local tokenRefs = {}
-- Reused buffers, each read through a count rather than #: the entries past it are whatever the
-- last write left there.
local activeSubs = {}
local unionOrder = {}
local unionSeen = {}
local flipped = {}
---@type UnitStatePollerSubscriber[]
local subscribers = {}
-- The union outlives the poll that built it, because walking every subscriber's membership costs
-- far more than the poll itself and only a Seed, a Clear or a new subscriber can move it.
local unionDirty = true
local unionCount = 0
local activeCount = 0
-- Last answer each subscriber's IsActive gave, so a module enabling or disabling is noticed.
local subscriberActive = {}
local ticker
local wakeFrame
-- One brought-forward poll in flight at a time, since getting controlled fires UNIT_FACTION once
-- per unit in the group.
local wakeQueued = false

---@class UnitStatePollerSubscriber
local Subscriber = {}
Subscriber.__index = Subscriber

---Drops one reference to a token, clearing the shared baseline when the last one goes.
---@param unitToken string
local function ReleaseToken(unitToken)
	local refs = tokenRefs[unitToken]

	if not refs then
		return
	end

	if refs > 1 then
		tokenRefs[unitToken] = refs - 1
		return
	end

	tokenRefs[unitToken] = nil
	enemyState[unitToken] = nil
	visibleState[unitToken] = nil
	charmedState[unitToken] = nil
	assistState[unitToken] = nil
end

local function RebuildUnion()
	activeCount = 0
	unionCount = 0

	wipe(unionSeen)

	-- Only the tokens an active subscriber watches are read. A disabled module keeps its
	-- membership, since it re-seeds on the enable path, and must not keep paying for it.
	for index = 1, #subscribers do
		local subscriber = subscribers[index]

		if subscriberActive[subscriber] then
			activeCount = activeCount + 1
			activeSubs[activeCount] = subscriber

			for unitToken in pairs(subscriber.Tokens) do
				if not unionSeen[unitToken] then
					unionSeen[unitToken] = true
					unionCount = unionCount + 1
					unionOrder[unionCount] = unitToken
				end
			end
		end
	end

	unionDirty = false
end

local function Poll()
	-- IsActive is the caller's own closure, so a module changing its mind arrives with nothing to
	-- announce it.
	for index = 1, #subscribers do
		local subscriber = subscribers[index]
		local isActive = subscriber.IsActive() and true or false

		if subscriberActive[subscriber] ~= isActive then
			subscriberActive[subscriber] = isActive
			unionDirty = true
		end
	end

	if unionDirty then
		RebuildUnion()
	end

	-- Nothing for an active subscriber to watch: stop until a Seed brings work back. Every module
	-- seeds on its own enable path, so becoming active is always announced here.
	if unionCount == 0 then
		if ticker then
			ticker:Cancel()
			ticker = nil
		end

		if wakeFrame then
			wakeFrame:UnregisterAllEvents()
		end

		return
	end

	local flippedCount = 0

	for index = 1, unionCount do
		local unitToken = unionOrder[index]
		local isEnemy = units:IsEnemy(unitToken)
		local isVisible = units:IsVisible(unitToken)
		local isCharmed = units:IsCharmed(unitToken)
		local canAssist = units:CanAssist(unitToken)

		if isEnemy ~= enemyState[unitToken]
			or isVisible ~= visibleState[unitToken]
			or isCharmed ~= charmedState[unitToken]
			or canAssist ~= assistState[unitToken] then
			enemyState[unitToken] = isEnemy
			visibleState[unitToken] = isVisible
			charmedState[unitToken] = isCharmed
			assistState[unitToken] = canAssist
			flippedCount = flippedCount + 1
			flipped[flippedCount] = unitToken
		end
	end

	-- Fired after the walk, never inside it: a subscriber's OnFlip refreshes its module, and a
	-- module that re-seeds its baselines (the raid frames do) clears and refills the membership
	-- the walk above traverses. Membership is read one token at a time down here, so a re-seed
	-- mid-dispatch is safe and lands before the tokens still to come.
	for index = 1, flippedCount do
		local unitToken = flipped[index]

		for slot = 1, activeCount do
			local subscriber = activeSubs[slot]

			if subscriber.Tokens[unitToken] then
				subscriber.OnFlip(unitToken)
			end
		end
	end
end

---Runs a poll on the next frame. Never straight away: the events that ask for this arrive in a
---burst, and the client has not necessarily finished moving the unit when the first one lands.
local function QueueWakePoll()
	if wakeQueued or not ticker then
		return
	end

	wakeQueued = true

	C_Timer.After(0, function()
		wakeQueued = false

		if ticker then
			Poll()
		end
	end)
end

local function StartTicker()
	if ticker then
		return
	end

	ticker = C_Timer.NewTicker(POLL_INTERVAL, Poll)

	if not wakeFrame then
		wakeFrame = CreateFrame("Frame")
		wakeFrame:SetScript("OnEvent", QueueWakePoll)
	end

	for index = 1, #WAKE_EVENTS do
		wakeFrame:RegisterEvent(WAKE_EVENTS[index])
	end
end

---Adds a token to this subscriber's watch set, returning its enemy status. The shared baseline is
---taken only when the caller is the token's sole watcher: re-seeding one another subscriber also
---watches would reset a change that subscriber has not been told about yet, and a swallowed flip
---is far worse than the spare one a stale baseline costs on the next poll.
---@param unitToken string
---@return boolean isEnemy
function Subscriber:Seed(unitToken)
	local isEnemy = units:IsEnemy(unitToken)

	if not self.Tokens[unitToken] then
		self.Tokens[unitToken] = true
		tokenRefs[unitToken] = (tokenRefs[unitToken] or 0) + 1
		unionDirty = true
	end

	-- The poll stops itself once no active subscriber watches anything, so seeding is what wakes
	-- it back up. Cheap enough to do unconditionally on a path this hot.
	StartTicker()

	if tokenRefs[unitToken] == 1 then
		enemyState[unitToken] = isEnemy
		visibleState[unitToken] = units:IsVisible(unitToken)
		charmedState[unitToken] = units:IsCharmed(unitToken)
		assistState[unitToken] = units:CanAssist(unitToken)
	end

	return isEnemy
end

---@param unitToken string
function Subscriber:Clear(unitToken)
	if not self.Tokens[unitToken] then
		return
	end

	self.Tokens[unitToken] = nil
	ReleaseToken(unitToken)
	unionDirty = true
end

function Subscriber:ClearAll()
	for unitToken in pairs(self.Tokens) do
		ReleaseToken(unitToken)
	end

	wipe(self.Tokens)
	unionDirty = true
end

---Registers a poll subscriber. IsActive gates the subscriber's whole membership (typically the
---module-enabled check); OnFlip runs after the token's baseline has been updated. The shared
---ticker only runs while an active subscriber actually watches a token, so registering alone
---costs nothing until the first Seed.
---@param isActive fun(): boolean
---@param onFlip fun(unitToken: string)
---@return UnitStatePollerSubscriber
function M:Register(isActive, onFlip)
	local subscriber = setmetatable({
		IsActive = isActive,
		OnFlip = onFlip,
		Tokens = {},
	}, Subscriber)
	subscribers[#subscribers + 1] = subscriber
	unionDirty = true

	return subscriber
end

---@class UnitStatePollerSubscriber
---@field IsActive fun(): boolean
---@field OnFlip fun(unitToken: string)
---@field Tokens table<string, boolean> The tokens this subscriber watches. The state itself lives
---in the shared baselines, keyed by token and shared with every other subscriber watching it.
