local _, addon = ...
local M = addon.Framework
local GUI = M.GUI

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

	local pixel = GUI.Pixel
	local line = GUI.DividerLine
	local gold = GUI.DividerGold

	local styled = GUI.IsStyled(options)

	local container = CreateFrame("Frame", nil, options.Parent)
	container:SetHeight(26)

	local leftLine = container:CreateTexture(nil, "ARTWORK")
	local rightLine = container:CreateTexture(nil, "ARTWORK")

	if styled then
		-- Rules fade out toward the page edges instead of running edge to edge at constant grey.
		GUI.SetGradientH(leftLine, line.r, line.g, line.b, 0, line.r, line.g, line.b, 0.6)
		GUI.SetGradientH(rightLine, line.r, line.g, line.b, 0.6, line.r, line.g, line.b, 0)
	else
		GUI.SetSolid(leftLine, line.r, line.g, line.b, 0.6)
		GUI.SetSolid(rightLine, line.r, line.g, line.b, 0.6)
	end

	pixel.SetHeight(leftLine, 1)
	pixel.SetHeight(rightLine, 1)

	local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetText((options.Text or ""):upper())

	if styled then
		label:SetTextColor(gold.r, gold.g, gold.b, 1)
	end

	label:SetPoint("CENTER", container, "CENTER")

	pixel.SetPoint(leftLine, "LEFT", container, "LEFT", 0, 0)
	pixel.SetPoint(leftLine, "RIGHT", label, "LEFT", -8, 0)

	pixel.SetPoint(rightLine, "LEFT", label, "RIGHT", 8, 0)
	pixel.SetPoint(rightLine, "RIGHT", container, "RIGHT", 0, 0)

	return container
end

---@class DividerOptions
---@field Parent table
---@field Text string
---@field CustomStyling boolean? Override the framework-wide styling default for this divider
