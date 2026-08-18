-- Tests for Core/KickTracker.lua - the interrupt lockout tracker. Fully event-driven and
-- 12.1-independent (kicks aren't auras), feeding the CC, Auras, Portrait, and
-- Nameplates kick icons on both paths.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()
local acm = require("AuraContainerMock")
acm.setup()

-- Environment: KickTracker captures these at load.
local enemyUnits = {}
_G.UnitIsEnemy = function(unit)
	return enemyUnits[unit] == true
end
_G.UnitIsUnit = function(a, b)
	return a == b
end
_G.GetTimePreciseSec = function()
	return _G.GetTime()
end
_G.C_Spell = _G.C_Spell or {}
_G.C_Spell.GetSpellTexture = function(spellId)
	return "tex:" .. tostring(spellId)
end

local addon = {
	Utils = {
		WoWEx = {
			CreateDuration = function(_, startTime, duration)
				return { start = startTime, duration = duration }
			end,
		},
	},
	Core = {
		InspectorFacade = {
			GetUnitSpecId = function()
				return nil
			end,
		},
	},
	Modules = {},
	Config = {},
}

assert(loadfile("src/Core/Kicks/KickData.lua"))("MiniAuras", addon)
assert(loadfile("src/Core/Kicks/KickEvents.lua"))("MiniAuras", addon)
assert(loadfile("src/Core/Kicks/KickTracker.lua"))("MiniAuras", addon)

local kickTracker = addon.Core.KickTracker

-- Fires an event on the unit event frame KickTracker created for the given Watch call.
local function unitFrame()
	return acm.lastFrameForEvent("UNIT_SPELLCAST_INTERRUPTED")
end

local function interrupt(frame, unit, kickedBy)
	frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", unit, "castGUID", 12345, kickedBy)
end

local watchCounter = 0
local function newWatchedUnit(resetEvents)
	-- Unique token per test so state never leaks between cases (Watch is idempotent per token).
	watchCounter = watchCounter + 1
	local unit = "testunit" .. watchCounter
	kickTracker:Watch(unit, resetEvents)
	return unit, unitFrame()
end

fw.describe("KickTracker - kick detection", function()
	fw.it("an interrupt with an interrupter creates a kick entry and notifies subscribers", function()
		wow.setTime(100)
		local unit, frame = newWatchedUnit()
		local notified = 0
		kickTracker:Subscribe(unit, function()
			notified = notified + 1
		end)

		interrupt(frame, unit, "Player-Kicker")

		local entry = kickTracker:GetKick(unit)
		assert(entry, "kick entry created")
		assert(entry.Duration == 3, "default lockout duration")
		assert(entry.StartTime == 100, "stamped with the current time")
		assert(entry.DurationObject.duration == 3, "duration object built")
		assert(notified == 1, "subscriber fired once, got " .. notified)
	end)

	fw.it("a cast ending without an interrupter creates nothing", function()
		local unit, frame = newWatchedUnit()
		interrupt(frame, unit, nil)
		assert(kickTracker:GetKick(unit) == nil)
	end)

	fw.it("INTERRUPTED and CHANNEL_STOP for the same interrupt only fire once", function()
		wow.setTime(50)
		local unit, frame = newWatchedUnit()
		local notified = 0
		kickTracker:Subscribe(unit, function()
			notified = notified + 1
		end)

		interrupt(frame, unit, "Player-Kicker")
		frame:TriggerEvent("UNIT_SPELLCAST_CHANNEL_STOP", unit, "castGUID", 12345, "Player-Kicker")

		assert(notified == 1, "double-trigger guard, got " .. notified)
	end)

	fw.it("a new cast re-arms the guard for the next interrupt", function()
		wow.setTime(60)
		local unit, frame = newWatchedUnit()
		interrupt(frame, unit, "Player-Kicker")
		wow.setTime(61)
		frame:TriggerEvent("UNIT_SPELLCAST_START", unit, "castGUID", 12345)
		interrupt(frame, unit, "Player-Kicker")
		local entry = kickTracker:GetKick(unit)
		assert(entry and entry.StartTime == 61, "second interrupt tracked after a new cast")
	end)
end)

fw.describe("KickTracker - lifecycle", function()
	fw.it("the entry clears and notifies when the lockout expires", function()
		wow.setTime(100)
		local unit, frame = newWatchedUnit()
		local notified = 0
		kickTracker:Subscribe(unit, function()
			notified = notified + 1
		end)

		interrupt(frame, unit, "Player-Kicker")
		assert(kickTracker:GetKick(unit))
		acm.runTimers()
		assert(kickTracker:GetKick(unit) == nil, "entry cleared on expiry")
		assert(notified == 2, "subscriber notified for both create and clear, got " .. notified)
	end)

	fw.it("a reset event clears an active entry", function()
		wow.setTime(100)
		local unit, frame = newWatchedUnit({ "PLAYER_TARGET_CHANGED" })
		interrupt(frame, unit, "Player-Kicker")
		assert(kickTracker:GetKick(unit))

		frame:TriggerEvent("PLAYER_TARGET_CHANGED")
		assert(kickTracker:GetKick(unit) == nil, "reset event cleared the entry")
	end)

	fw.it("Unwatch stops tracking entirely", function()
		local unit, frame = newWatchedUnit()
		interrupt(frame, unit, "Player-Kicker")
		kickTracker:Unwatch(unit)
		assert(kickTracker:GetKick(unit) == nil, "no entry after Unwatch")
	end)

	fw.it("re-watching a unit reuses its event frame", function()
		-- Frames can never be freed, and nameplate tokens are watched and unwatched every time a
		-- plate comes and goes. Building a fresh frame per Watch orphaned one per cycle, which a
		-- session of turning the camera in a crowd turns into thousands.
		local unit, frame = newWatchedUnit()

		kickTracker:Unwatch(unit)
		kickTracker:Watch(unit)

		assert(unitFrame() == frame, "the same token's second Watch reuses the first frame")

		-- And the reused frame is live again, not a silent leftover.
		interrupt(unitFrame(), unit, "Player-Kicker")
		assert(kickTracker:GetKick(unit) ~= nil, "the reused frame still reports kicks")
	end)

	fw.it("ignores its own events while nothing is watching the token", function()
		-- The registrations are left in place across an Unwatch, since taking them back walks the
		-- client's whole event registry and a plate leaving pays it. What makes that safe is the
		-- handlers dropping anything for a token nobody asked about.
		local unit, frame = newWatchedUnit()

		kickTracker:Unwatch(unit)
		interrupt(frame, unit, "Player-Kicker")

		assert(kickTracker:GetKick(unit) == nil, "an interrupt on an unwatched token is dropped")

		kickTracker:Watch(unit)
		interrupt(frame, unit, "Player-Kicker")

		assert(kickTracker:GetKick(unit) ~= nil, "and counts again once it is watched")
	end)

	fw.it("Watch reports whether it started tracking, so callers subscribe once", function()
		local unit = newWatchedUnit()

		assert(kickTracker:Watch(unit) == false, "a second Watch for the same token starts nothing")
		kickTracker:Unwatch(unit)
		assert(kickTracker:Watch(unit) == true, "watching again after Unwatch does start tracking")
	end)

	fw.it("Unsubscribe stops notifications", function()
		local unit, frame = newWatchedUnit()
		local notified = 0
		local key = kickTracker:Subscribe(unit, function()
			notified = notified + 1
		end)
		kickTracker:Unsubscribe(unit, key)
		interrupt(frame, unit, "Player-Kicker")
		assert(notified == 0, "unsubscribed callback must not fire, got " .. notified)
	end)
end)
