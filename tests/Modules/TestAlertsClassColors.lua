-- Alerts module, class colouring. The icons are normally tinted by category, red importants and
-- green defensives, and this option swaps that for the owner's class colour instead.
--
-- The whole thing turns on a constraint. A button takes its colour in initializeFrame and inside
-- an arena C_Secrets.ShouldAurasBeSecret never clears, so no restyle ever gets to correct it. The
-- colour therefore has to be known before the pair is built, and a pair built for one class can
-- never be recoloured for another. That is why the pairs are keyed by class, and why arena1
-- holding a rogue one match and a mage the next must not reuse the rogue's pair. It would draw
-- the whole match in the wrong colour with nothing able to fix it.
--
-- Asserted on the ring the button actually drew rather than on the stored option, because
-- "the colour was recorded but never reached a button" is exactly the failure worth catching.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local alerts = db.Modules.Alerts

alerts.Enabled.Always = true
alerts.Icons.Enabled = true
alerts.SplitBars = false
alerts.Important.Enabled = true
-- The ring rather than the glow: both take the same colour, and the border is the one whose
-- texture can be picked out of the button by its art.
alerts.Icons.Glow = false
alerts.Icons.Border = true
alerts.Icons.ClassColors = true

env.loadModule("src/Modules/Alerts/Sound.lua")
env.loadModule("src/Modules/Alerts/Display.lua")
env.loadModule("src/Modules/Alerts/Module.lua")
local module = env.addon.Modules.AlertsModule
module:Init()
-- Init only builds the lifecycle. A module sets itself up on the first refresh that finds it
-- enabled, which in the addon is the one PLAYER_ENTERING_WORLD drives.
module:Refresh()

local events = assert(acm.lastFrameForEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS"), "alerts event frame")

local BORDER_ASSET = env.addon.Core.BorderTextures:GetDispelAsset()
-- Spec ids the tests hand out, mapped to classes the mock knows a colour for.
local ROGUE_SPEC, MAGE_SPEC = 259, 62
env.specClasses[ROGUE_SPEC] = "ROGUE"
env.specClasses[MAGE_SPEC] = "MAGE"

local ROGUE = _G.RAID_CLASS_COLORS.ROGUE
local MAGE = _G.RAID_CLASS_COLORS.MAGE
-- Priest is white, which is also what stands in for Precognition (a PvP talent, not a class spell).
local PRIEST = _G.RAID_CLASS_COLORS.PRIEST
-- The shipped defensive tint, i.e. what a category-coloured defensive icon is ringed in.
local CATEGORY_DEFENSIVE = { 0.2, 1, 0.2 }

---The live (enabled) defensive container for a token. Class keying leaves the pairs built for
---other classes parked and still tagged with the token, so the enabled one is the one drawing.
local function liveDefOf(token)
	local found
	for _, container in ipairs(env.containersForUnit(token)) do
		if env.groupCount(container) == 3 and container._enabled then
			found = container
		end
	end
	return found
end

---The colour the first defensive button's ring was actually drawn in, as {r, g, b}.
local function ringColorOf(token)
	local container = liveDefOf(token)
	local button = container and container:GetAuraGroupFrame("bigdef", 1)

	for _, texture in ipairs(button and button._createdTextures or {}) do
		local asset = texture._lastArgs.SetTexture

		if asset ~= nil and asset[1] == BORDER_ASSET then
			return texture._lastArgs.SetVertexColor
		end
	end
end

---@param color table?
---@param expected table
local function isColor(color, expected)
	return color ~= nil
		and color[1] == expected[1] and color[2] == expected[2] and color[3] == expected[3]
end

---Enters an arena whose opponents hold the given specs, from a clean world load so the
---high-water opponent count starts over. A nil entry models a spec the client will not give up.
local function enterArenaWithSpecs(...)
	local specs = { n = select("#", ...), ... }

	env.inInstance = false
	env.instanceType = "none"
	env.arenaSpecs = {}
	env.arenaOpponents = 0
	env.invalidateWorldState()
	env.loadWorld(module)

	env.inInstance = true
	env.instanceType = "arena"
	env.invalidateWorldState()
	env.loadWorld(module)

	for index = 1, specs.n do
		env.arenaSpecs["arena" .. index] = specs[index]
	end

	-- The opponent count comes off the spec list, so an arena of unnamed specs still has to say
	-- how many there are.
	env.arenaOpponents = specs.n
	events:TriggerEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
end

fw.describe("Alerts - colouring the icons by class", function()
	fw.it("takes an arena opponent's colour from their specialisation", function()
		-- The unit's own class is secret in here. The spec is not, and a spec belongs to exactly
		-- one class, which is the only route to a readable colour.
		enterArenaWithSpecs(ROGUE_SPEC, MAGE_SPEC)

		assert(isColor(ringColorOf("arena1"), { ROGUE.r, ROGUE.g, ROGUE.b }),
			"arena1 is ringed in the rogue colour")
		assert(isColor(ringColorOf("arena2"), { MAGE.r, MAGE.g, MAGE.b }),
			"arena2 is ringed in the mage colour")
	end)

	fw.it("falls back to the category tints when the client will not name a class", function()
		enterArenaWithSpecs(nil, nil)

		assert(isColor(ringColorOf("arena1"), CATEGORY_DEFENSIVE),
			"an unnamed class keeps the defensive category tint")
	end)

	fw.it("uses the category tints when the option is off", function()
		alerts.Icons.ClassColors = false
		enterArenaWithSpecs(ROGUE_SPEC)

		assert(isColor(ringColorOf("arena1"), CATEGORY_DEFENSIVE), "the category tint is back")

		alerts.Icons.ClassColors = true
	end)
end)

fw.describe("Alerts - the test mode preview", function()
	local display = env.addon.Modules.Alerts.Display

	---The colours the preview drew its icon borders in.
	local function previewColors()
		local bar = display:GetContainer()
		local colors = {}

		for index = 1, bar.Count do
			local slot = bar.Slots[index]
			local border = slot and slot.IsUsed and slot.Container and slot.Container.Border
			local color = border and border._shown and border._lastArgs.SetVertexColor

			if color then
				colors[#colors + 1] = color
			end
		end

		return colors
	end

	local function previewWith(classColors)
		module:StopTesting()
		alerts.Icons.ClassColors = classColors
		module:StartTesting()

		local colors = previewColors()
		module:StopTesting()

		return colors
	end

	fw.it("draws the preview in class colours, not category colours", function()
		-- The option had no visible effect in test mode until the preview was taught about it,
		-- which reads as the setting being broken.
		local colors = previewWith(true)
		assert(#colors > 0, "the preview drew some rings")

		local sawClass, sawCategory = false, false
		for _, color in ipairs(colors) do
			if isColor(color, { MAGE.r, MAGE.g, MAGE.b }) then
				sawClass = true
			end
			if isColor(color, CATEGORY_DEFENSIVE) then
				sawCategory = true
			end
		end

		assert(sawClass, "a preview spell is drawn in its owner's class colour")
		assert(not sawCategory, "and the category tint is gone from the row")
	end)

	fw.it("gives two icons of one class the same colour, as a real bar would", function()
		-- A live bar colours per enemy, so every icon on one enemy matches. The preview spells are
		-- chosen so the row shows that: the mage's Ice Block and Combustion match, and so do the
		-- priest's Guardian Spirit and Precognition, which spans both categories.
		local colors = previewWith(true)
		local mage, priest = 0, 0

		for _, color in ipairs(colors) do
			if isColor(color, { MAGE.r, MAGE.g, MAGE.b }) then
				mage = mage + 1
			end
			if isColor(color, { PRIEST.r, PRIEST.g, PRIEST.b }) then
				priest = priest + 1
			end
		end

		assert(mage >= 2, "two mage spells share the one colour, got " .. mage)
		assert(priest >= 2, "and the priest's defensive and important match, got " .. priest)
	end)

	fw.it("stands Precognition in as a class that can actually take it", function()
		-- It is a PvP talent rather than a class spell, so the preview has to pick an owner. A
		-- rogue cannot take it, and showing one would teach the wrong thing about the talent.
		local testSpells = env.addon.Core.TestSpells

		for _, entry in ipairs(testSpells.Alerts.Important) do
			if entry.SpellId == 377362 then
				assert(entry.Class == "PRIEST",
					"Precognition stands in as a priest, got " .. tostring(entry.Class))
				return
			end
		end

		error("Precognition is no longer in the important preview spells")
	end)

	fw.it("goes back to the category tints when the option is off", function()
		local colors = previewWith(false)
		local sawCategory = false

		for _, color in ipairs(colors) do
			if isColor(color, CATEGORY_DEFENSIVE) then
				sawCategory = true
			end
		end

		assert(sawCategory, "the defensive category tint is what the preview shows")

		alerts.Icons.ClassColors = true
	end)
end)

fw.describe("Alerts - a token that changes class between matches", function()
	fw.it("does not reuse the pair built for the previous class", function()
		-- The bug this guards is silent and lasts a whole match: reusing arena1's rogue pair for
		-- a mage rings every alert in the rogue colour, and no restyle can reach those buttons
		-- to fix it while the match is on.
		enterArenaWithSpecs(ROGUE_SPEC)
		local roguePair = liveDefOf("arena1")
		assert(roguePair, "the rogue pair is live")
		assert(isColor(ringColorOf("arena1"), { ROGUE.r, ROGUE.g, ROGUE.b }), "in the rogue colour")

		enterArenaWithSpecs(MAGE_SPEC)

		assert(liveDefOf("arena1") ~= roguePair, "a different class gets a different pair")
		assert(isColor(ringColorOf("arena1"), { MAGE.r, MAGE.g, MAGE.b }),
			"and the mage's own colour is what gets drawn")
	end)

	fw.it("parks the pair it moved off, so one unit is never drawn twice", function()
		local live = 0
		for _, container in ipairs(env.containersForUnit("arena1")) do
			if env.groupCount(container) == 3 and container._enabled then
				live = live + 1
			end
		end

		assert(live == 1, "one live defensive container on arena1, got " .. live)
	end)

	fw.it("takes the first pair back when the class comes round again", function()
		-- Keying rather than rebuilding is what keeps this bounded: without reuse every match
		-- would abandon a pair per opponent, and a WoW frame can never be given back.
		local before = env.auraContainerCount()

		enterArenaWithSpecs(ROGUE_SPEC)

		assert(env.auraContainerCount() == before,
			"a class seen before built " .. (env.auraContainerCount() - before) .. " more containers")
		assert(isColor(ringColorOf("arena1"), { ROGUE.r, ROGUE.g, ROGUE.b }),
			"and it is the rogue pair that came back")
	end)
end)
