local _, addon = ...
local M = addon.Framework
local GUI = M.GUI

-- Resolved on first gradient call. 2 = 10.0+ SetGradient(orientation, ColorMixin, ColorMixin),
-- 1 = pre-10.0 SetGradientAlpha(orientation, r,g,b,a, r,g,b,a), 0 = neither.
local gradientTier

-- Widgets here target every flavor the Mini addons ship to, down to Wrath-era clients. The
-- shims below cover the APIs the widget styling leans on that arrived after those clients.

-- Pixel-snapping helpers (PixelUtil arrived in 8.0). The fallback ignores snapping, which costs
-- a fraction of a pixel of crispness on 1px rules and is otherwise invisible. Deliberately not
-- assigned to the PixelUtil global: other addons feature-detect it, and 23 addons racing to
-- define it would be worse than the gap.
GUI.Pixel = PixelUtil
	or {
		SetWidth = function(region, width)
			region:SetWidth(width)
		end,
		SetHeight = function(region, height)
			region:SetHeight(height)
		end,
		SetSize = function(region, width, height)
			region:SetSize(width, height)
		end,
		SetPoint = function(region, ...)
			region:SetPoint(...)
		end,
	}

-- CreateFrame errors on an unknown template, and BackdropTemplate only exists from 9.0.
GUI.BackdropTemplate = BackdropTemplateMixin and "BackdropTemplate" or nil

---Solid fill. SetColorTexture arrived in 7.0; before that SetTexture took the color directly.
function GUI.SetSolid(texture, r, g, b, a)
	if texture.SetColorTexture then
		texture:SetColorTexture(r, g, b, a)
	else
		texture:SetTexture(r, g, b, a)
	end
end

---Disables pixel-grid snapping on a texture. A one-pixel line at a fractional offset (anything
---inside a scroll child, or anchored to text with a fractional width) can snap onto a
---zero-coverage row and vanish, or snap each edge differently and render unevenly. No-op on
---clients without the API.
function GUI.Unsnap(texture)
	if texture.SetSnapToPixelGrid then
		texture:SetSnapToPixelGrid(false)
		texture:SetTexelSnappingBias(0)
	end
end

---Applies a backdrop, silently doing nothing on clients without the Backdrop mixin.
---@return boolean applied
function GUI.ApplyBackdrop(frame, backdrop, r, g, b, a, br, bg, bb, ba)
	if not frame.SetBackdrop then
		return false
	end

	frame:SetBackdrop(backdrop)

	if r then
		frame:SetBackdropColor(r, g, b, a)
	end

	if br then
		frame:SetBackdropBorderColor(br, bg, bb, ba)
	end

	return true
end

---Detects gradient support by attempting the modern call. Capability detection isn't enough
---here: 9.x clients have both CreateColor and SetGradient, but SetGradient still takes eight
---numbers there, so only actually calling it distinguishes the two.
local function ResolveGradientTier(texture)
	if CreateColor and texture.SetGradient then
		local ok = pcall(texture.SetGradient, texture, "HORIZONTAL", CreateColor(1, 1, 1, 1), CreateColor(1, 1, 1, 1))

		if ok then
			return 2
		end
	end

	if texture.SetGradientAlpha then
		return 1
	end

	return 0
end

---Writes gradient vertex colors without touching the texture's image, so it also works on a
---shaped texture file (the toggle pill), not just a solid fill.
local function ApplyGradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
	if not gradientTier then
		gradientTier = ResolveGradientTier(texture)
	end

	if gradientTier == 2 then
		texture:SetGradient(orientation, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
	elseif gradientTier == 1 then
		texture:SetGradientAlpha(orientation, r1, g1, b1, a1, r2, g2, b2, a2)
	else
		-- No gradient support at all - average the two stops so the element stays visible.
		texture:SetVertexColor((r1 + r2) / 2, (g1 + g2) / 2, (b1 + b2) / 2, (a1 + a2) / 2)
	end
end

local function SetGradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
	GUI.SetSolid(texture, 1, 1, 1, 1)
	ApplyGradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
end

---Turns a texture into a horizontal gradient (first color left, second right).
function GUI.SetGradientH(texture, r1, g1, b1, a1, r2, g2, b2, a2)
	SetGradient(texture, "HORIZONTAL", r1, g1, b1, a1, r2, g2, b2, a2)
end

---Turns a texture into a vertical gradient (first color bottom, second top).
function GUI.SetGradientV(texture, r1, g1, b1, a1, r2, g2, b2, a2)
	SetGradient(texture, "VERTICAL", r1, g1, b1, a1, r2, g2, b2, a2)
end

---Tints a texture's existing image with a horizontal gradient, keeping the image's shape.
function GUI.TintGradientH(texture, r1, g1, b1, a1, r2, g2, b2, a2)
	ApplyGradient(texture, "HORIZONTAL", r1, g1, b1, a1, r2, g2, b2, a2)
end

---Returns the label font string of a UICheckButtonTemplate. Retail exposes .Text, older
---clients expose .text or only the global `<name>Text`.
---@return table? fontString
function GUI.GetCheckboxLabel(checkbox)
	if checkbox.Text then
		return checkbox.Text
	end

	if checkbox.text then
		checkbox.Text = checkbox.text
		return checkbox.text
	end

	local name = checkbox.GetName and checkbox:GetName()
	local fontString = name and _G[name .. "Text"]

	if fontString then
		checkbox.Text = fontString
	end

	return fontString
end

---Shows or hides a frame. SetShown arrived in 5.0.
function GUI.SetShown(frame, shown)
	if frame.SetShown then
		frame:SetShown(shown)
	elseif shown then
		frame:Show()
	else
		frame:Hide()
	end
end

---Calls a method only when the client actually has it.
function GUI.TryCall(frame, method, ...)
	local fn = frame[method]

	if not fn then
		return false
	end

	fn(frame, ...)

	return true
end
