---@type string, Addon
local _, addon = ...

-- A rectangular outline built from four flat edges, for the shapes the ring border asset cannot
-- cover. Stretching that asset across a bar distorts it badly, so the live and stand-in bars alike
-- draw their border, and their pandemic reveal, out of solid edges instead.
--
-- Handed back as a list so a caller can colour, show and hide the whole outline in one loop.

local SOLID_TEXTURE = "Interface\\Buttons\\WHITE8X8"

---@class Outline
local M = {}

addon.Core.Outline = M

---@param parent table Frame the edges are created on and anchored to.
---@param inset number How far outside the parent the outline sits.
---@param thickness number Edge thickness in pixels.
---@param drawLayer string? Defaults to OVERLAY.
---@return table[] edges
function M:Create(parent, inset, thickness, drawLayer)
	drawLayer = drawLayer or "OVERLAY"

	local top = parent:CreateTexture(nil, drawLayer)
	top:SetPoint("TOPLEFT", parent, "TOPLEFT", -inset, inset)
	top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", inset, inset)
	top:SetHeight(thickness)

	local bottom = parent:CreateTexture(nil, drawLayer)
	bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -inset, -inset)
	bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", inset, -inset)
	bottom:SetHeight(thickness)

	-- Spanning between the horizontal edges rather than the parent, so the four meet at the
	-- corners whatever the inset is.
	local left = parent:CreateTexture(nil, drawLayer)
	left:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, 0)
	left:SetPoint("BOTTOMLEFT", bottom, "TOPLEFT", 0, 0)
	left:SetWidth(thickness)

	local right = parent:CreateTexture(nil, drawLayer)
	right:SetPoint("TOPRIGHT", top, "BOTTOMRIGHT", 0, 0)
	right:SetPoint("BOTTOMRIGHT", bottom, "TOPRIGHT", 0, 0)
	right:SetWidth(thickness)

	local edges = { top, bottom, left, right }

	-- Hidden until something asks for them, like the icon border: an outline nobody turned on
	-- would otherwise frame every single aura.
	for _, texture in ipairs(edges) do
		texture:SetTexture(SOLID_TEXTURE)
		texture:Hide()
	end

	return edges
end

---Colours a whole outline and shows or hides it in one call.
---@param edges table[]
---@param shown boolean
---@param r number
---@param g number
---@param b number
function M:Apply(edges, shown, r, g, b)
	for _, texture in ipairs(edges) do
		texture:SetShown(shown)
		texture:SetAlpha(shown and 1 or 0)
		texture:SetVertexColor(r or 1, g or 1, b or 1, 1)
	end
end
