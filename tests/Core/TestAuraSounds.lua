-- The shared wrapper around C_UnitAuras.AddAuraSound and RemoveAuraSound. AddAuraSound answers a
-- refusal with no handle, and the engine will not take one at all while the player is in combat
-- inside instanced PvE.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local auraSounds = env.addon.Core.AuraSounds
local db = env.db

local FILE = "Interface\\AddOns\\MiniAuras\\Sounds\\Effects\\Sonar.ogg"
local FIRST = 700001
local SECOND = 700002
local THIRD = 700003

db.DebugMode = false

---Runs body with the messages switched on and the throttle empty, and hands back what it printed.
---@param body function
---@return string[]
local function Printed(body)
	wipe(env.notifications)
	auraSounds:ResetDebugLog()
	db.DebugMode = true

	local ok, err = pcall(body)

	db.DebugMode = false

	assert(ok, err)

	local said = {}

	for index = 1, #env.notifications do
		said[index] = env.notifications[index]
	end

	wipe(env.notifications)

	return said
end

---A run of distinct spell ids, for the tests that need more failures than the ceiling allows.
---@param count number
---@return table<number, boolean>
local function SpellSet(count)
	local ids = {}

	for index = 1, count do
		ids[800000 + index] = true
	end

	return ids
end

---Runs body with the real C_UnitAuras call handed to it, and puts that call back whether body
---finished or not. The body installs whatever stand-in it wants. Only the removal wrapper still
---catches a throw, so only a removal stand-in may raise one.
---@param name string
---@param body fun(real: function): any
---@return any
local function Standing(name, body)
	local real = _G.C_UnitAuras[name]
	local ok, result = pcall(body, real)

	_G.C_UnitAuras[name] = real

	assert(ok, "the throw reached the caller: " .. tostring(result))

	return result
end

fw.describe("AuraSounds - a registration the engine will not take", function()
	fw.it("registers the rest of the set", function()
		local ids = Standing("AddAuraSound", function(realAdd)
			_G.C_UnitAuras.AddAuraSound = function(trigger, info)
				if info.spellID == FIRST then
					return nil
				end

				return realAdd(trigger, info)
			end

			return auraSounds:RegisterSet(nil, "player", { [FIRST] = true, [SECOND] = true }, FILE, "Master")
		end)

		assert(#ids == 1, "only the id the engine took is appended, got " .. #ids)
		assert(env.auraSounds[ids[1]].SpellId == SECOND, "and it is the one it did take")

		auraSounds:RemoveSet(ids)
	end)

	fw.it("names the spell, the unit and the channel", function()
		local said = Printed(function()
			local ids = Standing("AddAuraSound", function()
				_G.C_UnitAuras.AddAuraSound = function()
					return nil
				end

				return auraSounds:RegisterSet(nil, "party1", { [FIRST] = true }, FILE, "SFX")
			end)

			auraSounds:RemoveSet(ids)
		end)

		assert(#said == 1, "one message, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find(tostring(FIRST), 1, true), "the spell it was for")
		assert(said[1]:find("party1", 1, true), "the unit it was for")
		assert(said[1]:find("SFX", 1, true), "and the channel it was for")
	end)

	fw.it("reports a mapped registration the same way", function()
		local said = Printed(function()
			local ids = Standing("AddAuraSound", function()
				_G.C_UnitAuras.AddAuraSound = function()
					return nil
				end

				return auraSounds:RegisterMappedSet(nil, "party2", { [SECOND] = "Clip.ogg" }, "Voices\\", "Dialog")
			end)

			auraSounds:RemoveSet(ids)
		end)

		assert(#said == 1, "one message, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find(tostring(SECOND), 1, true), "the spell it was for")
		assert(said[1]:find("party2", 1, true), "the unit it was for")
		assert(said[1]:find("Voices\\Clip.ogg", 1, true), "and the file the mapping picked")
	end)

	fw.it("reports a registration with no spell id", function()
		local said = Printed(function()
			Standing("AddAuraSound", function()
				_G.C_UnitAuras.AddAuraSound = function()
					return nil
				end

				auraSounds:Add(Enum.UnitAuraSoundTrigger.Added,
					{ unitToken = "player", soundFileName = FILE, outputChannel = "Master" })
			end)
		end)

		assert(#said == 1, "one message, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find("nil", 1, true), "naming the id it was given: " .. said[1])
	end)

	fw.it("says the same spell again on another unit", function()
		local said = Printed(function()
			local ids = Standing("AddAuraSound", function()
				_G.C_UnitAuras.AddAuraSound = function()
					return nil
				end

				local held = auraSounds:RegisterSet(nil, "player", { [FIRST] = true }, FILE, "Master")

				return auraSounds:RegisterSet(held, "party1", { [FIRST] = true }, FILE, "Master")
			end)

			auraSounds:RemoveSet(ids)
		end)

		assert(#said == 2, "one message per unit, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find("player", 1, true), "the first names the unit it was for")
		assert(said[2]:find("party1", 1, true), "and the second names the other one")
	end)

	fw.it("says nothing while the setting is off", function()
		wipe(env.notifications)
		auraSounds:ResetDebugLog()

		local ids = Standing("AddAuraSound", function()
			_G.C_UnitAuras.AddAuraSound = function()
				return nil
			end

			return auraSounds:RegisterSet(nil, "player", { [FIRST] = true }, FILE, "Master")
		end)

		local heard = table.concat(env.notifications, " | ")

		wipe(env.notifications)
		auraSounds:RemoveSet(ids)

		assert(heard == "", "unexpected messages: " .. heard)
	end)
end)

fw.describe("AuraSounds - a removal the engine throws on", function()
	fw.it("removes the rest of the list, empties it, and pools it", function()
		local ids = auraSounds:RegisterSet(nil, "player",
			{ [FIRST] = true, [SECOND] = true, [THIRD] = true }, FILE, "Master")

		assert(#ids == 3, "three registrations to take back, got " .. #ids)

		local doomed = ids[2]
		local survivors = { ids[1], ids[3] }

		Standing("RemoveAuraSound", function(realRemove)
			_G.C_UnitAuras.RemoveAuraSound = function(handle)
				if handle == doomed then
					error("blocked")
				end

				return realRemove(handle)
			end

			auraSounds:RemoveSet(ids)
		end)

		assert(#ids == 0, "the list is emptied, got " .. #ids)

		for _, handle in ipairs(survivors) do
			assert(env.auraSounds[handle] == nil, "the loop carried on past the throw")
		end

		local reused = auraSounds:RegisterSet(nil, "player", { [FIRST] = true }, FILE, "Master")

		assert(reused == ids, "the list went back to the pool")

		auraSounds:RemoveSet(reused)
	end)

	fw.it("says once what a whole list of failing removals threw", function()
		local ids = auraSounds:RegisterSet(nil, "player",
			{ [FIRST] = true, [SECOND] = true, [THIRD] = true }, FILE, "Master")

		local said = Printed(function()
			Standing("RemoveAuraSound", function()
				_G.C_UnitAuras.RemoveAuraSound = function()
					error("blocked")
				end

				auraSounds:RemoveSet(ids)
			end)
		end)

		assert(#said == 1, "one message for three failures, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find("blocked", 1, true), "carrying what the engine threw")
	end)
end)

fw.describe("AuraSounds - the ceiling on what one session says", function()
	---Fails every registration of a set big enough to run past the ceiling.
	local function Flood()
		local ids = Standing("AddAuraSound", function()
			_G.C_UnitAuras.AddAuraSound = function()
				return nil
			end

			return auraSounds:RegisterSet(nil, "player", SpellSet(30), FILE, "Master")
		end)

		auraSounds:RemoveSet(ids)
	end

	fw.it("stops at ten lines however many ids fail at once", function()
		local said = Printed(Flood)

		assert(#said == 11, "ten failures and one summary, got " .. #said)

		for index = 1, 10 do
			assert(said[index]:find("Sound registration failed", 1, true),
				"line " .. index .. " names a failed registration")
		end

		assert(said[11]:find("No more sound failures", 1, true), "and the last one is the summary: " .. said[11])
	end)

	fw.it("prints the summary once no matter how many more failures pile up behind it", function()
		local said = Printed(function()
			Standing("AddAuraSound", function()
				_G.C_UnitAuras.AddAuraSound = function()
					return nil
				end

				local held = auraSounds:RegisterSet(nil, "player", SpellSet(10), FILE, "Master")

				-- The same ten four times over, so the throttle hides forty the ceiling never saw.
				for _ = 1, 4 do
					auraSounds:RegisterSet(held, "player", SpellSet(10), FILE, "Master")
				end

				auraSounds:RegisterSet(held, "player", { [900001] = true }, FILE, "Master")
				auraSounds:RemoveSet(held)
			end)
		end)

		assert(#said == 11, "ten failures and one summary, got " .. #said)
		assert(not said[11]:find("%d"), "the summary carries no count: " .. said[11])
	end)

	fw.it("says as much again once the log has been cleared", function()
		local first = Printed(Flood)
		local second = Printed(Flood)

		assert(#first == 11, "the first run stops at eleven lines, got " .. #first)
		assert(#second == 11, "and the clear gives the next run its lines back, got " .. #second)
	end)
end)

fw.describe("AuraSounds - where the engine takes a registration", function()
	---Moves the player to a kind of place and stales the snapshot the gate reads off.
	---@param instanceType string
	local function Zone(instanceType)
		env.inInstance = instanceType ~= "none"
		env.instanceType = instanceType
		env.invalidateWorldState()
	end

	---Registers one spell in the place named and hands back what the engine was asked for.
	---@param instanceType string
	---@param inCombat boolean? whether the player is fighting while the pass runs
	---@return number handles
	---@return number calls
	local function RegisterIn(instanceType, inCombat)
		Zone(instanceType)
		env.inCombat = inCombat == true

		local before = env.auraSoundAdds
		local ids = auraSounds:RegisterSet(nil, "player", { [FIRST] = true }, FILE, "Master")
		local handles, calls = #ids, env.auraSoundAdds - before

		auraSounds:RemoveSet(ids)
		env.inCombat = false
		Zone("none")

		return handles, calls
	end

	fw.it("registers in the open world, a battleground and an arena, fighting or not", function()
		for _, place in ipairs({ "none", "pvp", "arena" }) do
			for _, inCombat in ipairs({ false, true }) do
				local handles, calls = RegisterIn(place, inCombat)
				local when = place .. " with combat " .. tostring(inCombat)

				assert(handles == 1, "one handle in " .. when .. ", got " .. handles)
				assert(calls == 1, "one engine call in " .. when .. ", got " .. calls)
			end
		end
	end)

	fw.it("registers in a dungeon or a raid out of combat", function()
		for _, place in ipairs({ "party", "raid" }) do
			local handles, calls = RegisterIn(place, false)

			assert(handles == 1, "one handle in " .. place .. ", got " .. handles)
			assert(calls == 1, "one engine call in " .. place .. ", got " .. calls)
		end
	end)

	fw.it("asks the engine for nothing in a dungeon or a raid in combat", function()
		for _, place in ipairs({ "party", "raid" }) do
			local handles, calls = RegisterIn(place, true)

			assert(handles == 0, "no handle in " .. place .. ", got " .. handles)
			assert(calls == 0, "and no engine call in " .. place .. ", got " .. calls)
		end
	end)

	fw.it("treats a kind of place the allow-list has never met as the restricted kind", function()
		local handles, calls = RegisterIn("scenario", true)

		assert(handles == 0, "no handle while fighting, got " .. handles)
		assert(calls == 0, "and no engine call, got " .. calls)

		handles, calls = RegisterIn("scenario", false)

		assert(handles == 1, "one handle out of combat, got " .. handles)
		assert(calls == 1, "and one engine call, got " .. calls)
	end)

	-- Through Add rather than RegisterSet, so the gate staying ahead of both the engine call and
	-- the reporting is what the assertions rest on.
	fw.it("says nothing about a registration it never made", function()
		local before = env.auraSoundAdds
		local said = Printed(function()
			Zone("raid")
			env.inCombat = true

			auraSounds:Add(Enum.UnitAuraSoundTrigger.Added, {
				unitToken = "player",
				spellID = FIRST,
				soundFileName = FILE,
				outputChannel = "Master",
			})

			env.inCombat = false
			Zone("none")
		end)

		assert(env.auraSoundAdds == before, "the engine was never asked")
		assert(#said == 0, "nothing printed, got " .. table.concat(said, " | "))
	end)

	fw.it("holds a noted skip for the recovery, and forgets it once asked", function()
		auraSounds:ConsumeSkipped()
		auraSounds:NoteSkipped()

		assert(auraSounds:ConsumeSkipped() == true, "the skip was recorded")
		assert(auraSounds:ConsumeSkipped() == false, "and asking again clears it")
	end)

	-- The predicate is asked on every pass a module makes, whatever the player has switched on,
	-- so only a caller that knows it had work to do may put the recovery on the hook.
	fw.it("notes nothing on the answer alone", function()
		auraSounds:ConsumeSkipped()

		local handles = RegisterIn("party", true)

		assert(handles == 0, "the pass was refused, got " .. handles)
		assert(auraSounds:ConsumeSkipped() == false, "and being refused is not a noted skip")
	end)
end)
