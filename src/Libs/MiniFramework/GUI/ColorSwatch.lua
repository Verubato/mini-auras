local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L

local BORDER_COLOR = { r = 0.40, g = 0.40, b = 0.40 }
local DEFAULT_SIZE = 22
local DEFAULT_LABEL_GAP = 4

---Opens the colour picker.
---
---Alpha here is always alpha: 1 is opaque. The picker itself is inconsistent about that -
---the modern API's GetColorAlpha returns alpha, while the pre-Dragonflight fields called the
---same slot "opacity" and meant transparency - so both are normalised on the way in and out.
---@param r number
---@param g number
---@param b number
---@param a number
---@param onUpdate fun(r:number, g:number, b:number, a:number)
---@param onCancel fun(r:number, g:number, b:number, a:number)?
local function OpenColorPicker(r, g, b, a, onUpdate, onCancel)
	local prevR, prevG, prevB, prevA = r, g, b, a

	if ColorPickerFrame.SetupColorPickerAndShow then
		local function Changed()
			local newR, newG, newB = ColorPickerFrame:GetColorRGB()
			onUpdate(newR, newG, newB, ColorPickerFrame:GetColorAlpha())
		end

		ColorPickerFrame:SetupColorPickerAndShow({
			r = r,
			g = g,
			b = b,
			opacity = a,
			hasOpacity = true,
			swatchFunc = Changed,
			opacityFunc = Changed,
			cancelFunc = function()
				if onCancel then
					onCancel(prevR, prevG, prevB, prevA)
				end
			end,
		})

		return
	end

	-- Pre-Dragonflight: opacity is transparency, and the callbacks are plain fields.
	ColorPickerFrame.hasOpacity = true
	ColorPickerFrame.opacity = 1 - a
	ColorPickerFrame.previousValues = { r = r, g = g, b = b, opacity = 1 - a }

	local function Changed()
		local newR, newG, newB = ColorPickerFrame:GetColorRGB()
		onUpdate(newR, newG, newB, 1 - (ColorPickerFrame.opacity or 0))
	end

	ColorPickerFrame.func = Changed
	ColorPickerFrame.opacityFunc = Changed
	ColorPickerFrame.cancelFunc = function()
		if onCancel then
			onCancel(prevR, prevG, prevB, prevA)
		end
	end

	ColorPickerFrame:SetColorRGB(r, g, b)
	ColorPickerFrame:Hide()
	ColorPickerFrame:Show()
end

---Draws a 1px border out of four edge textures. A backdrop would need BackdropTemplate on a
---plain Button, and this stays crisp at any size.
local function DrawBorder(btn)
	local function Edge(pointA, pointB, width, height)
		local tex = btn:CreateTexture(nil, "BORDER")
		GUI.SetSolid(tex, BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b, 1)
		tex:SetPoint(pointA, btn, pointA, 0, 0)
		tex:SetPoint(pointB, btn, pointB, 0, 0)

		if width then
			tex:SetWidth(width)
		end

		if height then
			tex:SetHeight(height)
		end
	end

	Edge("TOPLEFT", "TOPRIGHT", nil, 1)
	Edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
	Edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
	Edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
end

---Creates a colour swatch button that opens the colour picker.
---GetValue/SetValue deal in r, g, b, a with alpha 1 meaning opaque; storage shape is the
---caller's business.
---@param options ColorSwatchOptions
---@return table swatch with a Label field when LabelText is set
function M:ColorSwatch(options)
	if not options then
		error("ColorSwatch - options must not be nil.")
	end

	if not options.Parent or not options.GetValue or not options.SetValue then
		error("ColorSwatch - invalid options.")
	end

	local size = options.Size or DEFAULT_SIZE
	local hasOpacity = options.HasOpacity ~= false

	local btn = CreateFrame("Button", nil, options.Parent)
	btn:SetSize(size, size)

	-- Placed here rather than left to the caller: an unanchored FontString never renders, so a
	-- LabelText that the caller did not also position was silently doing nothing. Sitting to the
	-- right of the swatch and vertically centred on it reads correctly beside a row of
	-- checkboxes, which is where these end up. A caller wanting it elsewhere clears the point
	-- and re-anchors btn.Label.
	local label
	if options.LabelText then
		label = options.Parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
		label:SetText(options.LabelText)
		label:SetPoint("LEFT", btn, "RIGHT", options.LabelGap or DEFAULT_LABEL_GAP, 0)
	end

	local fill = btn:CreateTexture(nil, "BACKGROUND")
	fill:SetPoint("TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", -1, 1)

	DrawBorder(btn)

	local function Refresh()
		local r, g, b = options.GetValue()
		GUI.SetSolid(fill, r or 1, g or 1, b or 1, 1)
	end

	local function Commit(r, g, b, a)
		options.SetValue(r, g, b, hasOpacity and a or 1)
		Refresh()

		if options.OnChange then
			options.OnChange()
		end
	end

	btn:SetScript("OnClick", function()
		local r, g, b, a = options.GetValue()
		OpenColorPicker(r or 1, g or 1, b or 1, a or 1, Commit, Commit)
	end)

	btn:SetScript("OnEnter", function(btnSelf)
		GameTooltip:SetOwner(btnSelf, "ANCHOR_RIGHT")
		GameTooltip:SetText(options.LabelText or L["Color"], 1, 0.82, 0)
		GameTooltip:AddLine(options.Tooltip or L["Click to change the color."], 1, 1, 1, true)
		GameTooltip:Show()
	end)

	btn:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	btn.Label = label
	btn.MiniRefresh = Refresh

	Refresh()
	GUI.AddControlForRefresh(options.Parent, btn)

	return btn
end

---@class ColorSwatchOptions
---@field Parent table
---@field LabelText string?
---@field Tooltip string?
---@field Size number? default 22
---@field HasOpacity boolean? default true; when false, alpha is forced to 1
---@field LabelGap number? pixels between the swatch and its label (default 4)
---@field GetValue fun(): number, number, number, number r, g, b, a
---@field SetValue fun(r: number, g: number, b: number, a: number)
---@field OnChange fun()? runs after SetValue, for applying the change live
