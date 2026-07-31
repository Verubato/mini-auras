---@type string, Addon
local _, addon = ...
local units = addon.Utils.Units

-- Duel detection: no event fires when a friendly unit turns attackable at duel start (or back
-- at duel end), so visible plates' enemy status is polled and subscribers are notified when it
-- flips. One shared ticker serves every module that needs this instead of a ticker per module.
-- Duels only occur in the open world, so the poll early-returns inside instances. Each
-- subscriber keeps its own per-token baseline set (seeded on plate add, cleared on plate
-- remove) because subscribers gate their plate events differently, so their tracked token
-- sets can diverge.

---@class DuelPoller
local M = {}
addon.Core.DuelPoller = M

local POLL_INTERVAL = 0.25
---@type DuelPollerSubscriber[]
local subscribers = {}
local ticker

---@class DuelPollerSubscriber
local Subscriber = {}
Subscriber.__index = Subscriber

local function Poll()
	if IsInInstance() then
		return
	end

	for i = 1, #subscribers do
		local subscriber = subscribers[i]
		if subscriber.IsActive() then
			for unitToken, wasEnemy in pairs(subscriber.Baselines) do
				local isEnemy = units:IsEnemy(unitToken)
				if isEnemy ~= wasEnemy then
					subscriber.Baselines[unitToken] = isEnemy
					subscriber.OnFlip(unitToken)
				end
			end
		end
	end
end

---Seeds or refreshes a token's baseline from its current enemy status, returning that status.
---@param unitToken string
---@return boolean isEnemy
function Subscriber:Seed(unitToken)
	local isEnemy = units:IsEnemy(unitToken)
	self.Baselines[unitToken] = isEnemy
	return isEnemy
end

---@param unitToken string
function Subscriber:Clear(unitToken)
	self.Baselines[unitToken] = nil
end

function Subscriber:ClearAll()
	wipe(self.Baselines)
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
---@field Baselines table<string, boolean>
