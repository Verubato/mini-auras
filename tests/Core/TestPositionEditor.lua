-- Typed placement: every draggable the addon arms in test mode also opens the position editor on
-- a plain click, and what the editor writes has to land exactly where a drop would have. The
-- three ways that goes wrong silently are a click that is really the end of a drag, a click on a
-- frame nobody armed (test mode off, so there is nothing to place), and a write that moves the
-- frame without saving it, or saves it without moving it.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local moduleUtil = env.addon.Utils.ModuleUtil

local opened = {}
local dropped = {}
local movableCount = 0

env.addon.Core.PositionEditor = {
	Toggle = function(_, binding)
		opened[#opened + 1] = binding
	end,
	OpenOrRefresh = function(_, binding)
		dropped[#dropped + 1] = binding
	end,
	Refresh = function() end,
	Close = function() end,
}

---@return table frame
---@return table options
local function NewMovable(onMoved)
	movableCount = movableCount + 1

	local frame = acm.NewFrame("Frame", "TestMovable" .. movableCount)
	local options = {
		Point = "CENTER",
		RelativePoint = "CENTER",
		RelativeTo = "UIParent",
		Offset = { X = 10, Y = 20 },
	}

	frame:SetPoint("CENTER", _G.UIParent, "CENTER", 10, 20)
	frame:SetMovable(true)
	moduleUtil:MakeMovable(frame, options, onMoved)

	return frame, options
end

local function Click(frame)
	frame._scripts.OnMouseDown(frame, "LeftButton")
	frame._scripts.OnMouseUp(frame, "LeftButton")
end

fw.describe("MakeMovable - the heading the editor opens under", function()
	fw.before_each(function()
		for i = #opened, 1, -1 do
			opened[i] = nil
		end

		env.db.ShowTestLabels = true
	end)

	fw.it("titles the editor with the caption the module put up", function()
		local frame = NewMovable()

		moduleUtil:SetTestLabel(frame, "Alerts")
		Click(frame)

		assert(opened[1] and opened[1].Title == "Alerts", "the editor names the frame it is placing")
	end)

	fw.it("keeps the heading once the captions are switched off", function()
		local frame = NewMovable()

		env.db.ShowTestLabels = false
		moduleUtil:SetTestLabel(frame, "Alerts")
		Click(frame)

		assert(opened[1] and opened[1].Title == "Alerts", "a setting about the screen left the editor alone")
	end)

	fw.it("drops the heading when the sweep takes the caption down", function()
		local frame = NewMovable()

		moduleUtil:SetTestLabel(frame, "Alerts")
		moduleUtil:HideAllTestLabels()
		Click(frame)

		assert(opened[1] and opened[1].Title == nil, "no stale name follows the caption down")
	end)
end)

fw.describe("MakeMovable - the position editor click", function()
	fw.before_each(function()
		for i = #opened, 1, -1 do
			opened[i] = nil
		end

		for i = #dropped, 1, -1 do
			dropped[i] = nil
		end
	end)

	fw.it("opens on a click, bound to the frame and where it sits", function()
		local frame = NewMovable()

		Click(frame)

		assert(#opened == 1, "one click opens the editor once, got " .. #opened)
		assert(opened[1].Key == frame, "and binds it to the frame that was clicked")

		local x, y = opened[1].Get()
		assert(x == 10 and y == 20, "reading the frame's own anchor, got " .. x .. "," .. y)
	end)

	fw.it("still steps one pixel when the saved anchor describes the spot differently", function()
		-- The bars re-pin their saved anchor to the edge the row grows from, in screen
		-- coordinates, and leave the frame on the anchor it already had. Reading the editor's
		-- numbers out of the saved table and writing them back to the frame's own point mixed the
		-- two spaces, and a one pixel nudge threw the bar across the screen.
		local frame, options = NewMovable()

		options.Point = "LEFT"
		options.RelativePoint = "BOTTOMLEFT"
		options.Offset.X = 760
		options.Offset.Y = 400

		Click(frame)

		local x, y = opened[1].Get()
		assert(x == 10 and y == 20, "the editor reads where the frame is, got " .. x .. "," .. y)

		opened[1].Set(x + 1, y)

		local _, _, _, liveX, liveY = frame:GetPoint(1)
		assert(liveX == 11 and liveY == 20, "a nudge moves one, got " .. liveX .. "," .. liveY)
	end)

	fw.it("does not toggle on the release that ends a drag", function()
		-- The drop opens the editor down its own path, so treating that release as a click too
		-- would open and shut it in the same drag.
		local frame = NewMovable()

		frame._scripts.OnMouseDown(frame, "LeftButton")
		frame._scripts.OnDragStart(frame)
		frame._scripts.OnDragStop(frame)
		frame._scripts.OnMouseUp(frame, "LeftButton")

		assert(#opened == 0, "a drop is not a click, opened " .. #opened)

		Click(frame)
		assert(#opened == 1, "and the click after it still opens, got " .. #opened)
	end)

	fw.it("opens on a drop, bound to the frame that landed", function()
		local frame = NewMovable()

		frame._scripts.OnMouseDown(frame, "LeftButton")
		frame._scripts.OnDragStart(frame)
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", _G.UIParent, "CENTER", 60, 70)
		frame._scripts.OnDragStop(frame)
		frame._scripts.OnMouseUp(frame, "LeftButton")

		assert(#dropped == 1, "the drop opens the editor once, got " .. #dropped)
		assert(dropped[1].Key == frame, "bound to the frame that was dragged")

		local x, y = dropped[1].Get()
		assert(x == 60 and y == 70, "showing where it landed, got " .. x .. "," .. y)
	end)

	fw.it("leaves a drop on an unarmed frame alone", function()
		-- Nothing arms a frame outside test mode, and a stray drag script firing there would
		-- pop the editor up over the game.
		local frame = NewMovable()
		frame:SetMovable(false)

		frame._scripts.OnMouseDown(frame, "LeftButton")
		frame._scripts.OnDragStop(frame)

		assert(#dropped == 0, "an unarmed drop opens nothing, got " .. #dropped)
	end)

	fw.it("stays shut while the frame is not armed for dragging", function()
		local frame = NewMovable()
		frame:SetMovable(false)

		Click(frame)

		assert(#opened == 0, "nothing is placeable outside test mode, opened " .. #opened)
	end)

	fw.it("moves the frame and saves the same numbers a drop would", function()
		local moved = 0
		local frame, options = NewMovable(function()
			moved = moved + 1
		end)

		Click(frame)
		opened[1].Set(-33, 44)

		local point, _, relativePoint, x, y = frame:GetPoint(1)
		assert(point == "CENTER" and relativePoint == "CENTER", "the anchor points are kept")
		assert(x == -33 and y == 44, "the frame moves to the typed offsets, got " .. x .. "," .. y)
		assert(options.Offset.X == -33 and options.Offset.Y == 44,
			"and they are saved, got " .. options.Offset.X .. "," .. options.Offset.Y)
		assert(options.Point == "CENTER" and options.RelativeTo == "UIParent", "with the anchor shape")
		assert(moved == 1, "the module's re-layout runs exactly once, ran " .. moved)
	end)

	fw.it("writes X/Y directly for a position table with no Offset sub-table", function()
		-- The personal aura groups' shape: the same editor drives both, and picking the wrong one
		-- would save a group's position into a key nothing reads back.
		local frame = acm.NewFrame("Frame", "TestMovableFlat")
		local position = { Point = "TOPLEFT", RelativePoint = "TOPLEFT", X = 1, Y = 2 }

		frame:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 1, 2)
		frame:SetMovable(true)
		moduleUtil:MakeMovable(frame, position)

		Click(frame)
		opened[1].Set(7, 8)

		assert(position.X == 7 and position.Y == 8,
			"the flat shape is written in place, got " .. position.X .. "," .. position.Y)
		assert(position.Offset == nil, "and no Offset sub-table is invented")
		assert(position.RelativeTo == nil, "nor a RelativeTo the table never carried")
	end)
end)
