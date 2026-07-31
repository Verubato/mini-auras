local _, addon = ...
local M = addon.Core.Framework
local GUI = addon.Core.GUI

---@class EditboxOptions
---@field Parent table
---@field LabelText string
---@field Tooltip string?
---@field Numeric boolean?
---@field AllowNegatives boolean?
---@field Width number?
---@field Height number?
---@field GetValue fun(): string|number
---@field SetValue fun(value: string|number)

---@class EditBoxReturn
---@field EditBox table
---@field Label table

---Strips InputBoxTemplate's parchment inset art and draws a flat dark field in its place.
---(The template's art extends ~5px left of the frame rect; the flat field mirrors that.)
---@param box table An EditBox created from InputBoxTemplate.
function M:FlattenEditBox(box)
	if box.Left then box.Left:Hide() end
	if box.Middle then box.Middle:Hide() end
	if box.Right then box.Right:Hide() end

	local border = box:CreateTexture(nil, "BACKGROUND", nil, 0)
	border:SetPoint("TOPLEFT", box, "TOPLEFT", -6, 1)
	border:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 2, -1)
	border:SetColorTexture(0.30, 0.27, 0.26, 1)

	local fill = box:CreateTexture(nil, "BACKGROUND", nil, 1)
	fill:SetPoint("TOPLEFT", border, "TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", -1, 1)
	fill:SetColorTexture(0.05, 0.045, 0.045, 1)
end

---Creates an edit box with a label using the specified options.
---@param options EditboxOptions
---@return EditBoxReturn
function M:EditBox(options)
	if not options then
		error("EditBox - options must not be nil.")
	end

	if not options.Parent or not options.GetValue or not options.SetValue then
		error("EditBox - invalid options.")
	end

	local label = options.Parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetText(options.LabelText or "")

	local box = CreateFrame("EditBox", nil, options.Parent, "InputBoxTemplate")
	M:FlattenEditBox(box)
	box:SetSize(options.Width or 80, options.Height or 20)
	box:SetAutoFocus(false)

	if options.Numeric then
		GUI.ConfigureNumericBox(box, options.AllowNegatives)
	end

	local function Commit()
		local new = box:GetText()

		options.SetValue(new)

		local value = options.GetValue() or ""

		box:SetText(tostring(value))
		box:SetCursorPosition(0)
	end

	box:SetScript("OnEnterPressed", function(boxSelf)
		boxSelf:ClearFocus()
		Commit()
	end)

	box:SetScript("OnEditFocusLost", Commit)

	function box.MiniRefresh(boxSelf)
		local value = options.GetValue()
		boxSelf:SetText(tostring(value))
		boxSelf:SetCursorPosition(0)
	end

	box:MiniRefresh()

	GUI.AddControlForRefresh(options.Parent, box)

	return { EditBox = box, Label = label }
end
