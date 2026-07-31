local _, addon = ...
local M = addon.Core.Framework
local GUI = addon.Core.GUI

---@class DividerOptions
---@field Parent table
---@field Text string

---Creates a horizontal line with a label.
---@param options DividerOptions
---@return table
function M:Divider(options)
	if not options then
		error("Divider - options must not be nil.")
	end

	if not options.Parent then
		error("Divider - invalid options.")
	end

	local line = GUI.DividerLine
	local gold = GUI.DividerGold

	local container = CreateFrame("Frame", nil, options.Parent)
	container:SetHeight(26)

	-- Rules fade out toward the page edges instead of running edge to edge at constant grey.
	local leftLine = container:CreateTexture(nil, "ARTWORK")
	GUI.SetGradientH(leftLine, line.r, line.g, line.b, 0, line.r, line.g, line.b, 0.6)
	PixelUtil.SetHeight(leftLine, 1)

	local rightLine = container:CreateTexture(nil, "ARTWORK")
	GUI.SetGradientH(rightLine, line.r, line.g, line.b, 0.6, line.r, line.g, line.b, 0)
	PixelUtil.SetHeight(rightLine, 1)

	local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetText((options.Text or ""):upper())
	label:SetTextColor(gold.r, gold.g, gold.b, 1)
	label:SetPoint("CENTER", container, "CENTER")

	PixelUtil.SetPoint(leftLine, "LEFT", container, "LEFT", 0, 0)
	PixelUtil.SetPoint(leftLine, "RIGHT", label, "LEFT", -8, 0)

	PixelUtil.SetPoint(rightLine, "LEFT", label, "RIGHT", 8, 0)
	PixelUtil.SetPoint(rightLine, "RIGHT", container, "RIGHT", 0, 0)

	return container
end
