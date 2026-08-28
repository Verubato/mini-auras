-- Alerts module, 12.1 container path: the parts of the bars that are geometry and gating rather
-- than aura data. Three areas, each a silent-failure class:
--
--   * Saved bar anchors are applied verbatim on refresh, and only a drag drop rewrites one,
--     pinned to the edge the row grows from. Anything that converts an anchor from a frame's rect
--     outside a drag has corrupted a profile reset, because the rect only matches the rendered
--     row while test icons are actually up.
--   * The prep room hides every display, and only the match-state event brings them back. A
--     mistake here means no alerts for the whole arena.
--   * Split mode gives importants their own bar and container. Combined mode renders them as a
--     third group inside the defensive container, which is what keeps the row gap-free.

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

env.loadModule("src/Modules/Alerts/Sound.lua")
env.loadModule("src/Modules/Alerts/Display.lua")
env.loadModule("src/Modules/Alerts/Module.lua")
local module = env.addon.Modules.AlertsModule
module:Init()
-- Init only builds the lifecycle. A module sets itself up on the first refresh that finds it
-- enabled, which in the addon is the one PLAYER_ENTERING_WORLD drives.
module:Refresh()

local events = assert(acm.lastFrameForEvent("PVP_MATCH_STATE_CHANGED"), "alerts event frame")

-- The two movable bars are the only frames the module makes draggable, in creation order:
-- the main bar first, then the dedicated important bar.
local mainBar, importantBar
for _, frame in ipairs(acm.frames) do
	if frame._scripts and frame._scripts.OnDragStop then
		if not mainBar then
			mainBar = frame
		elseif not importantBar then
			importantBar = frame
		end
	end
end
assert(mainBar and importantBar, "both alert bars are draggable anchors")

-- A bar sitting at x 300..500, y 400..430. Its centre is (400, 415).
local RECT = { left = 300, bottom = 400, width = 200, height = 30 }
local function placeMainBar()
	mainBar:SetMockRect(RECT.left, RECT.bottom, RECT.width, RECT.height)
end

-- The defensive container carries three groups (big, external, important). The dedicated
-- important container carries one.
-- A pair's two containers are built one after the other, Def then Imp, so the live pair for a
-- token is the last two carrying it. Counting groups does not tell them apart, because each
-- container is built with only the groups the current mode renders on it.
local function pairOf(token)
	local containers = env.containersForUnit(token)

	return containers[#containers - 1], containers[#containers]
end

local function defOf(token)
	return (pairOf(token))
end

local function impOf(token)
	local _, imp = pairOf(token)

	return imp
end

local function addEnemyPlate(token)
	env.enemies[token] = true
	env.addPlate(token)
	events:TriggerEvent("NAME_PLATE_UNIT_ADDED", token)
end

local function removePlate(token)
	events:TriggerEvent("NAME_PLATE_UNIT_REMOVED", token)
	env.plates[token] = nil
	env.enemies[token] = nil
end

fw.describe("Alerts 12.1 - bar anchor handling", function()
	fw.it("a refresh applies the saved anchor verbatim and never rewrites it", function()
		-- Converting the anchor from the frame's rect on a refresh caused two reset bugs in a
		-- row: the rect only matches the rendered row while test icons are up, so outside test
		-- mode the conversion measured stale or empty geometry into freshly restored options
		-- (first resurrecting the dragged position, then shifting the bar half a row across).
		placeMainBar()
		alerts.Grow = "CENTER"
		local shippedX, shippedY = alerts.Offset.X, alerts.Offset.Y
		module:Refresh()

		assert(alerts.Point == "CENTER" and alerts.RelativePoint == "TOP",
			"the shipped anchor survives a refresh untouched, got " .. tostring(alerts.Point))
		assert(alerts.Offset.X == shippedX and alerts.Offset.Y == shippedY, "offsets untouched")
	end)

	fw.it("flipping Grow leaves the saved anchor alone", function()
		-- The anchor pins the bar frame, not the row: growth direction only changes which way
		-- the rendered row extends, so there is nothing to rewrite.
		placeMainBar()
		local shippedX = alerts.Offset.X
		alerts.Grow = "LEFT"
		module:Refresh()

		assert(alerts.Point == "CENTER" and alerts.Offset.X == shippedX, "no rewrite on a Grow change")
		alerts.Grow = "CENTER"
	end)

	fw.it("a reset outside test mode places the bar at the restored anchor", function()
		-- A dragged anchor, then a reset to defaults while the bar is not rendering: the rect
		-- still shows the dragged position, and the restored values must win anyway.
		placeMainBar()
		alerts.Point = "LEFT"
		alerts.RelativePoint = "BOTTOMLEFT"
		alerts.RelativeTo = "UIParent"
		alerts.Offset.X = RECT.left
		alerts.Offset.Y = 415
		module:Refresh()

		alerts.Point = "CENTER"
		alerts.RelativePoint = "TOP"
		alerts.Offset.X = 0
		alerts.Offset.Y = -145
		module:Refresh()

		local point, _, relativePoint, x, y = mainBar:GetPoint(1)
		assert(point == "CENTER" and relativePoint == "TOP" and x == 0 and y == -145,
			"placed at the restored default, got " .. tostring(point) ..
			" " .. tostring(x) .. "," .. tostring(y))
		assert(alerts.Point == "CENTER" and alerts.Offset.X == 0 and alerts.Offset.Y == -145,
			"and the restored options were not measured over")
	end)

	fw.it("does not re-save on later refreshes", function()
		-- Re-saving on a refresh would let a transient layout (or a bar the user is mid-drag
		-- on) become the stored position.
		placeMainBar()
		module:Refresh()
		local savedX = alerts.Offset.X

		mainBar:SetMockRect(900, 100, RECT.width, RECT.height)
		module:Refresh()

		assert(alerts.Offset.X == savedX, "a refresh must leave the saved anchor alone")
	end)

	fw.it("a drag saves the dropped position normalized to the grow edge", function()
		placeMainBar()
		alerts.Grow = "RIGHT"
		module:Refresh()

		-- Land the drag somewhere with a different anchor point than the grow edge wants.
		mainBar:ClearAllPoints()
		mainBar:SetPoint("CENTER", _G.UIParent, "TOP", 12, -34)
		mainBar._scripts.OnDragStop(mainBar)

		assert(alerts.Point == "LEFT", "the dropped anchor is re-pinned to the grow edge")
		assert(alerts.RelativePoint == "BOTTOMLEFT" and alerts.RelativeTo == "UIParent", "against the screen")
		assert(alerts.Offset.X == RECT.left and alerts.Offset.Y == 415, "offsets describe where it was dropped")
	end)

	fw.it("a drag that already matches the grow edge keeps its own offsets", function()
		placeMainBar()
		alerts.Grow = "RIGHT"
		module:Refresh()

		mainBar:ClearAllPoints()
		mainBar:SetPoint("LEFT", _G.UIParent, "BOTTOMLEFT", 111, 222)
		mainBar._scripts.OnDragStop(mainBar)

		assert(alerts.Offset.X == 111 and alerts.Offset.Y == 222,
			"no rewrite needed, so the dragged offsets stand")
	end)

	fw.it("split mode places the defensives bar from its own anchor", function()
		placeMainBar()
		alerts.SplitBars = true
		module:Refresh()

		local point, _, _, x = mainBar:GetPoint(1)
		assert(point == alerts.Defensives.Point and x == alerts.Defensives.Offset.X,
			"split places from the Defensives anchor, got " .. tostring(x))

		alerts.SplitBars = false
		module:Refresh()
		local _, _, _, combinedX = mainBar:GetPoint(1)
		assert(combinedX == alerts.Offset.X, "combined returns to the module anchor")
	end)

	fw.it("a drag in split mode saves to the defensives anchor", function()
		placeMainBar()
		alerts.SplitBars = true
		module:Refresh()

		local combinedX = alerts.Offset.X
		mainBar:ClearAllPoints()
		mainBar:SetPoint("LEFT", _G.UIParent, "BOTTOMLEFT", 111, 222)
		mainBar._scripts.OnDragStop(mainBar)

		assert(alerts.Defensives.Offset.X == 111 and alerts.Defensives.Offset.Y == 222,
			"the drop lands on the Defensives anchor")
		assert(alerts.Offset.X == combinedX, "the combined anchor is untouched")

		alerts.SplitBars = false
		module:Refresh()
	end)
end)

fw.describe("Alerts 12.1 - how many pairs it prepares", function()
	local display = env.addon.Modules.Alerts.Display
	local moduleUtil = env.addon.Utils.ModuleUtil

	---@param instanceType string
	local function inPlace(instanceType, perSide)
		env.instanceType = instanceType
		env.inInstance = instanceType ~= "none"
		env.maxPlayers = perSide or 0
		moduleUtil:InvalidateWorldState()
	end

	fw.it("prepares what the place itself holds", function()
		-- A pair is frames, and the client never takes a frame back, so preparing forty of them
		-- for a place that holds three enemies is a set nothing can ever ask for.
		inPlace("arena")
		assert(display:PrewarmTokenTarget() == display.ArenaPrewarmTokenCount, "three in an arena")

		-- A battleground says how many a side holds, and that is how many enemies can have a
		-- plate up at once.
		inPlace("pvp", 10)
		assert(display:PrewarmTokenTarget() == 10, "one per enemy in a ten-a-side battleground")

		inPlace("pvp", 40)
		assert(display:PrewarmTokenTarget() == 40, "and forty in a forty-a-side one")

		-- Capped: the client hands out no more plate tokens than this however big the side is.
		inPlace("pvp", 500)
		assert(display:PrewarmTokenTarget() == display.MaxPrewarmTokenCount, "capped at the plate ceiling")

		-- Anywhere but a battleground the number counts the players the place fits, which says
		-- nothing about how many enemies are in front of you.
		inPlace("raid", 30)
		assert(display:PrewarmTokenTarget() == display.PrewarmTokenCount, "a raid's size is not an enemy count")

		inPlace("none")
		assert(display:PrewarmTokenTarget() == display.PrewarmTokenCount, "and outdoors, where world pvp happens")
	end)
end)

fw.describe("Alerts 12.1 - which plates get a pair", function()
	fw.it("builds nothing for an NPC", function()
		-- An alert is something another player did, and a busy zone is mostly NPCs. Each one tracked
		-- would hold a live aura container and a set of sound registrations for as long as its plate
		-- is up.
		env.npcs["nameplate5"] = true

		addEnemyPlate("nameplate5")

		assert(#env.containersForUnit("nameplate5") == 0, "no pair for a unit that cannot cast at you")

		removePlate("nameplate5")
		env.npcs["nameplate5"] = nil
	end)

	fw.it("drops the pair a token had when it comes back as an NPC", function()
		-- Plate tokens are recycled, so the enemy player on nameplate6 can be a boar a moment
		-- later. The pair it was holding has to go back rather than sit there enabled.
		addEnemyPlate("nameplate6")
		assert(#env.containersForUnit("nameplate6") == 2, "precondition: a player got a pair")

		removePlate("nameplate6")
		env.npcs["nameplate6"] = true
		addEnemyPlate("nameplate6")

		local def = defOf("nameplate6")

		assert(not def._enabled and not def:IsShown(), "the pair it held is parked")

		removePlate("nameplate6")
		env.npcs["nameplate6"] = nil
	end)
end)

fw.describe("Alerts 12.1 - prep room gating", function()
	fw.it("the prep room hides and disables every display pair", function()
		addEnemyPlate("nameplate1")
		local containers = env.containersForUnit("nameplate1")
		assert(#containers == 2, "pair acquired, got " .. #containers)
		-- Combined mode parks the dedicated important container, so only the defensive one is
		-- live here. The prep room still has to hide both.
		local def = defOf("nameplate1")
		assert(def._enabled and def:IsShown(), "precondition: live")

		env.matchState = _G.Enum.PvPMatchState.StartUp
		events:TriggerEvent("PVP_MATCH_STATE_CHANGED")

		for _, container in ipairs(containers) do
			assert(not container._enabled and not container:IsShown(), "hidden while in the prep room")
		end
	end)

	fw.it("a plate that spawns during the prep room stays hidden", function()
		addEnemyPlate("nameplate2")
		local containers = env.containersForUnit("nameplate2")
		assert(#containers == 2, "pair still acquired")
		for _, container in ipairs(containers) do
			assert(not container:IsShown(), "a new plate must not slip past the gate")
		end
	end)

	fw.it("the match starting brings every display back", function()
		-- Nothing else re-shows these: the aura containers have no events of ours to piggyback on,
		-- so a missed refresh here means no alerts for the rest of the match.
		env.matchState = 99
		events:TriggerEvent("PVP_MATCH_STATE_CHANGED")

		local restored = defOf("nameplate1")
		assert(restored._enabled and restored:IsShown(), "restored when the match starts")
		assert(defOf("nameplate2"):IsShown(), "including the plate that spawned during the prep room")
	end)
end)

fw.describe("Alerts 12.1 - split vs combined bars", function()
	---Resolves a two-frame row into (start, follower). The chain runs in token order now, so
	---nameplate1 starts the row, but the shape is what these tests are about: one frame at the
	---bar, one chained off it.
	local function chainPair(frameA, frameB, bar)
		local _, relativeToA = frameA:GetPoint(1)

		if relativeToA == bar then
			return frameA, frameB
		end

		return frameB, frameA
	end

	fw.it("combined mode draws the importants inside the defensive container", function()
		alerts.SplitBars = false
		module:Refresh()

		local def1, def2 = defOf("nameplate1"), defOf("nameplate2")
		assert(def1 and def2, "both plates tracked")

		-- The engine reserves each container's full icon budget of width, so a second container for
		-- one unit leaves a gap in the row.
		assert(def1._groups.important.maxFrameCount > 0, "the defensive container carries them")
		assert(not impOf("nameplate1"):IsShown(), "the dedicated important container is parked")
		assert(not importantBar:IsShown(), "no dedicated bar in combined mode")

		local first, second = chainPair(def1, def2, mainBar)
		local _, firstRelativeTo = first:GetPoint(1)
		local _, secondRelativeTo = second:GetPoint(1)
		assert(firstRelativeTo == mainBar and secondRelativeTo == first,
			"the row is one frame per unit: one starts at the bar, the other chains off it")
	end)

	fw.it("split mode starts the importants on their own bar", function()
		alerts.SplitBars = true
		module:Refresh()

		local firstImp, secondImp = chainPair(impOf("nameplate1"), impOf("nameplate2"), importantBar)
		local point, relativeTo, relativePoint = firstImp:GetPoint(1)
		assert(relativeTo == importantBar, "the important row starts at the important bar")
		assert(point == "LEFT" and relativePoint == "LEFT", "pinned to the bar's growth edge")

		local _, secondRelativeTo = secondImp:GetPoint(1)
		assert(secondRelativeTo == firstImp, "the other important chains off it")

		local firstDef, secondDef = chainPair(defOf("nameplate1"), defOf("nameplate2"), mainBar)
		local _, defRelativeTo = secondDef:GetPoint(1)
		assert(defRelativeTo == firstDef, "the defensive row is unaffected")
		assert(importantBar:IsShown(), "the dedicated bar is visible in split mode")
		assert(defOf("nameplate1")._groups.important == nil,
			"the defensive container is not built with them, so they can't be drawn twice")
	end)

	fw.it("switching back to combined moves the importants into the defensive container", function()
		alerts.SplitBars = false
		module:Refresh()

		assert(defOf("nameplate1")._groups.important.maxFrameCount > 0, "budget moves back")
		assert(not impOf("nameplate1"):IsShown(), "and the dedicated container is parked again")
		assert(not importantBar:IsShown(), "and the dedicated bar goes away again")
	end)

	fw.it("disabling importants drops the group from both containers", function()
		alerts.Important.Enabled = false
		module:Refresh()

		local def = defOf("nameplate1")
		assert(def._groups.important == nil, "the defensive container drops the group")
		assert(impOf("nameplate1")._groups.important == nil, "and so does the dedicated one")
		assert(def._enabled and def:IsShown(), "the defensive container stays live for its own auras")

		-- Re-enabling rebuilds the pairs, so the group comes back on a new container rather than
		-- on the one just looked at.
		alerts.Important.Enabled = true
		module:Refresh()
		assert(defOf("nameplate1")._groups.important.maxFrameCount > 0, "re-enabled")

		removePlate("nameplate1")
		removePlate("nameplate2")
	end)
end)

-- The border is the whole point of the category tints once the glow is off, because the two are
-- coloured from the same pick, so switching the glow off must not take the colouring with it.
--
-- Class colouring is off throughout, since it replaces the category tints outright and these are
-- the tests that pin the category path. TestAlertsClassColors covers the other one.
fw.describe("Alerts 12.1 - the border and the glow", function()
	local display = env.addon.Modules.Alerts.Display

	alerts.Icons.ClassColors = false

	---The border textures on the main bar's used slots, and the glow keys beside them.
	local function previewLook()
		local borders, glows = 0, 0
		local bar = display:GetContainer()

		for index = 1, bar.Count do
			local slot = bar.Slots[index]
			local layer = slot and slot.IsUsed and slot.Container

			if layer then
				if layer.Border and layer.Border._shown then
					borders = borders + 1
				end
				if layer.Frame._GlowColorKey then
					glows = glows + 1
				end
			end
		end

		return borders, glows
	end

	local function previewWith(glow, border)
		module:StopTesting()
		alerts.Icons.Glow = glow
		alerts.Icons.Border = border
		module:StartTesting()

		local borders, glows = previewLook()
		module:StopTesting()

		return borders, glows
	end

	fw.it("rings the preview icons while the border is on", function()
		local borders, glows = previewWith(false, true)

		assert(borders > 0, "the icons are ringed with the glow off")
		assert(glows == 0, "and nothing glows")
	end)

	fw.it("gives way to the glow when both are on", function()
		local borders, glows = previewWith(true, true)

		assert(glows > 0, "the glow draws")
		assert(borders == 0, "and the ring stands down rather than doubling up")
	end)

	fw.it("leaves the icons bare with both off", function()
		local borders, glows = previewWith(false, false)

		assert(borders == 0 and glows == 0, "nothing to colour")
	end)

	fw.it("trims the preview's icon corners under a border", function()
		previewWith(false, true)
		alerts.Icons.Glow = false
		alerts.Icons.Border = true
		module:StartTesting()

		local bar = display:GetContainer()
		local rounded, square = 0, 0

		for index = 1, bar.Count do
			local slot = bar.Slots[index]
			local layer = slot and slot.IsUsed and slot.Container

			if layer then
				if layer.CornersRounded then
					rounded = rounded + 1
				else
					square = square + 1
				end
			end
		end

		module:StopTesting()
		assert(rounded > 0 and square == 0, "every ringed icon is trimmed, got " .. rounded .. "/" .. square)
	end)

	fw.it("keeps the category tints on the border", function()
		previewWith(false, true)
		alerts.Icons.Glow = false
		alerts.Icons.Border = true
		module:StartTesting()

		local bar = display:GetContainer()
		local defensive = { 0.2, 1, 0.2 }
		local found = false

		for index = 1, bar.Count do
			local slot = bar.Slots[index]
			local border = slot and slot.IsUsed and slot.Container and slot.Container.Border
			local color = border and border._shown and border._lastArgs.SetVertexColor

			if color and color[1] == defensive[1] and color[2] == defensive[2] and color[3] == defensive[3] then
				found = true
			end
		end

		module:StopTesting()
		assert(found, "the defensive tint is what the ring is drawn in")
	end)
end)

-- The live buttons take the same pair of switches. A button can only be styled when it is created,
-- so moving either has to rebuild the pooled pairs. The ring itself is drawn by the addon here,
-- because the engine only owns a border it was handed for dispel colouring.
fw.describe("Alerts 12.1 - the border on the live bars", function()
	local BORDER_ASSET = [[Interface\Buttons\UI-Debuff-Overlays]]

	---The first defensive button on a token's live pair.
	local function buttonOf(token)
		local container
		for _, candidate in ipairs(env.containersForUnit(token)) do
			if env.groupCount(candidate) == 3 then
				container = candidate
			end
		end

		return container and container:GetAuraGroupFrame("bigdef", 1)
	end

	---A button's textures are picked by their art rather than by position: the icon is a created
	---texture too, and it is the one carrying no asset of its own.
	local function textureOf(button, isBorder)
		for _, texture in ipairs(button and button._createdTextures or {}) do
			local asset = texture._lastArgs.SetTexture
			local border = asset ~= nil and asset[1] == BORDER_ASSET

			if border == isBorder then
				return texture
			end
		end
	end

	local function borderOf(token)
		return textureOf(buttonOf(token), true)
	end

	local function borderWith(border)
		alerts.Icons.Glow = false
		alerts.Icons.Border = border
		module:Refresh()
		addEnemyPlate("nameplate4")

		local texture = borderOf("nameplate4")
		removePlate("nameplate4")

		return texture
	end

	fw.it("draws the ring in the category tint with the glow off", function()
		local texture = assert(borderWith(true), "the button has a border texture")
		local color = texture._lastArgs.SetVertexColor

		assert(texture._shown, "the ring is on screen")
		assert(color and color[1] == 0.2 and color[2] == 1 and color[3] == 0.2,
			"drawn in the defensive tint")
	end)

	-- The ring art has rounded inner corners, so a square icon under it leaves its own corners
	-- poking out past the ring. The glow already trimmed them. The border has to as well.
	fw.it("trims the icon corners the way the glow does", function()
		alerts.Icons.Glow = false
		alerts.Icons.Border = true
		module:Refresh()
		addEnemyPlate("nameplate5")

		local icon = assert(textureOf(buttonOf("nameplate5"), false), "the button has an icon")
		assert((icon._calls.AddMaskTexture or 0) > 0, "the corner mask is on the icon")

		removePlate("nameplate5")
	end)

	fw.it("leaves the live ring to the glow when both are on", function()
		alerts.Icons.Glow = true
		alerts.Icons.Border = true
		module:Refresh()
		addEnemyPlate("nameplate6")

		local border = assert(borderOf("nameplate6"), "the button has a border texture")
		assert(not border._shown, "the glow is the only ring")

		removePlate("nameplate6")
	end)

	fw.it("hides it again when the switch goes off", function()
		local texture = assert(borderWith(false), "the button still has one")

		assert(not texture._shown, "nothing rings the icon")
	end)
end)

-- Budgets and tints are applied to the existing pairs at runtime, so only what is genuinely
-- baked into the buttons (size, style) may rebuild them: every rebuild abandons the prewarmed
-- frame set for good, and frames can never be freed.
fw.describe("Alerts 12.1 - what may rebuild the display pairs", function()
	---The live Def container for a token. Earlier rebuilds leave abandoned containers still tagged
	---with the token, so the enabled one is asked, which is always the current pair's.
	local function liveDefOf(token)
		local found
		for _, container in ipairs(env.containersForUnit(token)) do
			if env.groupCount(container) == 3 and container._enabled then
				found = container
			end
		end
		return found
	end

	fw.it("a MaxIcons change re-budgets the live pairs without rebuilding them", function()
		module:Refresh()
		addEnemyPlate("nameplate1")

		local before = env.auraContainerCount()
		local oldMax = alerts.Icons.MaxIcons or 8
		alerts.Icons.MaxIcons = oldMax - 1
		module:Refresh()

		assert(env.auraContainerCount() == before, "no container was rebuilt")
		assert(liveDefOf("nameplate1")._groups.important.maxFrameCount == oldMax - 1,
			"the new budget landed on the existing pair")

		alerts.Icons.MaxIcons = oldMax
		module:Refresh()
	end)

	fw.it("a tint change leaves the pairs alone too", function()
		alerts.Icons.Border = true
		module:Refresh()

		local before = env.auraContainerCount()
		alerts.Icons.ImportantColor = { R = 0.1, G = 0.2, B = 0.9 }
		module:Refresh()

		assert(env.auraContainerCount() == before, "a picker change must not burn a frame set")

		alerts.Icons.ImportantColor = nil
		alerts.Icons.Border = false
		module:Refresh()
	end)

	fw.it("switches a parked pair back on without re-pushing what it already wears", function()
		-- A plate leaving parks its pair, and the configuration it was given is still on it. Only
		-- the enable and the show have to be undone, so the token coming back must not pay for a
		-- whole options push, and must not come back dark either.
		module:Refresh()
		addEnemyPlate("nameplate1")

		local before = env.auraContainerCount()
		-- The live one, since earlier rebuilds leave abandoned containers wearing the same token.
		local def = liveDefOf("nameplate1")

		assert(def, "the plate has a live pair to begin with")

		removePlate("nameplate1")
		assert(not def._enabled, "parking switches the pair off")

		addEnemyPlate("nameplate1")

		assert(env.auraContainerCount() == before, "the same pair came back, not a new one")
		assert(def._enabled, "and it is live again")
		assert(def:IsShown(), "and on screen")
	end)

	fw.it("an icon size change restyles the pairs instead of rebuilding them", function()
		-- Buttons take their size when they are created, but a restyle can re-fit them wherever
		-- the client allows one, and out of combat it does. Rebuilding would abandon every prewarmed
		-- pair for good, once per step of a slider drag.
		local before = env.auraContainerCount()
		local oldSize = alerts.Icons.Size
		local newSize = (oldSize or 24) + 2

		alerts.Icons.Size = newSize
		module:Refresh()

		assert(env.auraContainerCount() == before, "no frame set was abandoned")
		assert(liveDefOf("nameplate1")._groups.important.layout.elementWidth == newSize,
			"and the live pair wears the new size")

		alerts.Icons.Size = oldSize
		module:Refresh()
	end)

	fw.it("leaves the hidden pairs alone while test mode is drawing the preview", function()
		-- Test mode hides every pair and draws its own icons, so re-fitting the pairs while it runs
		-- is work nobody can see. What matters is that they are settled on the way out.
		local oldSize = alerts.Icons.Size
		local newSize = (oldSize or 24) + 6

		module:StartTesting()
		alerts.Icons.Size = newSize
		module:Refresh()

		local def = liveDefOf("nameplate1")

		assert(not def or def._groups.important.layout.elementWidth ~= newSize,
			"nothing was re-fitted while the preview was up")

		module:StopTesting()
		module:Refresh()

		assert(liveDefOf("nameplate1")._groups.important.layout.elementWidth == newSize,
			"and the new size lands once test mode ends")

		alerts.Icons.Size = oldSize
		module:Refresh()
	end)

	fw.it("rebuilds when the client will not let a restyle land", function()
		-- Inside an arena the restriction never clears, so a pair left holding the old size would
		-- wear it for the whole match. New buttons take their size as they are made, which is the
		-- only way through.
		local before = env.auraContainerCount()
		local oldSize = alerts.Icons.Size

		_G.InCombatLockdown = function()
			return true
		end
		alerts.Icons.Size = (oldSize or 24) + 4
		module:Refresh()
		_G.InCombatLockdown = function()
			return false
		end

		assert(env.auraContainerCount() > before, "the pairs were rebuilt at the new size")

		alerts.Icons.Size = oldSize
		module:Refresh()
		removePlate("nameplate1")
	end)
end)
