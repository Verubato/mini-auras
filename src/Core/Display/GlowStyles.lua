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

---@class GlowStyles
local M = {}

addon.Core.GlowStyles = M

-- Keys are user-facing db.GlowType values; renaming one orphans saved configs.
M.Specs = {
	["Rotation Assist (Anti-clockwise)"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\FlipbookWhiteAntiClockwise.tga",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 1 / 4,
		Animated = true,
		Rows = 6,
		Columns = 5,
		Frames = 30,
		Duration = 1.0,
	},
	["Rotation Assist (Clockwise)"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\FlipbookWhiteClockwise.tga",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 1 / 4,
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
		PaddingFactor = 1 / 4,
		Animated = true,
		Rows = 6,
		Columns = 5,
		Frames = 30,
		Duration = 1.0,
	},
	-- The next three keep their own colours, so they are not desaturated and the tint a caller
	-- passes has no effect on them.
	["Twins"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Twins.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 8,
		Animated = true,
		Rows = 6,
		Columns = 4,
		Frames = 24,
		Duration = 0.6,
	},
	["Mirror"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\Mirror.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 8,
		Animated = true,
		Rows = 12,
		Columns = 4,
		Frames = 48,
		Duration = 0.8,
	},
	["Twins Mirror"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\TwinMirror.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 8,
		Animated = true,
		Rows = 12,
		Columns = 4,
		Frames = 48,
		Duration = 1.8,
	},
	-- The halo needs to extend well past the icon edges to read correctly, hence the larger
	-- padding share.
	["Slot Glow"] = {
		Texture = "Interface\\AddOns\\" .. addonName .. "\\Textures\\SlotGlow.tga",
		BlendMode = "BLEND",
		Desaturated = false,
		PaddingFactor = 1 / 5,
		Animated = false,
	},
	["Static Pixel Border"] = {
		Atlas = "wowlabs-spell-icon-frame-highlight",
		BlendMode = "BLEND",
		Desaturated = true,
		PaddingFactor = 0.1,
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
