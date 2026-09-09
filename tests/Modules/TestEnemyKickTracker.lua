-- Enemy kick tracker: the observer watches the arena team's cast events and the display turns
-- each confirmed interrupt into a timed icon. The wiring between the two is what these cover -
-- an interrupt that produces no icon, or one cast producing several, is invisible in game until
-- someone is watching the bar during a match.

local fw = require("Framework")
local wow = require("WowApi")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db

-- The player's own spec drives IsEnabledForPlayer. Always sidesteps it for most of these.
local options = db.Modules.EnemyKickTracker
options.Enabled.Always = true

env.loadModule("src/Modules/EnemyKickTracker/Observer.lua")
env.loadModule("src/Modules/EnemyKickTracker/Display.lua")
env.loadModule("src/Modules/EnemyKickTracker/Module.lua")

local module = assert(env.addon.Modules.EnemyKickTrackerModule, "module registered")
local display = assert(env.addon.Modules.EnemyKickTracker.Display, "display registered")
local observer = assert(env.addon.Modules.EnemyKickTracker.Observer, "observer registered")
local BORDER_ASSET = env.addon.Core.BorderTextures:GetDispelAsset()
local glowStyles = env.addon.Core.GlowStyles
local GLOW_ASSET = glowStyles.Specs[glowStyles.DefaultName].Texture
-- The slider floors from Config/Panels/EnemyKickTracker.lua, where a name is at its smallest.
local MIN_ICON_SIZE = 20
local MIN_FONT_SCALE = 0.5
local DEFAULT_ICON_SIZE = options.Icons.Size
-- The floor the name font is held at, whatever the two above multiply out to.
local MIN_NAME_FONT_SIZE = 6

env.inInstance = true
env.instanceType = "arena"
env.invalidateWorldState()

module:Init()

-- The module hears no world event of its own. Entering an arena reaches it as the addon-wide
-- Refresh that PLAYER_ENTERING_WORLD drives.
local function enterWorld()
	module:Refresh()
end

---The frame the observer registered the given unit's cast events on. RegisterUnitEvent records
---the token as the event's value, so the registration itself identifies the frame.
local function castFrameFor(unit)
	for i = #acm.frames, 1, -1 do
		local frame = acm.frames[i]
		if frame._events and frame._events.UNIT_SPELLCAST_INTERRUPTED == unit then
			return frame
		end
	end
end

---Icons currently on the bar. The container hides every slot frame it is not using, so the shown
---ones are exactly the live kicks.
local function usedSlots()
	local count = 0
	for _, frame in ipairs(acm.frames) do
		if frame._name and frame._name:match("^MiniAuras_Slot_") and frame:IsShown() then
			count = count + 1
		end
	end
	return count
end

---The kicker labels on screen, in slot order. The display puts one font string on each slot
---frame and hides it again whenever that slot has nobody to name.
local function shownNames()
	local labels = {}
	for _, frame in ipairs(acm.frames) do
		if frame._name and frame._name:match("^MiniAuras_Slot_") then
			local label = frame._createdFontStrings[1]
			if label and label:IsShown() then
				labels[#labels + 1] = label
			end
		end
	end
	return labels
end

---The border rings on screen, in slot order, found by the art every one of them wears.
local function shownBorders()
	local borders = {}
	for _, frame in ipairs(acm.frames) do
		for _, texture in ipairs(frame._createdTextures or {}) do
			local asset = texture._lastArgs.SetTexture
			if asset and asset[1] == BORDER_ASSET and texture:IsShown() then
				borders[#borders + 1] = texture
			end
		end
	end
	return borders
end

---The static glow overlays on screen. Each one is a frame of its own carrying a single texture,
---and the frame is what gets shown, so its state is what says the glow is up.
local function shownGlows()
	local glows = {}
	for _, frame in ipairs(acm.frames) do
		for _, texture in ipairs(frame._createdTextures or {}) do
			local asset = texture._lastArgs.SetTexture
			if asset and asset[1] == GLOW_ASSET and frame:IsShown() then
				glows[#glows + 1] = texture
			end
		end
	end
	return glows
end

---Kicks the player's cast, crediting the given GUID. A fresh start event each time, since one
---cast only ever produces one icon.
---@param guid any
local function kicked(guid)
	local frame = assert(castFrameFor("player"), "player cast frame")

	frame:TriggerEvent("UNIT_SPELLCAST_START", "player")
	frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-who", 0, guid)
end

fw.describe("EnemyKickTracker - arena gating", function()
	fw.it("registers the arena team's cast events on entering an arena", function()
		enterWorld()

		for _, unit in ipairs({ "player", "party1", "party2" }) do
			assert(castFrameFor(unit), "no cast frame watching " .. unit)
		end
	end)

	fw.it("drops them again outside an arena", function()
		local frame = castFrameFor("player")
		env.inInstance = false
		env.instanceType = "none"
		env.invalidateWorldState()
		enterWorld()

		assert(not frame._events.UNIT_SPELLCAST_INTERRUPTED, "cast events must not stay live in the world")

		env.inInstance = true
		env.instanceType = "arena"
		env.invalidateWorldState()
		enterWorld()
		assert(castFrameFor("player"), "and come back on re-entry")
	end)
end)

fw.describe("EnemyKickTracker - interrupt to icon", function()
	local function castFrame()
		return assert(castFrameFor("player"), "player cast frame")
	end

	fw.before_each(function()
		module:Refresh()
		display:Clear()
	end)

	fw.it("an interrupted cast puts one icon on the bar", function()
		local frame = castFrame()
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")

		local before = usedSlots()
		-- arg 4 is interruptedBy, and without it this is an ordinary cast ending.
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-1", 0, "arena1")
		assert(usedSlots() == before + 1, "expected one icon, got " .. (usedSlots() - before))
	end)

	fw.it("the repeat events for the same cast do not stack more icons", function()
		local frame = castFrame()
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-2", 0, "arena1")

		local after = usedSlots()
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-2", 0, "arena1")
		frame:TriggerEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "cast-2", 0, "arena1")
		assert(usedSlots() == after, "one cast must only ever produce one icon")
	end)

	fw.it("a cast that simply finished is not an interrupt", function()
		local frame = castFrame()
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")

		local before = usedSlots()
		-- No interruptedBy: the cast ran to completion, or the channel ended normally.
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-3", 0, nil)
		frame:TriggerEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player", "cast-3", 0, nil)
		assert(usedSlots() == before, "a clean cast end must not draw a kick")
	end)

	fw.it("an ally being interrupted counts too", function()
		local frame = assert(castFrameFor("party2"), "party2 cast frame")
		frame:TriggerEvent("UNIT_SPELLCAST_START", "party2")

		local before = usedSlots()
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "party2", "cast-4", 0, "arena2")
		assert(usedSlots() == before + 1, "the whole arena team is watched, not just the player")
	end)
end)

-- The GUID the stop event carries is secret inside an arena, so the name and the class token it
-- resolves to are secret too: handed to a setter and never read, compared or used as a key.
fw.describe("EnemyKickTracker - attributing a kick", function()
	-- Nothing unregisters an observer callback, so one is installed for the file and only records
	-- while a test has asked it to.
	local capture

	observer:RegisterKickCallback(function(name, class)
		if capture then
			capture.Name, capture.Class = name, class
		end
	end)

	fw.before_each(function()
		capture = nil
		options.Icons.Border = true
		options.Icons.Glow = false
		options.Icons.Color = { R = 1, G = 1, B = 1, A = 1 }
		options.FontScale = 1.0
		options.ShowName = true
		module:Refresh()
		display:Clear()
		wipe(env.unitNames)
		wipe(env.unitClasses)
	end)

	fw.it("hands the interrupter's name and class to the kick callback", function()
		local seen = {}

		capture = seen

		env.unitNames["arena1"] = "Kicker"
		env.unitClasses["arena1"] = "ROGUE"

		kicked("arena1")

		capture = nil

		assert(seen.Name == "Kicker", "the name was dropped, got " .. tostring(seen.Name))
		assert(seen.Class == "ROGUE", "the class was dropped, got " .. tostring(seen.Class))
	end)

	fw.it("draws the name above the icon", function()
		env.unitNames["arena1"] = "Kicker"

		kicked("arena1")

		local labels = shownNames()
		assert(#labels == 1, "one label, got " .. #labels)
		assert(labels[1]:GetText() == "Kicker", "got " .. tostring(labels[1]:GetText()))
	end)

	fw.it("still draws the name with the option on", function()
		options.ShowName = true
		env.unitNames["arena1"] = "Kicker"

		kicked("arena1")

		assert(#shownNames() == 1, "one label, got " .. #shownNames())
	end)

	fw.it("draws no name with the option off", function()
		options.ShowName = false
		env.unitNames["arena1"] = "Kicker"

		kicked("arena1")

		assert(#shownNames() == 0, "a label must not be drawn with the option off")
	end)

	fw.it("blanks a label already on screen when the option is switched off", function()
		env.unitNames["arena1"] = "Kicker"
		kicked("arena1")
		assert(#shownNames() == 1, "the name is up")

		options.ShowName = false
		module:Refresh()

		assert(#shownNames() == 0, "ApplyOptions must blank the label when the option is off")
	end)

	fw.it("draws the name it is not allowed to read", function()
		local name = wow.markSecret({})

		env.unitNames["arena1"] = name

		kicked("arena1")

		local labels = shownNames()
		assert(#labels == 1, "one label, got " .. #labels)
		assert(labels[1]._lastArgs.SetText[1] == name, "the secret name is handed to SetText untouched")
	end)

	fw.it("rings the icon in a class colour it is not allowed to read", function()
		-- RAID_CLASS_COLORS cannot be indexed by a secret, so the colour has to come from the API
		-- call. What it returns is secret too, and only a setter may be given it.
		env.unitClasses["arena1"] = wow.markSecret({})

		kicked("arena1")

		local borders = shownBorders()
		assert(#borders == 1, "one ring, got " .. #borders)
		assert(issecretvalue(borders[1]._lastArgs.SetVertexColor[1]),
			"the secret class colour reached the ring")
	end)

	fw.it("glows the icon in a class colour it is not allowed to read", function()
		-- With no border the glow carries the colour on its own. Its colour cache key comes out of
		-- string.format, which on a secret hands back a string the layer may not compare.
		options.Icons.Glow = true
		module:Refresh()

		env.unitClasses["arena1"] = wow.markSecret({})

		kicked("arena1")

		local glows = shownGlows()

		assert(usedSlots() == 1, "the kick still produced its icon, got " .. usedSlots())
		assert(#glows == 1, "one glow, got " .. #glows)
		assert(issecretvalue(glows[1]._lastArgs.SetVertexColor[1]),
			"the secret class colour reached the glow")

		local layer = glows[1]._parent._parent

		assert(layer._GlowColorKey == nil,
			"a key it cannot compare must not be cached, got " .. tostring(layer._GlowColorKey))
	end)

	fw.it("falls back to the colour the user picked when the class did not resolve", function()
		options.Icons.Color = { R = 0.25, G = 0.5, B = 0.75, A = 1 }
		module:Refresh()

		-- Nothing maps this GUID to a class, which is what an old client answers.
		kicked("arena1")

		local applied = shownBorders()[1]._lastArgs.SetVertexColor
		assert(applied[1] == 0.25 and applied[2] == 0.5 and applied[3] == 0.75,
			"the user's own tint should still draw the ring, got " .. tostring(applied[1]))
	end)

	fw.it("draws no ring with the border option off", function()
		options.Icons.Border = false
		module:Refresh()

		env.unitClasses["arena1"] = "ROGUE"

		kicked("arena1")

		assert(usedSlots() == 1, "the kick still produced its icon, got " .. usedSlots())
		assert(#shownBorders() == 0, "a ring was drawn with the option off")
	end)

	fw.it("clamps a long name to the icon rather than cutting the string down", function()
		-- string.sub on a secret name throws, so the trimming is the client's to do.
		env.unitNames["arena1"] = "Averyveryverylongname"

		kicked("arena1")

		local label = shownNames()[1]
		assert(label:GetText() == "Averyveryverylongname", "the whole string is handed over")
		assert(label._lastArgs.SetWidth[1] == options.Icons.Size,
			"clamped to the icon's width, got " .. tostring(label._lastArgs.SetWidth[1]))
		assert(label._lastArgs.SetWordWrap[1] == false, "and kept on one line")
	end)

	fw.it("sets a real font on the name, sized by the module's own font scale", function()
		-- A bare font string inherits no font, and SetText on one errors on a live client.
		options.FontScale = 1.5
		module:Refresh()

		env.unitNames["arena1"] = "Kicker"
		kicked("arena1")

		local applied = shownNames()[1]._lastArgs.SetFont

		assert(applied and applied[1] ~= nil, "the label was given a font face")
		assert(applied[2] == math.floor(options.Icons.Size * 0.25 * 1.5),
			"the label follows the scale, got " .. tostring(applied and applied[2]))
	end)

	fw.it("keeps the name legible on the smallest icon the sliders allow", function()
		-- The scaled size floors to two points here, which draws nothing anyone can read.
		options.Icons.Size = MIN_ICON_SIZE
		options.FontScale = MIN_FONT_SCALE
		module:Refresh()

		env.unitNames["arena1"] = "Kicker"
		kicked("arena1")

		local applied = shownNames()[1]._lastArgs.SetFont
		local size = applied and applied[2]

		options.Icons.Size = DEFAULT_ICON_SIZE
		module:Refresh()

		assert(size == MIN_NAME_FONT_SIZE, "the name must not go below " ..
			MIN_NAME_FONT_SIZE .. " points, got " .. tostring(size))
	end)

	fw.it("takes the name down with the kick it belongs to", function()
		env.unitNames["arena1"] = "First"
		kicked("arena1")
		assert(#shownNames() == 1, "the name is up")

		acm.runTimers()

		assert(usedSlots() == 0, "the kick expired")
		assert(#shownNames() == 0, "and its name went with it")
	end)

	fw.it("takes every name down when the bar is cleared", function()
		-- What an arena's prep round does, so last match's kickers are not still named.
		env.unitNames["arena1"] = "First"
		kicked("arena1")
		assert(#shownNames() == 1, "the name is up")

		display:Clear()

		assert(#shownNames() == 0, "a cleared bar still names somebody")
	end)
end)

-- Only the player's own interrupted cast reports a class the addon may read. Every other kick
-- falls back to the art the Unknown kicks setting picks.
fw.describe("EnemyKickTracker - identifying the interrupt", function()
	-- Cooldowns are read from KickData rather than repeated, so a balance change moves both.
	local COUNTERSPELL_CD = env.addon.Core.KickData.SpecData[62].KickCd
	local COUNTER_SHOT_CD = env.addon.Core.KickData.SpecData[253].KickCd
	local WIND_SHEAR_CD = env.addon.Core.KickData.SpecData[262].KickCd
	local GENERIC_ICON = "tex:1766"

	---Leaves the arena and comes back, which is the only path that rereads the opponents' specs.
	local function reenterArena()
		env.inInstance = false
		env.instanceType = "none"
		env.invalidateWorldState()
		module:Refresh()

		env.inInstance = true
		env.instanceType = "arena"
		env.invalidateWorldState()
		module:Refresh()
	end

	---Kicks the player's cast and reports what the module handed the display.
	---@param guid any
	---@return table
	local function kickedBy(guid)
		local realAddKick = display.AddKick
		local seen

		display.AddKick = function(self, duration, icon, name, class, atlas)
			seen = { Duration = duration, Icon = icon, Atlas = atlas }
			return realAddKick(self, duration, icon, name, class, atlas)
		end

		kicked(guid)
		display.AddKick = realAddKick

		return assert(seen, "the kick never reached the display")
	end

	fw.before_each(function()
		options.UnknownKickIcon = "class"
		wipe(env.unitClasses)
		wipe(env.arenaSpecs)
		-- A shaman on the enemy team holds the unattributed floor below every cooldown asserted
		-- here, so a fallback duration cannot pass for an identified one.
		env.arenaSpecs.arena1 = 62
		env.arenaSpecs.arena2 = 262
		reenterArena()
		display:Clear()
	end)

	fw.it("draws the interrupt of the class that cut the cast, at its own cooldown", function()
		env.unitClasses["arena1"] = "MAGE"

		local kick = kickedBy("arena1")

		fw.eq(kick.Icon, "tex:2139", "Counterspell's own art")
		fw.eq(kick.Duration, COUNTERSPELL_CD, "and the cooldown that interrupt really has")
		fw.is_nil(kick.Atlas, "an identified kick needs no class crest to stand in")
	end)

	fw.it("identifies a class nobody on the enemy team is playing", function()
		-- No rogue spec is on the team, so the arena tells the addon nothing and the class's own
		-- interrupt has to carry it.
		env.unitClasses["arena1"] = "ROGUE"

		local kick = kickedBy("arena1")

		fw.eq(kick.Icon, GENERIC_ICON, "Kick's art, because Kick is what a rogue interrupts with")
		fw.eq(kick.Duration, env.addon.Core.KickData.SpecData[259].KickCd, "at a rogue's cooldown")
	end)

	fw.it("picks the interrupt most of a split class's specs share", function()
		-- Two hunter specs are up and they interrupt with different spells at different cooldowns.
		-- Counter Shot covers two of the three, so it is the safer thing to show.
		env.arenaSpecs.arena1 = 253
		env.arenaSpecs.arena2 = 255
		reenterArena()
		env.unitClasses["arena1"] = "HUNTER"

		local kick = kickedBy("arena1")

		fw.eq(kick.Icon, "tex:147362", "Counter Shot rather than Muzzle")
		fw.eq(kick.Duration, COUNTER_SHOT_CD, "at the cooldown Counter Shot carries")
	end)

	fw.it("falls back to the shortest cooldown on the team for a class it may not read", function()
		env.unitClasses["arena1"] = wow.markSecret({})

		local kick = kickedBy("arena1")

		fw.eq(kick.Icon, GENERIC_ICON, "no interrupt was named, so the generic icon stands in")
		fw.eq(kick.Duration, WIND_SHEAR_CD, "and the fastest interrupt the team could have")
	end)

	fw.it("crests the icon with a class it may not read", function()
		env.unitClasses["arena1"] = wow.markSecret({})

		local kick = kickedBy("arena1")

		assert(issecretvalue(kick.Atlas), "the crest name is built from a secret and stays one")
	end)

	fw.it("leaves the crest off a kick set to stay generic", function()
		options.UnknownKickIcon = "generic"
		env.unitClasses["arena1"] = wow.markSecret({})

		local kick = kickedBy("arena1")

		fw.eq(kick.Icon, GENERIC_ICON, "the plain kick icon")
		fw.is_nil(kick.Atlas, "and nothing over it")
	end)
end)

fw.describe("EnemyKickTracker - lifecycle", function()
	fw.it("names every preview kick, and takes the names down with the preview", function()
		module:StartTesting()

		local labels = shownNames()
		assert(#labels == 3, "one label per preview icon, got " .. #labels)

		module:StopTesting()
		assert(#shownNames() == 0, "and they go with the preview")
	end)

	fw.it("test mode fills the bar and leaving it empties the bar again", function()
		display:Clear()
		local before = usedSlots()

		module:StartTesting()
		assert(usedSlots() > before, "test mode previews some kicks")

		module:StopTesting()
		assert(usedSlots() == before, "and clears them on the way out")
	end)

	fw.it("test mode swallows live interrupts rather than mixing them in", function()
		module:StartTesting()
		local preview = usedSlots()

		local frame = assert(castFrameFor("player"), "player cast frame")
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-5", 0, "arena1")
		assert(usedSlots() == preview, "a real kick must not land on top of the preview")

		module:StopTesting()
	end)

	fw.it("switching every spec toggle off tears the bar down", function()
		local frame = assert(castFrameFor("player"), "player cast frame")
		frame:TriggerEvent("UNIT_SPELLCAST_START", "player")
		frame:TriggerEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "cast-6", 0, "arena1")
		assert(usedSlots() > 0, "something on the bar to tear down")

		options.Enabled.Always = false
		options.Enabled.Caster = false
		options.Enabled.Healer = false
		module:Refresh()
		assert(usedSlots() == 0, "the icons went with it")
		assert(not frame._events.UNIT_SPELLCAST_INTERRUPTED, "and the events were unregistered")

		options.Enabled.Always = true
		module:Refresh()
		assert(castFrameFor("player"), "re-enabling brings the events back")
	end)

	fw.it("reported no misuse through the whole run", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
