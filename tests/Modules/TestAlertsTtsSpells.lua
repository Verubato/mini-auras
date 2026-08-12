-- The per-spell TTS switches on the Alerts page. Muting is an opt-out list the module hands to
-- the engine as an exclusion, so the failure it guards is quiet on both sides: a muted spell that
-- keeps announcing, or a settings change that never reaches the live registrations because the
-- signature did not notice it.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local addon = env.addon

env.loadModule("src/Modules/Alerts/Sound.lua")

local sound = addon.Modules.Alerts.Sound
local ttsSounds = addon.Core.AuraTtsSounds
local tts = db.Modules.AlertsModule.TTS

local PLATE = "nameplate1"
local ICY_VEINS = 12472
local ICE_BLOCK = 45438
local DEATHMARK = 360194

sound:Init()

---The spell ids the engine currently holds a registration for.
---@return table<number, boolean>
local function LiveSpellIds()
	local live = {}

	for _, registration in pairs(env.auraSounds) do
		live[registration.SpellId] = true
	end

	return live
end

---@param map table<number, string>
---@return number
local function CountOf(map)
	local count = 0

	for _ in pairs(map) do
		count = count + 1
	end

	return count
end

local function Reset()
	env.setModuleEnabled("AlertsModule", true)
	tts.Important.Enabled = true
	tts.Defensive.Enabled = true
	tts.EnemyDebuff.Enabled = false
	tts.Important.MutedSpellIds = {}
	tts.Defensive.MutedSpellIds = {}
	tts.EnemyDebuff.MutedSpellIds = {}
	db.Modules.AlertsModule.Sound.Important.Enabled = false
	db.Modules.AlertsModule.Sound.Defensive.Enabled = false

	sound:RemoveAllTokens()
	sound:RemoveAllySounds()
	sound:Refresh({})
	sound:RegisterToken(PLATE)
end

fw.describe("Alerts TTS - per-spell muting", function()
	fw.before_each(Reset)

	fw.it("announces every spell with a clip until one is switched off", function()
		local live = LiveSpellIds()

		assert(live[ICY_VEINS], "an important spell is registered")
		assert(live[ICE_BLOCK], "and a defensive one")
	end)

	fw.it("leaves a muted spell unregistered", function()
		tts.Important.MutedSpellIds[ICY_VEINS] = true
		sound:Refresh({ [PLATE] = true })

		local live = LiveSpellIds()

		assert(not live[ICY_VEINS], "the muted spell has no clip to play")
		assert(live[ICE_BLOCK], "the rest of the list is untouched")
	end)

	fw.it("mutes only the category the spell was switched off in", function()
		-- Deathmark carries a clip in both Important and EnemyDebuff; the tab lists it twice
		-- because they are announced on different units.
		tts.EnemyDebuff.Enabled = true
		tts.Important.MutedSpellIds[DEATHMARK] = true
		sound:Refresh({ [PLATE] = true })
		sound:RefreshAllySounds(true)

		local nameplate, ally = false, false

		for _, registration in pairs(env.auraSounds) do
			if registration.SpellId == DEATHMARK then
				if registration.Unit == PLATE then
					nameplate = true
				else
					ally = true
				end
			end
		end

		assert(not nameplate, "muted where it was switched off")
		assert(ally, "and still announced where it was not")
	end)

	fw.it("a token registered after the change is muted too", function()
		tts.Important.MutedSpellIds[ICY_VEINS] = true
		sound:Refresh({ [PLATE] = true })
		sound:RegisterToken("nameplate2")

		for _, registration in pairs(env.auraSounds) do
			assert(registration.SpellId ~= ICY_VEINS, "a fresh plate reads the same list")
		end
	end)

	fw.it("unmuting registers the spell again", function()
		tts.Important.MutedSpellIds[ICY_VEINS] = true
		sound:Refresh({ [PLATE] = true })

		tts.Important.MutedSpellIds[ICY_VEINS] = nil
		sound:Refresh({ [PLATE] = true })

		assert(LiveSpellIds()[ICY_VEINS], "the signature has to notice the set changing")
	end)

	fw.it("muting everything in a category registers none of it", function()
		for spellId in pairs(ttsSounds.Important) do
			tts.Important.MutedSpellIds[spellId] = true
		end

		sound:Refresh({ [PLATE] = true })

		local live = LiveSpellIds()
		local defensiveCount = 0

		for spellId in pairs(ttsSounds.Important) do
			assert(not live[spellId], "nothing left in the muted category")
		end

		for spellId in pairs(ttsSounds.Defensive) do
			if live[spellId] then
				defensiveCount = defensiveCount + 1
			end
		end

		assert(defensiveCount == CountOf(ttsSounds.Defensive), "the other category is whole")
	end)
end)
