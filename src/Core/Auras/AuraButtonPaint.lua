---@type string, Addon
local _, addon = ...
local glowStyles = addon.Core.GlowStyles

-- What colour a 12.1 aura button's ring, glow and fill take, and which of those the engine paints
-- rather than the addon.

---@class AuraButtonPaint
local M = {}

addon.Core.AuraButtonPaint = M

---Applies a glow style's asset to a button's glow frame. Only re-skins when the style actually
---changed, since this runs per button on every restyle.
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

---Whether this button's glow shows at all. A group's own answer wins over the display-wide switch,
---so one display can glow a single category and leave the rest plain.
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

---Whether this button's border takes the engine's dispel palette. A group's own answer wins over
---the display-wide switch, so a row can colour the crowd control leading it and leave the plain
---debuffs behind it alone.
---@param instance AuraContainerDisplay
---@param widgets table
---@return boolean
function M:DispelColorWanted(instance, widgets)
	local group = widgets.Group

	if group and group.ColorByDispelType ~= nil then
		return group.ColorByDispelType == true
	end

	return instance.Style.ColorByDispelType == true
end

---The tint a button's border, glow and bar fill take. The group's own colour wins over the
---display-wide one, so alerts can colour by category.
---The button holds its group rather than a copy of the colour so SetGroupGlowColor can recolour a
---display that already exists. A button cannot be rebuilt while auras are secret.
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
---textures by dispel type and drives their per-aura visibility, and the PreserveAsset style leaves
---our asset alone so it only colours it.
---The border registers when ColorByDispelType is on, and the glow's texture registers with it so
---the glow inherits the border colour. The aura's own dispel colour cannot be read here, so only
---the engine can apply it.
---The border is a list because a bar's is built from four flat edges, while an icon's is a single
---ring asset.
---@param instance AuraContainerDisplay
---@param button table
---@param widgets table
function M:ApplyDispelTextures(instance, button, widgets)
	local style = instance.Style
	local borders = widgets.BorderTextures
	local group = widgets.Group
	-- A group carrying its own tint opts out of dispel colouring. The engine's palette has nothing
	-- to say about a buff, so the categories the user picked a colour for keep that colour while CC
	-- still takes the dispel type's.
	local tinted = group ~= nil and group.GlowColor ~= nil
	local colored = M:DispelColorWanted(instance, widgets)
	local wantBorder = colored and borders ~= nil and not tinted
	-- Whether the border also shows on auras with no dispel type, tinted with the "None" palette
	-- colour. It is opt-in per display because on a generic debuff display it would ring every
	-- physical debuff.
	local wantTypelessBorder = wantBorder and style.BorderWithoutDispelType == true
	local wantGlowTint = wantBorder and M:GlowWanted(instance, widgets) and widgets.Glow ~= nil
	-- A tinted group draws the border the dispel registration would have drawn, in its own colour,
	-- so switching the colours on never costs those icons their ring.
	local wantPlainBorder = style.Border == true or (tinted and colored)
	local colorR, colorG, colorB = M:ButtonColor(instance, widgets)

	-- This runs per button on every restyle, and the retry ticker restyles every stale display once
	-- a second. The colour is part of the check so a colour-only change still repaints.
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
		-- Not registered for dispel colouring, so their visibility is ours to drive.
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
		-- showWithoutDispelType keeps the glow on physical CC, tinted with the "None" palette colour.
		button:AddDispelTypeTexture(widgets.Glow.Texture, {
			style = Enum.CustomAuraButtonDispelTypeTextureStyle.PreserveAsset,
			showWhenHarmful = true,
			showWhenHelpful = true,
			showWithoutDispelType = true,
		})
	elseif widgets.Glow then
		-- Restore the glow's own colour, and show it so the engine's last hidden state cannot
		-- linger on the texture.
		widgets.Glow.Texture:SetVertexColor(colorR or 1, colorG or 1, colorB or 1, 1)
		widgets.Glow.Texture:Show()
	end
end
