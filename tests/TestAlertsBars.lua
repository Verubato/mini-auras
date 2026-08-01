-- Alerts module, 12.1 container path: the parts of the bars that are geometry and gating rather
-- than aura data. Three areas, each a silent-failure class:
--
--   * The saved anchor is rewritten to the edge the row grows FROM whenever Grow changes, so the
--     bar never moves on screen when the user flips the direction.
--   * The prep room hides every display, and only the match-state event brings them back - a
--     mistake here means no alerts for the whole arena.
--   * Split mode gives importants their own bar and container; combined mode renders them as a
--     third group inside the defensive container, which is what keeps the row gap-free.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local alerts = db.Modules.AlertsModule

alerts.Enabled.Always = true
alerts.Icons.Enabled = true
alerts.SplitBars = false
alerts.Important.Enabled = true

env.loadModule("src/Modules/AlertsModule.lua")
local module = env.addon.Modules.AlertsModule
module:Init()

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

-- A bar sitting at x 300..500, y 400..430; its centre is (400, 415).
local RECT = { left = 300, bottom = 400, width = 200, height = 30 }
local function placeMainBar()
	mainBar:SetMockRect(RECT.left, RECT.bottom, RECT.width, RECT.height)
end

-- The defensive container carries three groups (big, external, important); the dedicated
-- important container carries one.
local function defOf(token)
	for _, container in ipairs(env.containersForUnit(token)) do
		if env.groupCount(container) == 3 then
			return container
		end
	end
end

local function impOf(token)
	for _, container in ipairs(env.containersForUnit(token)) do
		if env.groupCount(container) == 1 then
			return container
		end
	end
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

fw.describe("AlertsModule 12.1 - bar anchor normalization", function()
	fw.it("pins the edge the row grows from, taken from the bar's live position", function()
		-- Default Grow is CENTER, which behaves as RIGHT on 12.1: the row extends rightwards,
		-- so its LEFT edge is what has to stay put.
		placeMainBar()
		alerts.Grow = "CENTER"
		module:Refresh()

		assert(alerts.Point == "LEFT", "grow RIGHT pins the LEFT edge, got " .. tostring(alerts.Point))
		assert(alerts.RelativeTo == "UIParent" and alerts.RelativePoint == "BOTTOMLEFT",
			"re-anchored against the screen so the saved offsets are absolute")
		assert(alerts.Offset.X == RECT.left, "offset X is the live left edge, got " .. tostring(alerts.Offset.X))
		assert(alerts.Offset.Y == 415, "offset Y is the live vertical centre, got " .. tostring(alerts.Offset.Y))
	end)

	fw.it("flipping Grow re-pins the opposite edge without moving the bar", function()
		placeMainBar()
		alerts.Grow = "LEFT"
		module:Refresh()

		assert(alerts.Point == "RIGHT", "grow LEFT pins the RIGHT edge")
		-- Anchoring the bar's RIGHT edge at 500 leaves it exactly where it is now (300..500);
		-- taking the old LEFT offset would have shifted it a full bar width across the screen.
		assert(alerts.Offset.X == RECT.left + RECT.width, "offset X is the live right edge, got " .. tostring(alerts.Offset.X))
		assert(alerts.Offset.Y == 415, "vertical centre unchanged")
	end)

	fw.it("does not re-save on later refreshes with the same Grow", function()
		-- Normalization exists to survive a Grow change, not to track the frame: re-saving on
		-- every refresh would let a transient layout (or a bar the user is mid-drag on) become
		-- the stored position.
		placeMainBar()
		module:Refresh()
		local savedX = alerts.Offset.X

		mainBar:SetMockRect(900, 100, RECT.width, RECT.height)
		module:Refresh()

		assert(alerts.Offset.X == savedX, "an unchanged Grow must leave the saved anchor alone")
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
end)

fw.describe("AlertsModule 12.1 - prep room gating", function()
	fw.it("the prep room hides and disables every display pair", function()
		addEnemyPlate("nameplate1")
		local containers = env.containersForUnit("nameplate1")
		assert(#containers == 2, "pair acquired, got " .. #containers)
		-- Combined mode parks the dedicated important container, so only the defensive one is
		-- live here; the prep room still has to hide both.
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

fw.describe("AlertsModule 12.1 - split vs combined bars", function()
	fw.it("combined mode draws the importants inside the defensive container", function()
		alerts.SplitBars = false
		module:Refresh()

		local def1, def2 = defOf("nameplate1"), defOf("nameplate2")
		assert(def1 and def2, "both plates tracked")

		-- One container per unit holding every category is what removes the gap: separate
		-- containers are separate frames and the engine reserves each one's full icon budget.
		assert(def1._groups.important.maxFrameCount > 0, "the defensive container carries them")
		assert(not impOf("nameplate1"):IsShown(), "the dedicated important container is parked")
		assert(not importantBar:IsShown(), "no dedicated bar in combined mode")

		local _, relativeTo = def2:GetPoint(1)
		assert(relativeTo == def1, "the row is one frame per unit, chained in order")
	end)

	fw.it("split mode starts the importants on their own bar", function()
		alerts.SplitBars = true
		module:Refresh()

		local firstImp = impOf("nameplate1")
		local point, relativeTo, relativePoint = firstImp:GetPoint(1)
		assert(relativeTo == importantBar, "the important row starts at the important bar")
		assert(point == "LEFT" and relativePoint == "LEFT", "pinned to the bar's growth edge")

		local secondImp = impOf("nameplate2")
		local _, secondRelativeTo = secondImp:GetPoint(1)
		assert(secondRelativeTo == firstImp, "later importants chain off the previous important")

		local _, defRelativeTo = defOf("nameplate2"):GetPoint(1)
		assert(defRelativeTo == defOf("nameplate1"), "the defensive row is unaffected")
		assert(importantBar:IsShown(), "the dedicated bar is visible in split mode")
		assert(defOf("nameplate1")._groups.important.maxFrameCount == 0,
			"the defensive container drops them so they aren't drawn twice")
	end)

	fw.it("switching back to combined moves the importants into the defensive container", function()
		alerts.SplitBars = false
		module:Refresh()

		assert(defOf("nameplate1")._groups.important.maxFrameCount > 0, "budget moves back")
		assert(not impOf("nameplate1"):IsShown(), "and the dedicated container is parked again")
		assert(not importantBar:IsShown(), "and the dedicated bar goes away again")
	end)

	fw.it("disabling importants zeroes the budget on whichever container holds them", function()
		alerts.Important.Enabled = false
		module:Refresh()

		local def = defOf("nameplate1")
		assert(def._groups.important.maxFrameCount == 0, "budget zeroed")
		assert(impOf("nameplate1")._groups.important.maxFrameCount == 0, "on both containers")
		assert(def._enabled and def:IsShown(), "the defensive container stays live for its own auras")

		alerts.Important.Enabled = true
		module:Refresh()
		assert(def._groups.important.maxFrameCount > 0, "re-enabled")

		removePlate("nameplate1")
		removePlate("nameplate2")
	end)
end)
