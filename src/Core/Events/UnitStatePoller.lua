---@type string, Addon
local _, addon = ...
local units = addon.Utils.UnitUtil

-- The states that change with no event to announce them, polled because there is no alternative:
-- a friendly unit turning attackable at duel start (or back at the end), a unit leaving or
-- re-entering the player's visible world, a unit becoming charmed (mind control flips it to the
-- other team's control), and whether the player can assist it. All decide what the engine will do
-- with an aura filter, so a display that ignores them shows the wrong thing until something
-- unrelated refreshes it.
--
-- Assistability is polled alongside the rest because it IS the identity gate: a spell-ID filter
-- applies to helpful auras only on a unit the player can assist and to harmful auras only on one
-- it cannot (see Core/Auras/AuraFilters). A unit that changes sides keeps the groups it was built
-- with, and the ones whose map the gate now skips fall back to their filter string alone - which
-- for the disarm group is every non-CC debuff the unit has.
--
-- The baseline is per token, not per subscriber. Modules watch overlapping sets - the three raid
-- frame modules all watch the same group units, and the two nameplate modules the same plate
-- tokens - so a baseline per subscriber read the same unit three times a tick. Here a token is
-- read once and the flip is handed to every subscriber watching it; a subscriber holds only its
-- membership. Baselines are reference counted so one subscriber dropping a token cannot strand
-- another with a missing baseline, which would read as a flip on the next poll.
--
-- Enemy status is read everywhere, not just outdoors where duels happen: mind control flips a
-- unit to the other team's side mid-arena, and that flip is the only signal a display gets that
-- the identity gate now answers the other way for it.

---@class UnitStatePoller
local M = {}
addon.Core.UnitStatePoller = M

local POLL_INTERVAL = 0.25

-- Shared baselines, keyed by unit token and alive while any subscriber watches the token.
local enemyState = {}
local visibleState = {}
local charmedState = {}
local assistState = {}
local tokenRefs = {}
-- Per-poll scratch, all reused. Never measured with #: the entries past a poll's own count are
-- whatever the previous poll left there.
local activeSubs = {}
local unionOrder = {}
local unionSeen = {}
local flipped = {}
---@type UnitStatePollerSubscriber[]
local subscribers = {}
local ticker

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

local function Poll()
	local activeCount = 0
	local unionCount = 0

	wipe(unionSeen)

	-- Only the tokens an active subscriber watches are read. A disabled module keeps its
	-- membership, since it re-seeds on the enable path, and must not keep paying for it.
	for index = 1, #subscribers do
		local subscriber = subscribers[index]

		if subscriber.IsActive() then
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

	-- Nothing for an active subscriber to watch: stop until a Seed brings work back. Every module
	-- seeds on its own enable path, so becoming active is always announced here.
	if unionCount == 0 then
		if ticker then
			ticker:Cancel()
			ticker = nil
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

local function StartTicker()
	if not ticker then
		ticker = C_Timer.NewTicker(POLL_INTERVAL, Poll)
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
end

function Subscriber:ClearAll()
	for unitToken in pairs(self.Tokens) do
		ReleaseToken(unitToken)
	end

	wipe(self.Tokens)
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

	return subscriber
end

---@class UnitStatePollerSubscriber
---@field IsActive fun(): boolean
---@field OnFlip fun(unitToken: string)
---@field Tokens table<string, boolean> The tokens this subscriber watches. The state itself lives
---in the shared baselines, keyed by token and shared with every other subscriber watching it.
