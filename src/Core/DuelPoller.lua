---@type string, Addon
local _, addon = ...
local units = addon.Utils.Units

-- The states that change with no event to announce them, polled because there is no alternative:
-- a friendly unit turning attackable at duel start (or back at the end), a unit leaving or
-- re-entering the player's visible world, and a unit becoming charmed (mind control flips it to
-- the other team's control). All decide what the engine will do with an aura filter, so a
-- display that ignores them shows the wrong thing until something unrelated refreshes it. One
-- shared ticker serves every module that needs this instead of a ticker per module. Each
-- subscriber keeps its own per-token baselines (seeded on plate add or per refresh, cleared on
-- removal) because subscribers track different token sets.
--
-- Duels only occur in the open world, but visibility and mind control do not, so only the duel
-- half of the poll early-returns inside instances.

---@class DuelPoller
local M = {}
addon.Core.DuelPoller = M

local POLL_INTERVAL = 0.25
-- Scratch for the tokens one subscriber's scan found flipped, so OnFlip runs after the walk.
local flipped = {}
---@type DuelPollerSubscriber[]
local subscribers = {}
local ticker

---@class DuelPollerSubscriber
local Subscriber = {}
Subscriber.__index = Subscriber

local function Poll()
	local outdoors = not IsInInstance()

	for i = 1, #subscribers do
		local subscriber = subscribers[i]
		if subscriber.IsActive() then
			wipe(flipped)

			for unitToken, wasEnemy in pairs(subscriber.Baselines) do
				-- Not an and/or chain: IsEnemy returning false there would read as "unchanged"
				-- and a duel ending would never be noticed.
				local isEnemy = wasEnemy

				if outdoors then
					isEnemy = units:IsEnemy(unitToken)
				end

				local isVisible = units:IsVisible(unitToken)
				local isCharmed = units:IsCharmed(unitToken)

				if isEnemy ~= wasEnemy
					or isVisible ~= subscriber.Visibility[unitToken]
					or isCharmed ~= subscriber.Charmed[unitToken] then
					subscriber.Baselines[unitToken] = isEnemy
					subscriber.Visibility[unitToken] = isVisible
					subscriber.Charmed[unitToken] = isCharmed
					flipped[#flipped + 1] = unitToken
				end
			end

			-- Fired after the walk, never inside it: a subscriber's OnFlip refreshes its module,
			-- and a module that re-seeds its baselines (the raid frames do) clears and refills
			-- the very table being traversed, which Lua does not define.
			for index = 1, #flipped do
				subscriber.OnFlip(flipped[index])
			end
		end
	end
end

---Seeds or refreshes a token's baselines from its current state, returning its enemy status.
---@param unitToken string
---@return boolean isEnemy
function Subscriber:Seed(unitToken)
	local isEnemy = units:IsEnemy(unitToken)

	self.Baselines[unitToken] = isEnemy
	self.Visibility[unitToken] = units:IsVisible(unitToken)
	self.Charmed[unitToken] = units:IsCharmed(unitToken)

	return isEnemy
end

---@param unitToken string
function Subscriber:Clear(unitToken)
	self.Baselines[unitToken] = nil
	self.Visibility[unitToken] = nil
	self.Charmed[unitToken] = nil
end

function Subscriber:ClearAll()
	wipe(self.Baselines)
	wipe(self.Visibility)
	wipe(self.Charmed)
end

---Registers a poll subscriber. IsActive gates the subscriber's whole scan (typically the
---module-enabled check); OnFlip runs after the token's baseline has been updated. The shared
---ticker starts on the first registration.
---@param isActive fun(): boolean
---@param onFlip fun(unitToken: string)
---@return DuelPollerSubscriber
function M:Register(isActive, onFlip)
	local subscriber = setmetatable({
		IsActive = isActive,
		OnFlip = onFlip,
		Baselines = {},
		Visibility = {},
		Charmed = {},
	}, Subscriber)
	subscribers[#subscribers + 1] = subscriber

	if not ticker then
		ticker = C_Timer.NewTicker(POLL_INTERVAL, Poll)
	end

	return subscriber
end

---@class DuelPollerSubscriber
---@field IsActive fun(): boolean
---@field OnFlip fun(unitToken: string)
---@field Baselines table<string, boolean> Token -> was an enemy at the last poll.
---@field Visibility table<string, boolean> Token -> was in the player's visible world.
---@field Charmed table<string, boolean> Token -> was charmed (mind controlled).
