-- The shared poller behind the states no event announces: a friendly unit turning attackable at
-- duel start, a unit leaving or re-entering the player's visible world, and a unit becoming
-- charmed. Subscribers react by refreshing their module, and a module is entitled to re-seed its
-- own baselines while doing so - which is the hazard these cover.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()

local addon = { Core = {}, Utils = {} }
local env = { enemies = {}, visible = {}, charmed = {}, reads = 0 }

addon.Utils.Units = {
	IsEnemy = function(_, unit)
		env.reads = env.reads + 1
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

		-- Both, not just the first: dispatch re-reads membership per token, so a re-seed that
		-- happens part way through must leave the tokens still to come able to receive theirs.
		assert(seen == 2, "both flips were reported")

		sub:ClearAll()
		env.enemies.party3 = nil
		env.enemies.party4 = nil
	end)

	-- The point of the shared baseline: the three raid frame modules all watch the same group
	-- units, so a token every one of them wants must still only be read once a tick.
	fw.it("reads a token once a poll however many subscribers watch it", function()
		local flips = {}

		local function Watch()
			return poller:Register(function()
				return true
			end, function(unit)
				flips[#flips + 1] = unit
			end)
		end

		local first, second, third = Watch(), Watch(), Watch()

		env.enemies.raid5 = false
		first:Seed("raid5")
		second:Seed("raid5")
		third:Seed("raid5")

		env.enemies.raid5 = true
		env.reads = 0
		ticker()

		assert(env.reads == 1, "the token was read once, not once per subscriber")
		assert(#flips == 3, "every subscriber watching it was told")

		first:ClearAll()
		second:ClearAll()
		third:ClearAll()
		env.enemies.raid5 = nil
	end)

	fw.it("keeps a shared token's baseline while another subscriber still watches it", function()
		local flips = {}
		local staying = poller:Register(function()
			return true
		end, function(unit)
			flips[#flips + 1] = unit
		end)
		local leaving = poller:Register(function()
			return true
		end, function() end)

		env.enemies.raid6 = false
		staying:Seed("raid6")
		leaving:Seed("raid6")

		-- Dropping one watcher must not take the baseline with it: a cleared baseline reads as a
		-- flip on the very next poll, and the module still watching would refresh for nothing.
		leaving:Clear("raid6")
		ticker()

		assert(#flips == 0, "no flip was invented for the subscriber that stayed")

		env.enemies.raid6 = true
		ticker()

		assert(#flips == 1 and flips[1] == "raid6", "a real flip still lands")

		staying:ClearAll()
		env.enemies.raid6 = nil
	end)

	-- A module re-seeds its whole watched set whenever it refreshes, for reasons of its own that
	-- have nothing to do with the other modules watching the same units. Taking a fresh baseline
	-- there would reset a change nobody else has been told about yet, and the flip would be lost
	-- for good; a baseline left alone costs one spare refresh on the next poll instead.
	fw.it("lets a shared token's flip survive another subscriber re-seeding it", function()
		local flips = {}
		local watching = poller:Register(function()
			return true
		end, function(unit)
			flips[#flips + 1] = unit
		end)
		local reseeding = poller:Register(function()
			return true
		end, function() end)

		env.enemies.raid7 = false
		watching:Seed("raid7")
		reseeding:Seed("raid7")

		env.enemies.raid7 = true
		reseeding:Seed("raid7")

		ticker()

		assert(#flips == 1 and flips[1] == "raid7", "the flip reached the subscriber that missed it")

		watching:ClearAll()
		reseeding:ClearAll()
		env.enemies.raid7 = nil
	end)

	fw.it("skips tokens only a disabled subscriber watches", function()
		local enabled = false
		local sub = poller:Register(function()
			return enabled
		end, function() end)

		sub:Seed("party9")

		env.reads = 0
		ticker()

		assert(env.reads == 0, "a disabled subscriber's tokens cost nothing")

		enabled = true
		env.reads = 0
		ticker()

		assert(env.reads == 1, "and are read again once it is back on")

		sub:ClearAll()
	end)

	-- What the live addon actually looks like: one module switched off while another watches the
	-- same token. The token is still read, but only for the module that can act on it.
	fw.it("still reads a token an active subscriber shares with a disabled one", function()
		local flips = {}
		local active = poller:Register(function()
			return true
		end, function(unit)
			flips[#flips + 1] = unit
		end)
		local disabled = poller:Register(function()
			return false
		end, function()
			error("a disabled subscriber must never be called back")
		end)

		env.enemies.nameplate5 = false
		active:Seed("nameplate5")
		disabled:Seed("nameplate5")

		env.enemies.nameplate5 = true
		env.reads = 0
		ticker()

		assert(env.reads == 1, "the shared token was read once")
		assert(#flips == 1, "only the active subscriber was told")

		active:ClearAll()
		disabled:ClearAll()
		env.enemies.nameplate5 = nil
	end)
end)
