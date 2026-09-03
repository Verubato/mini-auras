---@type string, Addon
local _, addon = ...

-- Single source of truth for the "Grow" option (LEFT/RIGHT/CENTER/UP/DOWN) -> anchor geometry.
--
-- Three related mappings live here:
--   Anchor - which point of the icon row is pinned to which point of its anchor frame. Also the
--            edge to pin when a row grows from a saved position (the alerts bars).
--   Chain  - how to continue a row after a preceding frame (the kick icon, or the previous
--            unit's container in the chained 12.1 rows). XMul/YMul turn a spacing value into
--            the offset for that direction.
--   Flow   - 12.1 AuraContainer flow layout settings, and the point the container hangs off.

---@class GrowAnchors
local M = {}

addon.Core.GrowAnchors = M

M.Default = "CENTER"

---@type table<string, { Point: string, RelativePoint: string }>
M.Anchor = {
	LEFT = { Point = "RIGHT", RelativePoint = "LEFT" },
	RIGHT = { Point = "LEFT", RelativePoint = "RIGHT" },
	CENTER = { Point = "CENTER", RelativePoint = "CENTER" },
	DOWN = { Point = "TOP", RelativePoint = "BOTTOM" },
	UP = { Point = "BOTTOM", RelativePoint = "TOP" },
	-- The two corner grows, for a row that wraps onto a second line rather than running on. Only
	-- a wrapping row has an opinion about which way the next line goes, so the plain LEFT and
	-- RIGHT above keep dropping downwards like every single-row display does.
	LEFT_UP = { Point = "BOTTOMRIGHT", RelativePoint = "BOTTOMRIGHT" },
	RIGHT_UP = { Point = "BOTTOMLEFT", RelativePoint = "BOTTOMLEFT" },
}

---@type table<string, { Point: string, RelativePoint: string, XMul: number, YMul: number }>
M.Chain = {
	LEFT = { Point = "RIGHT", RelativePoint = "LEFT", XMul = -1, YMul = 0 },
	RIGHT = { Point = "LEFT", RelativePoint = "RIGHT", XMul = 1, YMul = 0 },
	-- A row continuing after another frame has no centre of its own to work from, so CENTER
	-- chains rightwards like RIGHT.
	CENTER = { Point = "LEFT", RelativePoint = "RIGHT", XMul = 1, YMul = 0 },
	DOWN = { Point = "TOP", RelativePoint = "BOTTOM", XMul = 0, YMul = -1 },
	UP = { Point = "BOTTOM", RelativePoint = "TOP", XMul = 0, YMul = 1 },
	LEFT_UP = { Point = "RIGHT", RelativePoint = "LEFT", XMul = -1, YMul = 0 },
	RIGHT_UP = { Point = "LEFT", RelativePoint = "RIGHT", XMul = 1, YMul = 0 },
}

-- AnchorPoint is the corner a run starts from, so it names the edge each axis grows away from.
-- Pin hangs that box off the host.
---@type table<string, { Axis: string, AnchorPoint: string, Pin: string, Horizontal: string, Vertical: string }>
M.Flow = {
	LEFT = { Axis = "Horizontal", AnchorPoint = "TOPRIGHT", Pin = "TOPRIGHT", Horizontal = "Left", Vertical = "Down" },
	RIGHT = { Axis = "Horizontal", AnchorPoint = "TOPLEFT", Pin = "TOPLEFT", Horizontal = "Right", Vertical = "Down" },
	-- A centred row spreads both ways from the anchor, so it keeps a mid-edge pin.
	CENTER = { Axis = "Horizontal", AnchorPoint = "TOPLEFT", Pin = "TOP", Horizontal = "Right", Vertical = "Down" },
	DOWN = { Axis = "Vertical", AnchorPoint = "TOPLEFT", Pin = "TOP", Horizontal = "Right", Vertical = "Down" },
	UP = { Axis = "Vertical", AnchorPoint = "BOTTOMLEFT", Pin = "BOTTOM", Horizontal = "Right", Vertical = "Up" },
	-- The two corner grows, which stack a wrapped line upwards instead of down.
	LEFT_UP = { Axis = "Horizontal", AnchorPoint = "BOTTOMRIGHT", Pin = "BOTTOMRIGHT", Horizontal = "Left", Vertical = "Up" },
	RIGHT_UP = { Axis = "Horizontal", AnchorPoint = "BOTTOMLEFT", Pin = "BOTTOMLEFT", Horizontal = "Right", Vertical = "Up" },
}

---Anchor points for positioning a row against its anchor frame.
---@param grow string?
---@return string point, string relativePoint
function M:GetAnchor(grow)
	local entry = M.Anchor[grow] or M.Anchor[M.Default]
	return entry.Point, entry.RelativePoint
end

---The edge of a row that stays pinned as icons appear (i.e. the point a saved position anchors).
---@param grow string?
---@return string point
function M:GetPinPoint(grow)
	return (M.Anchor[grow] or M.Anchor[M.Default]).Point
end

---Rewrites a saved position so its anchor is the pinned edge for this grow direction, keeping the
---frame at its current on-screen spot. Rect values are in the frame's own scale, which is also the
---scale SetPoint offsets use, so no conversion is needed even for frames that ignore parent scale.
---Needs a real rect, so call this from a drag drop rather than a layout path, where a stale or
---unrendered rect corrupts the options.
---@param frame table
---@param options { Point: string, RelativeTo: string?, RelativePoint: string, Offset: { X: number, Y: number } }
---@param grow string?
---@return boolean rewritten True when the saved anchor was changed.
function M:PinSavedAnchor(frame, options, grow)
	local point = M:GetPinPoint(grow)

	if options.Point == point then
		return false
	end

	local x, y = frame:GetCenter()

	if point == "LEFT" then
		x = frame:GetLeft()
	elseif point == "RIGHT" then
		x = frame:GetRight()
	elseif point == "TOP" then
		y = frame:GetTop()
	elseif point == "BOTTOM" then
		y = frame:GetBottom()
	end

	if not x or not y then
		return false
	end

	options.Point = point
	options.RelativeTo = "UIParent"
	options.RelativePoint = "BOTTOMLEFT"
	options.Offset.X = x
	options.Offset.Y = y

	return true
end

---Anchor points and spacing offsets for continuing a row after `previous`.
---@param grow string?
---@param spacing number
---@return string point, string relativePoint, number offsetX, number offsetY
function M:GetChain(grow, spacing)
	local entry = M.Chain[grow] or M.Chain[M.Default]
	return entry.Point, entry.RelativePoint, entry.XMul * spacing, entry.YMul * spacing
end

---12.1 flow layout settings for a container.
---@param grow string?
---@return { Axis: string, AnchorPoint: string, Pin: string, Horizontal: string, Vertical: string }
function M:GetFlow(grow)
	return M.Flow[grow] or M.Flow[M.Default]
end

---The point of a 12.1 container to hang off its host's anchor point, so the first icon lands on
---that anchor and every line the row gains grows away from it.
---@param grow string?
---@return string point
function M:GetFlowPin(grow)
	return (M.Flow[grow] or M.Flow[M.Default]).Pin
end

---Whether a row runs leftwards from its anchored edge, so the first icon is the rightmost one.
---@param grow string?
---@return boolean
function M:FillsLeftward(grow)
	return M:GetFlow(grow).Horizontal == "Left"
end
