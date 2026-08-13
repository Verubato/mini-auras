-- The shared poller behind the states no event announces: a friendly unit turning attackable at
-- duel start, a unit leaving or re-entering the player's visible world, and a unit becoming
-- charmed. Subscribers react by refreshing their module, and a module is entitled to re-seed its
-- own baselines while doing so - which is the hazard these cover.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

local addon = { Core = {}, Utils = {} }
local env = { enemies = {}, visible = {}, charmed = {} }

addon.Utils.Units = {
	IsEnemy = function(_, unit)
		return env.enemies[unit] == true
	end,
	IsVisible = function(_, unit)
		return env.visible[unit] ~= false
	end,
	IsCharmed = function(_, unit)
		return env.charmed[unit] == true
	end,
}

_G.IsInInstance = function()
	return false, "none"
end

local ticker

_G.C_Timer = _G.C_Timer or {}
_G.C_Timer.NewTicker = function(_, fn)
	ticker = fn
	return { Cancel = function() end }
end

assert(loadfile("src/Core/DuelPoller.lua"))("MiniAuras", addon)

local poller = addon.Core.DuelPoller

fw.describe("DuelPoller", function()
	fw.it("tells a subscriber when a unit it watches turns hostile", function()
		local flips = {}
		local sub = poller:Register(function()
			return true
		end, function(unit)
			flips[#flips + 1] = unit
		end)

		env.enemies.party1 = false
		sub:Seed("party1")

		env.enemies.party1 = true
		ticker()

		assert(#flips == 1 and flips[1] == "party1", "the flip was reported once")

		sub:ClearAll()
	end)

	fw.it("tells it when one leaves the visible world, which fires no event of its own", function()
		local flips = {}
		local sub = poller:Register(function()
			return true
		end, function(unit)
			flips[#flips + 1] = unit
		end)

		sub:Seed("party2")

		env.visible.party2 = false
		ticker()

		assert(#flips == 1 and flips[1] == "party2", "the visibility change was reported")

		env.visible.party2 = nil
		sub:ClearAll()
	end)

	fw.it("tells it when a unit becomes mind controlled, even inside an instance", function()
		local flips = {}
		local sub = poller:Register(function()
			return true
		end, function(unit)
			flips[#flips + 1] = unit
		end)

		env.enemies.nameplate1 = true
		sub:Seed("nameplate1")

		-- The enemy half of the poll is skipped inside instances; the charm half must not be,
		-- since mind control is most common in arenas and battlegrounds.
		_G.IsInInstance = function()
			return true, "arena"
		end

		env.charmed.nameplate1 = true
		ticker()

		assert(#flips == 1 and flips[1] == "nameplate1", "the charm was reported")

		env.charmed.nameplate1 = nil
		ticker()

		assert(#flips == 2, "the charm ending was reported too")

		_G.IsInInstance = function()
			return false, "none"
		end
		env.enemies.nameplate1 = nil
		sub:ClearAll()
	end)

	fw.it("survives a subscriber that re-seeds its baselines from inside the callback", function()
		local sub
		local seen = 0

		sub = poller:Register(function()
			return true
		end, function()
			seen = seen + 1
			-- What the raid frames do: refreshing the module re-seeds the whole watched set.
			-- Doing that while the poller is still walking the table it is clearing is what this
			-- test exists to catch.
			sub:ClearAll()
			sub:Seed("party3")
			sub:Seed("party4")
		end)

		env.enemies.party3 = false
		env.enemies.party4 = false
		sub:Seed("party3")
		sub:Seed("party4")

		env.enemies.party3 = true
		env.enemies.party4 = true

		ticker()

		assert(seen > 0, "the flip was still reported")

		sub:ClearAll()
		env.enemies.party3 = nil
		env.enemies.party4 = nil
	end)
end)
