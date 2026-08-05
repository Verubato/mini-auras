-- Precog's sound option. On 12.1 the addon is never told that the buff landed - it only ever
-- hands secret values to secure setters - so the sound cannot be played from a callback. It is
-- registered with the engine instead, against the two spell ids on the Added trigger, and the
-- engine plays it. The failure this guards is silent: a registration that is never made, or one
-- that is never taken back when the module is switched off, leaves a sound that plays forever.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local addon = env.addon
local options = db.Modules.PrecogModule

local PRECOGNITION = 377362
local NULLIFYING_SHROUD = 378464

env.loadModule("src/Modules/Precog/Sound.lua")

local sound = addon.Modules.Precog.Sound

sound:Init()

---@type table<number, boolean>
local SPELL_IDS = {
	[PRECOGNITION] = true,
	[NULLIFYING_SHROUD] = true,
}

---The registrations currently held by the engine, keyed by the spell they fire on.
---@return table<number, table>
local function LiveRegistrations()
	local live = {}

	for _, registration in pairs(env.auraSounds) do
		live[registration.SpellId] = registration
	end

	return live
end

local function Reset()
	env.setModuleEnabled("PrecogModule", true)
	options.Sound.Enabled = true
	options.Sound.File = "ElectricalSpark.ogg"
	options.Sound.Channel = "Master"
	sound:Clear()
	sound:Refresh(SPELL_IDS)
end

fw.describe("Precog sound - registration", function()
	fw.before_each(Reset)

	fw.it("registers both precog spells on the added trigger", function()
		local live = LiveRegistrations()

		assert(live[PRECOGNITION], "Precognition is registered")
		assert(live[NULLIFYING_SHROUD], "so is Nullifying Shroud")

		for _, registration in pairs(live) do
			assert(registration.Trigger == Enum.UnitAuraSoundTrigger.Added,
				"the sound fires as the aura lands, not when it drops")
			assert(registration.Unit == "player", "precog is a self buff")
			assert(registration.File:find("ElectricalSpark%.ogg"), "with the configured file")
			assert(registration.Channel == "Master", "on the configured channel")
		end
	end)

	fw.it("registers nothing while the option is off", function()
		options.Sound.Enabled = false
		sound:Refresh(SPELL_IDS)

		assert(next(env.auraSounds) == nil, "no engine-side sound to play")
	end)

	fw.it("hands the registrations back when the option is switched off", function()
		assert(next(env.auraSounds) ~= nil, "registered to begin with")

		options.Sound.Enabled = false
		sound:Refresh(SPELL_IDS)

		assert(next(env.auraSounds) == nil, "a stale registration would play forever")
	end)

	fw.it("registers nothing while the module is disabled", function()
		env.setModuleEnabled("PrecogModule", false)
		sound:Refresh(SPELL_IDS)

		assert(next(env.auraSounds) == nil, "a disabled module makes no noise")
	end)

	fw.it("re-registers when the sound file changes", function()
		options.Sound.File = "Sonar.ogg"
		sound:Refresh(SPELL_IDS)

		local live = LiveRegistrations()
		assert(live[PRECOGNITION].File:find("Sonar%.ogg"), "the file is baked into each one")
	end)

	fw.it("does no work when nothing has changed", function()
		local before = env.auraSoundAdds

		sound:Refresh(SPELL_IDS)
		sound:Refresh(SPELL_IDS)

		assert(env.auraSoundAdds == before, "a repeat refresh must not re-register")
	end)
end)
