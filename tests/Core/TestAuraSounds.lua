-- The shared wrapper around C_UnitAuras.AddAuraSound and RemoveAuraSound. Those calls are known to
-- throw, so a throw that escaped would take out whatever module refreshes after the one that hit it.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local auraSounds = env.addon.Core.AuraSounds
local db = env.db

local FILE = "Interface\\AddOns\\MiniAuras\\Sounds\\Effects\\Sonar.ogg"
local FIRST = 700001
local SECOND = 700002
local THIRD = 700003

db.SoundDebugMessages = false

---Runs body with the messages switched on and the throttle empty, and hands back what it printed.
---@param body function
---@return string[]
local function Printed(body)
	wipe(env.notifications)
	auraSounds:ResetDebugLog()
	db.SoundDebugMessages = true

	local ok, err = pcall(body)

	db.SoundDebugMessages = false

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
---finished or not. The body installs whatever stand-in it wants.
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

fw.describe("AuraSounds - a registration the engine throws on", function()
	fw.it("registers the rest of the set", function()
		local ids = Standing("AddAuraSound", function(realAdd)
			_G.C_UnitAuras.AddAuraSound = function(trigger, info)
				if info.spellID == FIRST then
					error("blocked")
				end

				return realAdd(trigger, info)
			end

			return auraSounds:RegisterSet(nil, "player", { [FIRST] = true, [SECOND] = true }, FILE, "Master")
		end)

		assert(#ids == 1, "only the id the engine took is appended, got " .. #ids)
		assert(env.auraSounds[ids[1]].SpellId == SECOND, "and it is the one that did not throw")

		auraSounds:RemoveSet(ids)
	end)

	fw.it("names the spell, the unit and what was thrown", function()
		local said = Printed(function()
			local ids = Standing("AddAuraSound", function()
				_G.C_UnitAuras.AddAuraSound = function()
					error("blocked")
				end

				return auraSounds:RegisterSet(nil, "party1", { [FIRST] = true }, FILE, "SFX")
			end)

			auraSounds:RemoveSet(ids)
		end)

		assert(#said == 1, "one message, got " .. #said .. ": " .. table.concat(said, " | "))
		assert(said[1]:find(tostring(FIRST), 1, true), "the spell it was for")
		assert(said[1]:find("party1", 1, true), "the unit it was for")
		assert(said[1]:find("SFX", 1, true), "the channel it was for")
		assert(said[1]:find("blocked", 1, true), "and what the engine threw")
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
		assert(said[1]:find("Voices\\Clip.ogg", 1, true), "the file the mapping picked")
		assert(said[1]:find("no handle", 1, true), "and that the engine simply gave nothing back")
	end)

	fw.it("reports a registration with no spell id rather than throwing itself", function()
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
					error("blocked")
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
				error("blocked")
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
				error("blocked")
			end

			return auraSounds:RegisterSet(nil, "player", SpellSet(30), FILE, "Master")
		end)

		auraSounds:RemoveSet(ids)
	end

	fw.it("stops at ten lines however many ids fail at once", function()
		local said = Printed(Flood)

		assert(#said == 11, "ten failures and one summary, got " .. #said)

		for index = 1, 10 do
			assert(said[index]:find("blocked", 1, true), "line " .. index .. " says what was thrown")
		end

		assert(said[11]:find("No more sound failures", 1, true), "and the last one is the summary: " .. said[11])
	end)

	fw.it("prints the summary once no matter how many more failures pile up behind it", function()
		local said = Printed(function()
			Standing("AddAuraSound", function()
				_G.C_UnitAuras.AddAuraSound = function()
					error("blocked")
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
