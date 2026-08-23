---@type string, Addon
local _, addon = ...
local glowStyles = addon.Core.GlowStyles

-- What colour a 12.1 aura button's ring, glow and fill take, and which of those the engine paints
-- rather than the addon.
--
-- Split out of AuraContainerDisplay because the rule is subtle and self-contained: an aura's own
-- dispel type is unreadable here, so the border and glow textures are REGISTERED with the engine
-- and it tints them, while a group carrying its own category colour opts out and is painted
-- directly. Everything below is that one decision.

---@class AuraButtonPaint
local M = {}

addon.Core.AuraButtonPaint = M

---Applies a glow style's asset to a button's glow frame. Only re-skins when the style actually
---changed - this runs per button on every restyle.
---@param widgets table
---@param button table
---@param styleName string
---@param size number
function M:ApplyGlowStyle(widgets, button, styleName, size)
	local glow = widgets.Glow
	local spec = glowStyles.Specs[styleName]

	if widgets.GlowStyle ~= styleName then
		widgets.GlowStyle = styleName
		glowStyles:ApplySpec(glow, spec)
	end

	-- Re-anchoring invalidates the button's layout, and a restyle that changed neither the size nor
	-- the style leaves the glow exactly where it already sits.
	local padding = size * spec.PaddingFactor

	if widgets.GlowPadding ~= padding then
		widgets.GlowPadding = padding
		glow:SetPoint("TOPLEFT", button, "TOPLEFT", -padding, padding)
		glow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", padding, -padding)
	end
end

---Whether this button's glow shows at all. A group may carry its own answer, so one display can
---glow a single category and leave the rest plain; without one the display-wide switch stands.
---@param instance AuraContainerDisplay
---@param widgets table
---@return boolean
function M:GlowWanted(instance, widgets)
	local group = widgets.Group

	if group and group.Glow ~= nil then
		return group.Glow == true
	end

	return instance.Style.Glow == true
end

---The tint a button's border, glow and bar fill take. The group's own colour wins over the
---display-wide one: alerts colour by category, while a single-category display just takes the
---user's picked colour.
---The button holds its group rather than a copy of the colour, so SetGroupGlowColor can recolour
---a display that already exists - buttons can only be built once, and rebuilding one to change a
---tint is impossible while auras are secret.
---@param instance AuraContainerDisplay
---@param widgets table
---@return number?, number?, number?
function M:ButtonColor(instance, widgets)
	local style = instance.Style
	local group = widgets.Group
	local color = group and group.GlowColor

	if color then
		return color[1], color[2], color[3]
	end

	return style.GlowColorR, style.GlowColorG, style.GlowColorB
end

---Registers (or unregisters) the button's dispel-type textures. The engine tints registered
---textures by dispel type and drives their per-aura visibility (PreserveAsset style keeps our
---asset and only colours it). The border participates when ColorByDispelType is on; the glow's
---texture ALSO registers when the glow is enabled, which is how the glow inherits the border
---colour - the legacy paths tinted the glow with the aura's dispel colour, which is unreadable
---here, so the engine applies it instead. showWithoutDispelType keeps the glow visible for
---physical CC, tinted with the "None" palette colour like legacy.
---The border is a list rather than one texture because a bar's is built from four flat edges;
---an icon's is a single ring asset, so its list holds one.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
function M:ApplyDispelTextures(instance, button, widgets)
	local style = instance.Style
	local borders = widgets.BorderTextures
	local group = widgets.Group
	-- A group carrying its own tint opts out of dispel colouring: the engine's palette has nothing
	-- to say about a buff, so the categories the user picked a colour for (defensives, importants)
	-- keep that colour while CC still takes the dispel type's.
	local tinted = group ~= nil and group.GlowColor ~= nil
	local wantBorder = style.ColorByDispelType == true and borders ~= nil and not tinted
	-- Whether the border also shows on auras with NO dispel type (stuns, disarms), tinted with the
	-- "None" palette colour like the glow below. Opt-in per display: on a CC-only group every aura
	-- deserves the ring, but on a generic debuff display it would ring every physical debuff.
	local wantTypelessBorder = wantBorder and style.BorderWithoutDispelType == true
	local wantGlowTint = wantBorder and M:GlowWanted(instance, widgets) and widgets.Glow ~= nil
	-- A tinted group draws the border the dispel registration would have drawn, in its own colour,
	-- so switching the colours on never costs those icons their ring.
	local wantPlainBorder = style.Border == true or (tinted and style.ColorByDispelType == true)
	local colorR, colorG, colorB = M:ButtonColor(instance, widgets)

	-- Compared field by field rather than through a joined string: this runs per button on
	-- every restyle, and the retry ticker restyles every stale display once a second. The colour
	-- is part of it so a colour-only change still repaints.
	if wantBorder == widgets.DispelBorder
		and wantTypelessBorder == widgets.DispelTypelessBorder
		and wantGlowTint == widgets.DispelGlowTint
		and wantPlainBorder == widgets.DispelPlainBorder
		and colorR == widgets.DispelColorR
		and colorG == widgets.DispelColorG
		and colorB == widgets.DispelColorB then
		return
	end

	widgets.DispelBorder = wantBorder
	widgets.DispelTypelessBorder = wantTypelessBorder
	widgets.DispelGlowTint = wantGlowTint
	widgets.DispelPlainBorder = wantPlainBorder
	widgets.DispelColorR = colorR
	widgets.DispelColorG = colorG
	widgets.DispelColorB = colorB
	button:ClearDispelTypeTextures()

	if wantBorder then
		for _, texture in ipairs(borders) do
			button:AddDispelTypeTexture(texture, {
				style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
				showWhenHarmful = true,
				showWhenHelpful = true,
				showWithoutDispelType = wantTypelessBorder,
			})
		end
	elseif borders then
		-- Not registered for dispel colouring, so their visibility is ours to drive: draw the
		-- plain border only when the module asked for one, tinted with the same colour the glow
		-- would take.
		for _, texture in ipairs(borders) do
			if wantPlainBorder then
				texture:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)
				texture:Show()
			else
				texture:Hide()
			end
		end
	end

	if wantGlowTint then
		button:AddDispelTypeTexture(widgets.Glow.Texture, {
			style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
			showWhenHarmful = true,
			showWhenHelpful = true,
			showWithoutDispelType = true,
		})
	elseif widgets.Glow then
		-- Unregistered again: restore the glow's own colour and make sure the engine's
		-- last hidden state doesn't linger on the texture. GlowColor is the group's category
		-- tint (e.g. red importants, green defensives) and is nil unless the caller asked for
		-- one, in which case this is the plain white glow. Dispel colouring wins when both are
		-- on, since that branch hands the texture to the engine.
		widgets.Glow.Texture:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)
		widgets.Glow.Texture:Show()
	end
end
