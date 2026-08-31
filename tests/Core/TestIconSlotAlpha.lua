-- Which client setter an IconSlotContainer slot's alpha reaches, picked on the Lua type of what
-- the caller passed.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
-- For an alpha the client hands over secret, which the addon may pass on but never inspect.
local wow = require("WowApi")

local env = moduleEnv.build()
local iconSlotContainer = env.addon.Core.IconSlotContainer

local ICON = 134400

---A container with its first slot already built, and the record of every alpha call the layer
---frame takes from then on. Instrumented after the build so nothing the first SetSlot did is
---counted against the call under test.
---@return IconSlotContainer container, table calls
local function BuiltSlot()
	local container = iconSlotContainer:New(_G.UIParent, 1, 30, 2, "AlphaTest")

	container:SetSlot(1, { Texture = ICON })

	local frame = container.Slots[1].Container.Frame
	local calls = {}

	frame.SetAlpha = function(_, value)
		calls[#calls + 1] = { Setter = "SetAlpha", Value = value }
	end

	frame.SetAlphaFromBoolean = function(_, value)
		calls[#calls + 1] = { Setter = "SetAlphaFromBoolean", Value = value }
	end

	return container, calls
end

---@param calls table
---@return string setter, any value
local function Only(calls)
	assert(#calls == 1, "one alpha call per slot update, got " .. #calls)

	return calls[1].Setter, calls[1].Value
end

fw.describe("IconSlotContainer - the alpha a slot is given", function()
	fw.it("sets a number straight onto the layer", function()
		local container, calls = BuiltSlot()

		container:SetSlot(1, { Texture = ICON, Alpha = 0.4 })

		local setter, value = Only(calls)

		assert(setter == "SetAlpha", "a number the addon worked out itself, got " .. setter)
		assert(value == 0.4, "at the value it was given, got " .. tostring(value))
	end)

	fw.it("routes a boolean through the setter that takes one", function()
		local container, calls = BuiltSlot()

		container:SetSlot(1, { Texture = ICON, Alpha = true })

		local setter, value = Only(calls)

		assert(setter == "SetAlphaFromBoolean", "a boolean has its own setter, got " .. setter)
		assert(value == true, "handed over as it stands, got " .. tostring(value))
	end)

	fw.it("routes a value the client keeps secret through the same one", function()
		local container, calls = BuiltSlot()
		local secret = wow.markSecret({})

		container:SetSlot(1, { Texture = ICON, Alpha = secret })

		local setter, value = Only(calls)

		-- The secret guard is checked before the type check, so a secret never reaches type().
		assert(setter == "SetAlphaFromBoolean", "reading it to pick a number would abort the handler")
		assert(value == secret, "and it reaches the client untouched")
	end)

	fw.it("routes a secret number through the boolean setter, not SetAlpha", function()
		local container, calls = BuiltSlot()
		local secret = wow.markSecret(211)

		container:SetSlot(1, { Texture = ICON, Alpha = secret })

		local setter, value = Only(calls)

		-- A secret number would pass the live client's type() check and land in SetAlpha,
		-- which the client refuses. The secret guard must catch it first.
		assert(setter == "SetAlphaFromBoolean", "a secret number must not reach SetAlpha, got " .. setter)
		assert(value == secret, "and it reaches the client untouched")
	end)

	fw.it("hands the client nothing at all when the caller passed no alpha", function()
		-- Every caller that wants a slot fully opaque leaves this out, so this is the path most
		-- slots in the addon take.
		local container, calls = BuiltSlot()

		container:SetSlot(1, { Texture = ICON })

		local setter, value = Only(calls)

		assert(setter == "SetAlphaFromBoolean", "still the boolean setter, got " .. setter)
		assert(value == nil, "with nothing in it, got " .. tostring(value))
	end)
end)
