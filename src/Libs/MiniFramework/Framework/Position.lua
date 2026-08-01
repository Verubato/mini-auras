local _, addon = ...
local M = addon.Framework

-- Saved position shape: { Point, RelativeTo, RelativePoint, X, Y }. RelativeTo is a frame NAME,
-- never a frame - saved variables are serialized to a Lua file, so a frame stored there is lost
-- at best and corrupts the file at worst.

---Reads a frame's current anchor into the position table.
---@param frame table
---@param position table saved-variable table to write into
function M:SavePosition(frame, position)
	if not frame or not position then
		error("SavePosition - frame and position must not be nil.")
	end

	local point, relativeTo, relativePoint, x, y = frame:GetPoint(1)

	if not point then
		return
	end

	position.Point = point
	position.RelativePoint = relativePoint
	position.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
	position.X = x
	position.Y = y
end

---Anchors a frame from a saved position, falling back to defaults for any missing field.
---@param frame table
---@param position table
---@param defaults table? used for any field the position table doesn't have
function M:ApplyPosition(frame, position, defaults)
	if not frame or not position then
		error("ApplyPosition - frame and position must not be nil.")
	end

	defaults = defaults or {}

	local point = position.Point or defaults.Point or "CENTER"
	local relativePoint = position.RelativePoint or defaults.RelativePoint or point
	local name = position.RelativeTo or defaults.RelativeTo
	local x = tonumber(position.X) or tonumber(defaults.X) or 0
	local y = tonumber(position.Y) or tonumber(defaults.Y) or 0

	-- A saved anchor can name a frame that no longer exists (another addon disabled, or an
	-- older layout); UIParent keeps the frame on screen instead of erroring.
	local relativeTo = (type(name) == "string" and _G[name]) or UIParent

	frame:ClearAllPoints()
	frame:SetPoint(point, relativeTo, relativePoint, x, y)
end

---Applies the locked state: a locked frame can't be dragged and ignores the mouse entirely.
function M:SetPositionLocked(frame, locked)
	if not frame then
		error("SetPositionLocked - frame must not be nil.")
	end

	frame:SetMovable(not locked)
	frame:EnableMouse(not locked)
end

---Makes a frame drag-to-move, persisting where it lands.
---@param frame table
---@param position table saved-variable table, written on drag stop
---@param options MovableOptions?
function M:MakeMovable(frame, position, options)
	if not frame or not position then
		error("MakeMovable - frame and position must not be nil.")
	end

	options = options or {}

	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(options.Clamped ~= false)
	frame:RegisterForDrag(options.DragButton or "LeftButton")

	-- Blizzard's own layout manager otherwise restores its remembered position on load and
	-- fights the saved one.
	if frame.SetDontSavePosition then
		frame:SetDontSavePosition(true)
	end

	frame:SetScript("OnDragStart", function(frameSelf)
		if options.IsLocked and options.IsLocked() then
			return
		end

		frameSelf:StartMoving()
	end)

	frame:SetScript("OnDragStop", function(frameSelf)
		frameSelf:StopMovingOrSizing()
		M:SavePosition(frameSelf, position)

		if options.OnMoved then
			options.OnMoved()
		end
	end)

	if options.IsLocked then
		M:SetPositionLocked(frame, options.IsLocked())
	end
end

---@class MovableOptions
---@field IsLocked fun(): boolean? consulted on every drag, so a lock toggle needs no rewiring
---@field OnMoved fun()? runs after the position is saved
---@field Clamped boolean? keep the frame on screen, default true
---@field DragButton string? default "LeftButton"
