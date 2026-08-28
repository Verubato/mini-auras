-- Alerts module, the CENTER grow direction. The row is partitioned around the bar's centre rather
-- than centred as a whole, because a display's width can be secret for a whole match.

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
-- Class colouring keys an arena pair by the opponent's class, so a token would move to a new pair
-- as soon as a test named a spec. Off here, since none of this is about colour.
alerts.Icons.ClassColors = false
-- An even number, so the half-spacing the seam uses is exact.
alerts.IconSpacing = 4

env.loadModule("src/Modules/Alerts/Sound.lua")
env.loadModule("src/Modules/Alerts/Display.lua")
env.loadModule("src/Modules/Alerts/Module.lua")
local display = env.addon.Modules.Alerts.Display
local module = env.addon.Modules.AlertsModule
module:Init()
module:Refresh()

local SPACING = alerts.IconSpacing
local SEAM = SPACING / 2

local events = assert(acm.lastFrameForEvent("PVP_MATCH_STATE_CHANGED"), "alerts event frame")

-- The two movable bars are the only frames the module makes draggable, in creation order: the main
-- bar first, then the dedicated important bar.
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

-- A pair's two containers are built Def then Imp, so the live pair for a token is the last two
-- carrying it.
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

local function enterArena(opponents)
	env.inInstance = true
	env.instanceType = "arena"
	env.arenaOpponents = opponents
	env.invalidateWorldState()
	env.loadWorld(module)
end

local function enterWorld()
	env.inInstance = false
	env.instanceType = "none"
	env.arenaOpponents = 0
	env.invalidateWorldState()
	env.loadWorld(module)
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

---The defensive frames of the given tokens.
local function rowOf(...)
	local frames = {}

	for _, token in ipairs({ ... }) do
		frames[#frames + 1] = assert(defOf(token), "no live display for " .. token)
	end

	return frames
end

---Asserts where one display sits. Named per token rather than matched on shape, so a row that came
---out in the wrong order fails on the unit that moved.
---@param frame table
---@param point string
---@param relativeTo table
---@param relativePoint string
---@param offsetX number
---@param what string
local function anchoredAt(frame, point, relativeTo, relativePoint, offsetX, what)
	assert(frame, what .. ": there is no live display")

	local p, target, rp, x = frame:GetPoint(1)
	local got = tostring(p) .. " -> " .. tostring(rp) .. " at " .. tostring(x)

	if target ~= relativeTo then
		got = got .. ", against a different frame"
	end

	assert(p == point and target == relativeTo and rp == relativePoint and x == offsetX,
		what .. ": expected " .. point .. " -> " .. relativePoint .. " at " .. offsetX
		.. ", got " .. got)

	return frame
end

---The one frame in `frames` whose first anchor matches, and an error when that is not exactly one.
local function only(frames, point, relativeTo, relativePoint, offsetX, what)
	local found

	for _, frame in ipairs(frames) do
		local p, target, rp, x = frame:GetPoint(1)

		if p == point and target == relativeTo and rp == relativePoint and x == offsetX then
			assert(not found, "more than one frame is " .. what)
			found = frame
		end
	end

	return assert(found, "no frame is " .. what)
end

---Which way a display fills, as the pair of flow settings the container was given.
local function flowOf(frame)
	return frame._flowAnchorPoint, frame._flowGrowth and frame._flowGrowth.h
end

fw.describe("Alerts - a centred row in the arena", function()
	fw.it("hangs arena1 and arena3 off the edges of arena2, which takes the centre", function()
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(3)

		local straddler = anchoredAt(defOf("arena2"), "CENTER", mainBar, "CENTER", 0, "arena2")

		anchoredAt(defOf("arena1"), "RIGHT", straddler, "LEFT", -SPACING, "arena1")
		anchoredAt(defOf("arena3"), "LEFT", straddler, "RIGHT", SPACING, "arena3")

		only(rowOf("arena1", "arena2", "arena3"), "CENTER", mainBar, "CENTER", 0,
			"the only unit on the bar's centre")
	end)

	fw.it("fills each half towards the centre", function()
		-- The halves mirror each other only if the left one fills leftwards, so its first icon sits
		-- nearest the middle.
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(3)

		local leftAnchor, leftGrowth = flowOf(defOf("arena1"))
		assert(leftAnchor == "RIGHT" and leftGrowth == _G.AnchorUtil.FlowDirection.Left,
			"arena1 fills leftwards, got " .. tostring(leftAnchor))

		local rightAnchor, rightGrowth = flowOf(defOf("arena3"))
		assert(rightAnchor == "LEFT" and rightGrowth == _G.AnchorUtil.FlowDirection.Right,
			"arena3 fills rightwards, got " .. tostring(rightAnchor))

		assert((flowOf(defOf("arena2"))) == "LEFT", "arena2 reads with the right half")
	end)

	fw.it("puts arena1 and arena2 either side of the seam when the count is even", function()
		-- No unit straddles, so the two inner displays meet on the centre itself.
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(2)

		anchoredAt(defOf("arena1"), "RIGHT", mainBar, "CENTER", -SEAM, "arena1")
		anchoredAt(defOf("arena2"), "LEFT", mainBar, "CENTER", SEAM, "arena2")

		for _, frame in ipairs(rowOf("arena1", "arena2")) do
			local point, target = frame:GetPoint(1)
			assert(not (point == "CENTER" and target == mainBar), "no unit takes the centre itself")
		end

		assert((flowOf(defOf("arena1"))) == "RIGHT", "arena1 still fills towards the centre")
		assert((flowOf(defOf("arena2"))) == "LEFT", "and arena2 away from it")
	end)

	fw.it("turns the new middle unit around when it was in the left half", function()
		-- An opponent behind a pillar leaves the tracked set, and the unit that takes the centre
		-- while they are gone was filling leftwards a moment earlier.
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(3)

		env.phased["arena1"] = true
		module:Refresh()

		assert((flowOf(defOf("arena2"))) == "RIGHT",
			"precondition: arena2 is in the left half and fills leftwards")

		env.phased["arena1"] = nil
		module:Refresh()

		anchoredAt(defOf("arena2"), "CENTER", mainBar, "CENTER", 0, "arena2 back on the centre")
		assert((flowOf(defOf("arena2"))) == "LEFT",
			"arena2 fills rightwards again as the middle unit")
	end)

	fw.it("gives a lone opponent the centre", function()
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(1)

		anchoredAt(defOf("arena1"), "CENTER", mainBar, "CENTER", 0, "the only opponent")
	end)
end)

fw.describe("Alerts - a centred row deeper than a half of one", function()
	-- Bound through the display rather than the module, because the module never binds more than
	-- the three tokens the client hands out. The partition itself has no such ceiling.
	local function bindTokens(...)
		local tokens = {}

		for _, token in ipairs({ ... }) do
			tokens[token] = true
		end

		display:SyncActiveTokens(tokens)
	end

	fw.it("chains each half outward from the one nearer the centre", function()
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(3)
		bindTokens("arena1", "arena2", "arena3", "arena4")

		local leftInner = anchoredAt(defOf("arena2"), "RIGHT", mainBar, "CENTER", -SEAM, "arena2")
		local rightInner = anchoredAt(defOf("arena3"), "LEFT", mainBar, "CENTER", SEAM, "arena3")

		anchoredAt(defOf("arena1"), "RIGHT", leftInner, "LEFT", -SPACING, "arena1")
		anchoredAt(defOf("arena4"), "LEFT", rightInner, "RIGHT", SPACING, "arena4")

		assert((flowOf(defOf("arena1"))) == "RIGHT", "the outer left unit fills towards the centre too")
	end)

	fw.it("re-partitions when the set grows to an odd count", function()
		-- The third opponent of an arena is sometimes only named part way in, so the row has to be
		-- able to move from a seam to a straddling unit without anything reading a size.
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(3)
		bindTokens("arena1", "arena2", "arena3", "arena4", "arena5")

		local straddler = anchoredAt(defOf("arena3"), "CENTER", mainBar, "CENTER", 0, "arena3")
		local leftInner = anchoredAt(defOf("arena2"), "RIGHT", straddler, "LEFT", -SPACING, "arena2")
		local rightInner = anchoredAt(defOf("arena4"), "LEFT", straddler, "RIGHT", SPACING, "arena4")

		anchoredAt(defOf("arena1"), "RIGHT", leftInner, "LEFT", -SPACING, "arena1")
		anchoredAt(defOf("arena5"), "LEFT", rightInner, "RIGHT", SPACING, "arena5")

		display:ReleaseAllDisplays()
	end)
end)

fw.describe("Alerts - the row order does not depend on how the tokens arrived", function()
	fw.it("puts arena2 on the centre even when the tokens are bound back to front", function()
		-- Lua places a string key by its hash, so the map's order has nothing to do with the order
		-- the tokens were bound in. Reversing it is one way to land on an order a sort must correct.
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(3)
		display:ReleaseAllDisplays()

		for _, token in ipairs({ "arena3", "arena1", "arena2" }) do
			display:ApplyOneAndChain(token)
		end

		local straddler = anchoredAt(defOf("arena2"), "CENTER", mainBar, "CENTER", 0, "arena2")

		anchoredAt(defOf("arena1"), "RIGHT", straddler, "LEFT", -SPACING, "arena1")
		anchoredAt(defOf("arena3"), "LEFT", straddler, "RIGHT", SPACING, "arena3")

		display:ReleaseAllDisplays()
	end)
end)

fw.describe("Alerts - a centred row in split mode", function()
	fw.it("gives a token the same place on both bars", function()
		-- A row that drew the wrong half of a pair would put a unit's defensives and its
		-- importants in different columns.
		alerts.Grow = "CENTER"
		alerts.SplitBars = true
		enterArena(3)

		local defStraddler = anchoredAt(defOf("arena2"), "CENTER", mainBar, "CENTER", 0,
			"arena2 on the defensive bar")

		anchoredAt(defOf("arena1"), "RIGHT", defStraddler, "LEFT", -SPACING, "arena1 on the defensive bar")
		anchoredAt(defOf("arena3"), "LEFT", defStraddler, "RIGHT", SPACING, "arena3 on the defensive bar")

		local impStraddler = anchoredAt(impOf("arena2"), "CENTER", importantBar, "CENTER", 0,
			"arena2 on the important bar")

		anchoredAt(impOf("arena1"), "RIGHT", impStraddler, "LEFT", -SPACING, "arena1 on the important bar")
		anchoredAt(impOf("arena3"), "LEFT", impStraddler, "RIGHT", SPACING, "arena3 on the important bar")
	end)
end)

fw.describe("Alerts - CENTER on the nameplate path", function()
	fw.it("keeps growing rightwards whatever the setting says", function()
		-- Plates come and go constantly, and a centred row would re-partition and shift the whole
		-- row across the screen on every one of them.
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterWorld()
		addEnemyPlate("nameplate1")
		addEnemyPlate("nameplate2")

		local first = anchoredAt(defOf("nameplate1"), "LEFT", mainBar, "LEFT", 0, "nameplate1")

		anchoredAt(defOf("nameplate2"), "LEFT", first, "RIGHT", SPACING, "nameplate2")

		for _, frame in ipairs(rowOf("nameplate1", "nameplate2")) do
			assert((flowOf(frame)) == "LEFT", "every plate display fills rightwards")
		end

		removePlate("nameplate1")
		removePlate("nameplate2")
	end)
end)

fw.describe("Alerts - pinning the bar under CENTER", function()
	-- A bar sitting at x 300..500, y 400..430, so its centre is (400, 415).
	local function placeBarAt(point, x, y)
		mainBar:SetMockRect(300, 400, 200, 30)
		mainBar:ClearAllPoints()
		mainBar:SetPoint(point, _G.UIParent, "BOTTOMLEFT", x, y)
	end

	fw.it("pins by the left edge while the fallback row is in play", function()
		-- An empty bar frame is one icon square rather than zero wide, so pinning by the centre
		-- while the row starts from the left edge puts the row half an icon off the saved spot.
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterWorld()
		placeBarAt("CENTER", 12, 34)
		mainBar._scripts.OnDragStop(mainBar)

		assert(alerts.Point == "LEFT", "pinned by the left edge, got " .. tostring(alerts.Point))
		assert(alerts.Offset.X == 300 and alerts.Offset.Y == 415, "at the frame's own left edge")
	end)

	fw.it("pins by the centre once the row really is centred", function()
		alerts.Grow = "CENTER"
		alerts.SplitBars = false
		enterArena(3)
		placeBarAt("LEFT", 111, 222)
		mainBar._scripts.OnDragStop(mainBar)

		assert(alerts.Point == "CENTER", "pinned by the centre, got " .. tostring(alerts.Point))
		assert(alerts.Offset.X == 400 and alerts.Offset.Y == 415, "at the frame's own centre")
	end)
end)
