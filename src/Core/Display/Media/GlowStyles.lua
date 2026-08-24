---@type string, Addon
local addonName, addon = ...

-- The texture-based glow catalog shared by both icon backends, so an icon glows the same whichever
-- one draws it and a new style is one entry here.

-- Every overlay in the catalog has rounded inner corners, so an icon showing one is masked to the
-- same shape. A square icon's corners otherwise poke out past the glow, and so does its swipe.
local ICON_CORNER_MASK = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Masks\\IconCornerMask.tga"

-- The swipe ignores masks, so its shape comes from its own art. A flat block is the square case:
-- set explicitly rather than left at the client's default, so squaring an icon back up lands on
-- the same texture it started with.
local SQUARE_SWIPE_TEXTURE = "Interface\\Buttons\\WHITE8X8"

---@class GlowStyles
local M = {}

addon.Core.GlowStyles = M

-- Texture overlays only. LibCustomGlow re-parents pooled frames onto its target and 12.1 disallows
-- SetParent onto AuraButtons, so anything the 12.1 path cannot draw is left out.
--
-- Every style is static, and no animated one may come back. A REPEAT animation is evaluated every
-- frame even on a hidden icon, the containers create buttons far beyond the auras actually showing,
-- and there is no way to gate an animation per icon: AuraButtons forbid untrusted scripts, their
-- shown state is secret, and the frame count reports frames created rather than active.
--
-- Keys are user-facing db.GlowType values, and renaming one orphans saved configs.
--
-- A spec sets:
--   Texture/Atlas - the asset, exactly one of the two.
--   BlendMode     - texture blend mode.
--   Desaturated   - strip the asset's own colour so tints apply uniformly.
--   PaddingFactor - how far the overlay extends past the icon, as a multiple of its size.
M.Specs = {
	-- The halo needs to extend well past the icon edges to read correctly, hence the larger
	-- padding share.
	["Slot Glow"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Glows\\SlotGlow.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 5,
	},
	-- Atlas rather than a bundled file: this one ships with the client.
	["Static Pixel Border"] = {
		Atlas = "wowlabs-spell-icon-frame-highlight",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 0.15,
	},
}

M.DefaultName = "Slot Glow"

---Builds an unskinned glow overlay: a child frame carrying an OVERLAY texture. Skin it with
---ApplySpec; the caller owns positioning and visibility.
---@param parent table
---@param name string? Global frame name.
---@return table glowFrame Carries .Texture.
function M:BuildGlowFrame(parent, name)
	local glow = CreateFrame("Frame", name, parent)
	glow:SetFrameLevel(parent:GetFrameLevel() + 5)

	glow.Texture = glow:CreateTexture(nil, "OVERLAY")
	glow.Texture:SetAllPoints()

	return glow
end

---Skins a glow frame with a spec's asset.
---@param glowFrame table A frame from BuildGlowFrame.
---@param spec table An entry of M.Specs.
function M:ApplySpec(glowFrame, spec)
	if spec.Atlas then
		glowFrame.Texture:SetAtlas(spec.Atlas)
	else
		glowFrame.Texture:SetTexture(spec.Texture)
	end
	glowFrame.Texture:SetBlendMode(spec.BlendMode)
	glowFrame.Texture:SetDesaturated(spec.Desaturated)
	-- Read back by resize handlers that re-pad an already-built overlay.
	glowFrame.PaddingFactor = spec.PaddingFactor
end

---Squares off a cooldown's swipe. Called when an icon is built, so both shapes come from us and
---the square one never depends on whatever the client defaults to.
---@param cooldown table
function M:SquareSwipe(cooldown)
	cooldown:SetSwipeTexture(SQUARE_SWIPE_TEXTURE)
end

---Cuts an icon's corners to the glow art's shape, or squares them back up. Only call on a change:
---adding the same mask twice stacks it.
---@param parent table Frame the mask texture is created on.
---@param icon table
---@param cooldown table? Takes the matching swipe art when present.
---@param mask table? The mask from an earlier call, held by the caller.
---@param rounded boolean
---@return table? mask To hand back next time.
function M:SetIconCorners(parent, icon, cooldown, mask, rounded)
	if rounded and not mask then
		mask = parent:CreateMaskTexture()
		-- Clamped rather than wrapped, so the icon outside the mask's rect is cut away instead of
		-- being smeared with the mask's edge pixels.
		mask:SetTexture(ICON_CORNER_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		mask:SetAllPoints(icon)
	end

	if not mask then
		return nil
	end

	if rounded then
		icon:AddMaskTexture(mask)
	else
		icon:RemoveMaskTexture(mask)
	end

	if cooldown then
		cooldown:SetSwipeTexture(rounded and ICON_CORNER_MASK or SQUARE_SWIPE_TEXTURE)
	end

	return mask
end
