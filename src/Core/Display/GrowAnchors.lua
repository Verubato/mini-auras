---@type string, Addon
local _, addon = ...

-- Single source of truth for the "Grow" option (LEFT/RIGHT/CENTER/UP/DOWN) -> anchor geometry.
-- The same mapping used to be written out three different ways (if/elseif chains in the unit
-- frame modules, a GrowToAnchor helper in the nameplates module, and three lookup tables in the
-- aura display wrapper), which made it easy for one of them to drift.
--
-- Three related mappings live here:
--   Anchor - which point of the icon row is pinned to which point of its anchor frame. Also the
--            edge to pin when a row grows from a saved position (the alerts bars).
--   Chain  - how to continue a row after a preceding frame (the kick icon, or the previous
--            unit's container in the chained 12.1 rows). XMul/YMul turn a spacing value into
--            the offset for that direction.
--   Flow   - 12.1 AuraContainer flow layout settings, so the first icon sits nearest the
--            container's anchored edge like the legacy layouts.

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
}

---@type table<string, { Point: string, RelativePoint: string, XMul: number, YMul: number }>
M.Chain = {
	LEFT = { Point = "RIGHT", RelativePoint = "LEFT", XMul = -1, YMul = 0 },
	RIGHT = { Point = "LEFT", RelativePoint = "RIGHT", XMul = 1, YMul = 0 },
	-- CENTER can't be centred without a readable row width (12.1 container sizes can be
	-- secret), so it chains rightwards like RIGHT.
	CENTER = { Point = "LEFT", RelativePoint = "RIGHT", XMul = 1, YMul = 0 },
	DOWN = { Point = "TOP", RelativePoint = "BOTTOM", XMul = 0, YMul = -1 },
	UP = { Point = "BOTTOM", RelativePoint = "TOP", XMul = 0, YMul = 1 },
}

---@type table<string, { Axis: string, AnchorPoint: string, Horizontal: string, Vertical: string }>
M.Flow = {
	LEFT = { Axis = "Horizontal", AnchorPoint = "RIGHT", Horizontal = "Left", Vertical = "Down" },
	RIGHT = { Axis = "Horizontal", AnchorPoint = "LEFT", Horizontal = "Right", Vertical = "Down" },
	CENTER = { Axis = "Horizontal", AnchorPoint = "LEFT", Horizontal = "Right", Vertical = "Down" },
	DOWN = { Axis = "Vertical", AnchorPoint = "TOP", Horizontal = "Right", Vertical = "Down" },
	UP = { Axis = "Vertical", AnchorPoint = "BOTTOM", Horizontal = "Right", Vertical = "Up" },
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
---@return { Axis: string, AnchorPoint: string, Horizontal: string, Vertical: string }
function M:GetFlow(grow)
	return M.Flow[grow] or M.Flow[M.Default]
end
