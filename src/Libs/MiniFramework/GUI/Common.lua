local addonName, addon = ...
local M = addon.Framework
local GUI = M.GUI

-- Crop off the one-texel transparent margin the media textures keep against border bleed.
-- The field textures are 64x32, so the margin differs per axis; the icons are 32x32.
local PILL_CROP_X = 1 / 64
local PILL_CROP_Y = 1 / 32
local ICON_CROP = 1 / 32
-- Shape texels between the margins of every 64x32 field texture, used to scale slice caps.
local SHAPE_HEIGHT = 30
-- Cap widths in texels: a pill's round end is its full half, a soft corner just its radius.
local PILL_CAP = 15
local ROUNDED_CAP = 8

-- The only keys M:SetPalette will accept. GUI holds compat helpers too, so overriding by
-- truthiness alone would let a caller replace a function with a color table.
local PALETTE_KEYS = {
	Accent = true,
	AccentHi = true,
	TabTextIdle = true,
	TabTextHover = true,
	TabTextSelected = true,
	TabTextBright = true,
	DividerLine = true,
	DividerGold = true,
	TitleText = true,
}

-- Config-UI palette: one crimson accent plus warm neutrals. Plain
-- tables at file scope; ColorMixins are created lazily because CreateColor only exists in
-- the real client. Override with M:SetPalette to rebrand.
GUI.Accent = { r = 0.78, g = 0.20, b = 0.24 }
GUI.AccentHi = { r = 0.88, g = 0.29, b = 0.32 }
-- Idle/hover text for tab buttons (warm greys; selected is pure white). Horizontal sub-tabs
-- dim when idle; the vertical sidebar stays bright, with only the wash/bar marking selection.
GUI.TabTextIdle = { r = 0.73, g = 0.70, b = 0.66 }
GUI.TabTextHover = { r = 0.91, g = 0.89, b = 0.85 }
-- The selected tab, in every tab control. Gold rather than white so it reads as chosen at a
-- glance, next to a strip of near-white idle labels.
GUI.TabTextSelected = { r = 1, g = 0.82, b = 0 }
-- Hover for a vertical tab, which idles at TabTextHover already and so needs something brighter
-- again to respond to the mouse at all.
GUI.TabTextBright = { r = 1, g = 1, b = 1 }
-- Divider rules and label (muted gold - the one deliberate nod to the WoW default palette).
GUI.DividerLine = { r = 0.42, g = 0.35, b = 0.25 }
GUI.DividerGold = { r = 0.81, g = 0.66, b = 0.31 }
-- Standalone window title. Deliberately a touch brighter and less saturated than Accent.
GUI.TitleText = { r = 0.90, g = 0.20, b = 0.20 }

-- Shared chrome for the custom-drawn controls (toggle, slider, dropdown): dark fields, ivory
-- knobs, one hover treatment everywhere. Not part of the SetPalette surface.
GUI.FieldIdle = { r = 0.17, g = 0.15, b = 0.15 }
GUI.FieldHover = { r = 0.26, g = 0.23, b = 0.22 }
GUI.KnobIdle = { r = 0.91, g = 0.89, b = 0.85 }
GUI.KnobHover = { r = 1, g = 1, b = 1 }
GUI.LineIdle = { r = 0.30, g = 0.27, b = 0.26 }
GUI.LineHover = { r = 0.43, g = 0.40, b = 0.37 }
GUI.FillDisabled = { r = 0.40, g = 0.38, b = 0.36 }
GUI.DisabledAlpha = 0.3

-- White shapes tinted with vertex colors; the client can only draw rectangles itself. The
-- path assumes the prescribed embed location, Libs\MiniFramework inside the addon.
GUI.MediaPath = "Interface\\AddOns\\" .. addonName .. "\\Libs\\MiniFramework\\Media\\"
GUI.PillTexture = GUI.MediaPath .. "TogglePill.tga"
GUI.KnobTexture = GUI.MediaPath .. "ToggleKnob.tga"
GUI.ChevronTexture = GUI.MediaPath .. "Chevron.tga"
GUI.RoundedFieldTexture = GUI.MediaPath .. "RoundedField.tga"
GUI.RoundedBorderTexture = GUI.MediaPath .. "RoundedBorder.tga"

---Crops a media icon texture's transparent margin.
function GUI.CropIcon(texture)
	texture:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)
end

---Crops the pill texture's transparent margin, for drawing the whole pill on one texture.
function GUI.CropPill(texture)
	texture:SetTexCoord(PILL_CROP_X, 1 - PILL_CROP_X, PILL_CROP_Y, 1 - PILL_CROP_Y)
end

---Backs a frame with a 64x32 field texture in three slices - fixed-width shaped caps,
---stretched middle - so any width keeps its rounded ends undistorted. The slices are
---centered vertically at the given height, independent of the frame's own height.
---@return table field with SetColor(r, g, b, a)
local function ThreeSlice(frame, texture, height, capTexels, layer, sublayer)
	-- Uniform cap scale: the cap's texels drawn at the same scale the shape height gets.
	local capWidth = height * capTexels / SHAPE_HEIGHT
	local leftEdge = PILL_CROP_X + capTexels / 64
	local rightEdge = 1 - PILL_CROP_X - capTexels / 64

	local left = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sublayer)
	left:SetSize(capWidth, height)
	left:SetPoint("LEFT", frame, "LEFT", 0, 0)
	left:SetTexture(texture)
	left:SetTexCoord(PILL_CROP_X, leftEdge, PILL_CROP_Y, 1 - PILL_CROP_Y)

	local right = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sublayer)
	right:SetSize(capWidth, height)
	right:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
	right:SetTexture(texture)
	right:SetTexCoord(rightEdge, 1 - PILL_CROP_X, PILL_CROP_Y, 1 - PILL_CROP_Y)

	local middle = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sublayer)
	middle:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
	middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT", 0, 0)
	middle:SetTexture(texture)
	middle:SetTexCoord(leftEdge, rightEdge, PILL_CROP_Y, 1 - PILL_CROP_Y)

	local field = { Left = left, Middle = middle, Right = right }

	function field:SetColor(r, g, b, a)
		left:SetVertexColor(r, g, b, a)
		middle:SetVertexColor(r, g, b, a)
		right:SetVertexColor(r, g, b, a)
	end

	return field
end

---Backs a frame with the pill texture: full-capsule round ends.
---@return table field with SetColor(r, g, b, a)
function GUI.PillField(frame, height, layer, sublayer)
	return ThreeSlice(frame, GUI.PillTexture, height, PILL_CAP, layer, sublayer)
end

---Backs a frame with the soft-cornered field: a rounded-rect fill plus a 1px border ring in
---the same geometry, tinted independently through Fill and Border.
---@return table field with Fill and Border, each with SetColor(r, g, b, a)
function GUI.RoundedField(frame, height, layer)
	return {
		Fill = ThreeSlice(frame, GUI.RoundedFieldTexture, height, ROUNDED_CAP, layer, 0),
		Border = ThreeSlice(frame, GUI.RoundedBorderTexture, height, ROUNDED_CAP, layer, 1),
	}
end

---Whether a widget should draw the accented restyle rather than stock Blizzard art.
---A per-widget CustomStyling wins over the framework-wide default, including when false.
---@return boolean
function GUI.IsStyled(options)
	if options and options.CustomStyling ~= nil then
		return options.CustomStyling and true or false
	end

	return M.CustomStyling and true or false
end

---Refreshes any registered panels nested below a frame: sub-tab contents and section frames
---collect their own MiniControls, so a top-level MiniRefresh would otherwise stop at its own
---direct controls and leave nested sections stale (profile resets showed old values on tabbed
---panels). Frames that carry both MiniRefresh and MiniControls are panels and refresh
---themselves; plain controls carry only MiniRefresh and are covered by their panel's own list.
local function RefreshChildPanels(frame)
	for _, child in ipairs({ frame:GetChildren() }) do
		if child.MiniRefresh and child.MiniControls then
			child:MiniRefresh()
		else
			RefreshChildPanels(child)
		end
	end
end

function GUI.AddControlForRefresh(panel, control)
	-- store controls for refresh behaviour
	panel.MiniControls = panel.MiniControls or {}
	panel.MiniControls[#panel.MiniControls + 1] = control

	if panel.MiniRefresh then
		return
	end

	panel.MiniRefresh = function(panelSelf)
		for _, c in ipairs(panelSelf.MiniControls or {}) do
			if c.MiniRefresh then
				c:MiniRefresh()
			end
		end

		RefreshChildPanels(panelSelf)

		if panel.OnMiniRefresh then
			panel:OnMiniRefresh()
		end
	end
end

---Re-reads a page and every panel registered below it. A page built out of sub-tabs owns no
---controls itself, so it carries no MiniRefresh of its own.
---@param frame table?
function GUI.RefreshPanelTree(frame)
	if not frame then
		return
	end

	if frame.MiniRefresh then
		frame:MiniRefresh()

		return
	end

	RefreshChildPanels(frame)
end

function GUI.ConfigureNumericBox(box, allowNegative)
	if not allowNegative then
		box:SetNumeric(true)
		return
	end

	box:HookScript("OnTextChanged", function(boxSelf, userInput)
		if not userInput then
			return
		end

		local text = boxSelf:GetText()

		-- allow: "", "-", "-123", "123"
		if text == "" or text == "-" or text:match("^%-?%d+$") then
			return
		end

		-- strip invalid chars
		text = text:gsub("[^%d%-]", "")

		-- only one leading '-'
		text = text:gsub("%-+", "-")

		if text:sub(1, 1) ~= "-" then
			text = text:gsub("%-", "")
		else
			text = "-" .. text:sub(2):gsub("%-", "")
		end

		boxSelf:SetText(text)
	end)
end

---Turns the accented restyle on or off for every widget this addon creates.
---Call before building any widgets.
function M:SetCustomStyling(enabled)
	M.CustomStyling = enabled and true or false
end

---Overrides one or more palette colors so an addon can rebrand the config UI.
---Call before building any widgets.
---@param colors table<string, {r:number, g:number, b:number}>
function M:SetPalette(colors)
	if not colors then
		error("SetPalette - colors must not be nil.")
	end

	for key, color in pairs(colors) do
		-- An explicit whitelist, not `if GUI[key]`: GUI also holds the compat helpers, and a
		-- key collision would replace a function with a color table. A typo errors rather
		-- than silently doing nothing.
		if not PALETTE_KEYS[key] then
			error("SetPalette - unknown palette color: " .. tostring(key))
		end

		GUI[key] = { r = color.r, g = color.g, b = color.b }
	end
end
