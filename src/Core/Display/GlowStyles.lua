---@type string, Addon
local addonName, addon = ...

-- The texture-based glow catalog shared by both icon backends: AuraContainerDisplay styles the
-- 12.1 AuraButtons from it, and IconSlotContainer draws the same overlays on kick and test
-- icons, so both ways of rendering an icon glow identically and a new style is one entry here.
--
-- Only texture overlays belong in the catalog. LibCustomGlow cannot attach to AuraButtons (it
-- re-parents pooled frames onto its target, and 12.1 disallows SetParent onto AuraButtons), so
-- anything the 12.1 path cannot draw is left out.
--
-- Spec fields:
--   Texture/Atlas - the asset; exactly one is set.
--   BlendMode     - texture blend mode.
--   Desaturated   - strip the asset's own colour so tints apply uniformly.
--   PaddingFactor - how far the overlay extends past the icon, as a multiple of its size.
--   Animated      - the style runs the looping flipbook. A REPEAT animation costs CPU every
--                   frame even on hidden frames, so consumers only Play() when this is set.
--   Rows/Columns/Frames/Duration - flipbook geometry, required when Animated is set. Each sheet
--                   carries its own, since the layouts differ from one asset to the next.

-- Every overlay in the catalog has rounded inner corners, so an icon showing one is masked to the
-- same shape. A square icon's corners otherwise poke out past the glow, and so does its swipe.
local ICON_CORNER_MASK = "Interface\\AddOns\\" .. addonName .. "\\Textures\\IconCornerMask.tga"

-- The swipe ignores masks, so its shape comes from its own art. A flat block is the square case:
-- set explicitly rather than left at the client's default, so squaring an icon back up lands on
-- the same texture it started with.
local SQUARE_SWIPE_TEXTURE = "Interface\\Buttons\\WHITE8X8"

---@class GlowStyles
local M = {}

addon.Core.GlowStyles = M

-- Keys are user-facing db.GlowType values; renaming one orphans saved configs.
M.Specs = {
	["Rotation Assist (Anti-clockwise)"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Glows\\FlipbookWhiteAntiClockwise.tga",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 1 / 3,
		Animated = true,
		Rows = 6,
		Columns = 5,
		Frames = 30,
		Duration = 1.0,
	},
	["Rotation Assist (Clockwise)"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Glows\\FlipbookWhiteClockwise.tga",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 1 / 3,
		Animated = true,
		Rows = 6,
		Columns = 5,
		Frames = 30,
		Duration = 1.0,
	},
	-- Atlas rather than a bundled file: this one ships with the client.
	["Ants (Anti-Clockwise)"] = {
		Atlas = "RotationHelper_Ants_Flipbook",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 1 / 3,
		Animated = true,
		Rows = 6,
		Columns = 5,
		Frames = 30,
		Duration = 1.0,
	},
	-- The next three keep their own colours, so they are not desaturated and the tint a caller
	-- passes has no effect on them.
	["Twins"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Glows\\Twins.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 7,
		Animated = true,
		Rows = 6,
		Columns = 4,
		Frames = 24,
		Duration = 0.6,
	},
	["Mirror"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Glows\\Mirror.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 7,
		Animated = true,
		Rows = 12,
		Columns = 4,
		Frames = 48,
		Duration = 0.8,
	},
	["Twins Mirror"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Glows\\TwinMirror.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 7,
		Animated = true,
		Rows = 12,
		Columns = 4,
		Frames = 48,
		Duration = 1.8,
	},
	-- The halo needs to extend well past the icon edges to read correctly, hence the larger
	-- padding share.
	["Slot Glow"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Glows\\SlotGlow.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 5,
		Animated = false,
	},
	["Static Pixel Border"] = {
		Atlas = "wowlabs-spell-icon-frame-highlight",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 0.15,
		Animated = false,
	},
}

M.DefaultName = "Slot Glow"

---Builds an unskinned glow overlay: a child frame carrying an OVERLAY texture and a stopped
---flipbook animation. The animation exists even for static styles so a later switch to an
---animated one never has to touch the frame again - which matters on AuraButtons, where
---children cannot be modified while auras are secret. Skin it with ApplySpec; the caller owns
---positioning, visibility and starting the animation.
---@param parent table
---@param name string? Global frame name.
---@return table glowFrame Carries .Texture and .Anim.
function M:BuildGlowFrame(parent, name)
	local glow = CreateFrame("Frame", name, parent)
	glow:SetFrameLevel(parent:GetFrameLevel() + 5)

	glow.Texture = glow:CreateTexture(nil, "OVERLAY")
	glow.Texture:SetAllPoints()

	glow.Anim = glow:CreateAnimationGroup()
	glow.Anim:SetLooping("REPEAT")

	-- A single cell until ApplySpec fills in the chosen sheet's geometry, so the animation is never
	-- left unconfigured.
	local flip = glow.Anim:CreateAnimation("FlipBook")
	flip:SetChildKey("Texture")
	flip:SetFlipBookRows(1)
	flip:SetFlipBookColumns(1)
	flip:SetFlipBookFrames(1)
	flip:SetDuration(1.0)
	glow.FlipAnim = flip

	return glow
end

---Skins a glow frame with a spec's asset. Leaves the looping animation stopped; the caller
---decides whether it should run (see the Animated spec field).
---@param glowFrame table A frame from BuildGlowFrame.
---@param spec table An entry of M.Specs.
function M:ApplySpec(glowFrame, spec)
	-- Stop before re-skinning: the flipbook drives tex coords, so a running animation would
	-- fight the reset below (and Stop may restore its own pre-animation coords).
	glowFrame.Anim:Stop()

	if spec.Atlas then
		glowFrame.Texture:SetAtlas(spec.Atlas)
	else
		glowFrame.Texture:SetTexture(spec.Texture)
	end
	glowFrame.Texture:SetBlendMode(spec.BlendMode)
	glowFrame.Texture:SetDesaturated(spec.Desaturated)
	-- Read back by resize handlers that re-pad an already-built overlay.
	glowFrame.PaddingFactor = spec.PaddingFactor

	if spec.Animated then
		glowFrame.FlipAnim:SetFlipBookRows(spec.Rows)
		glowFrame.FlipAnim:SetFlipBookColumns(spec.Columns)
		glowFrame.FlipAnim:SetFlipBookFrames(spec.Frames)
		glowFrame.FlipAnim:SetDuration(spec.Duration)
	else
		-- The flipbook leaves the coords on its last cell; reset them so a static asset is not
		-- rendered as a crop of itself.
		glowFrame.Texture:SetTexCoord(0, 1, 0, 1)
	end
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
