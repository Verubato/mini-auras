local _, addon = ...
local M = addon.Framework
local GUI = M.GUI

local BORDER_COLOR = { r = 0.30, g = 0.27, b = 0.26 }
local FILL_COLOR = { r = 0.05, g = 0.045, b = 0.045 }

---Draws the flat dark field behind an edit box.
---@param box table
---@param left number inset from the box's left edge (negative extends outwards)
---@param right number inset from the box's right edge (positive extends outwards)
local function DrawField(box, left, right)
	local border = box:CreateTexture(nil, "BACKGROUND", nil, 0)
	border:SetPoint("TOPLEFT", box, "TOPLEFT", left, 1)
	border:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", right, -1)
	GUI.SetSolid(border, BORDER_COLOR.r, BORDER_COLOR.g, BORDER_COLOR.b, 1)

	local fill = box:CreateTexture(nil, "BACKGROUND", nil, 1)
	fill:SetPoint("TOPLEFT", border, "TOPLEFT", 1, -1)
	fill:SetPoint("BOTTOMRIGHT", border, "BOTTOMRIGHT", -1, 1)
	GUI.SetSolid(fill, FILL_COLOR.r, FILL_COLOR.g, FILL_COLOR.b, 1)
end

---Strips InputBoxTemplate's parchment inset art and draws a flat dark field in its place.
---(The template's art extends ~5px left of the frame rect; the flat field mirrors that.)
---@param box table An EditBox created from InputBoxTemplate.
function M:FlattenEditBox(box)
	if box.Left then box.Left:Hide() end
	if box.Middle then box.Middle:Hide() end
	if box.Right then box.Right:Hide() end

	DrawField(box, -6, 2)
end

---Creates an edit box with a label using the specified options.
---@param options EditboxOptions
---@return EditBoxReturn
function M:EditBox(options)
	if not options then
		error("EditBox - options must not be nil.")
	end

	if not options.Parent or not options.GetValue then
		error("EditBox - invalid options.")
	end

	local readonly = options.Readonly == true

	if not readonly and not options.SetValue then
		error("EditBox - invalid options.")
	end

	local label = options.Parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetText(options.LabelText or "")

	local box

	if options.MultiLine then
		-- InputBoxTemplate's art is built for a single line, so a multi-line field is always
		-- drawn from scratch - there is no stock art to fall back to here.
		box = CreateFrame("EditBox", nil, options.Parent)
		box:SetMultiLine(true)
		box:SetFontObject("GameFontWhite")
		DrawField(box, 0, 0)
	else
		box = CreateFrame("EditBox", nil, options.Parent, "InputBoxTemplate")

		if GUI.IsStyled(options) then
			M:FlattenEditBox(box)
		end
	end

	box:SetSize(options.Width or 80, options.Height or 20)
	box:SetAutoFocus(false)

	if options.TextInsets then
		local insets = options.TextInsets
		box:SetTextInsets(insets.Left or 0, insets.Right or 0, insets.Top or 0, insets.Bottom or 0)
	elseif options.MultiLine then
		box:SetTextInsets(6, 6, 6, 6)
	end

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

	if readonly then
		-- Swallow edits by snapping the text back to the source value.
		box:SetScript("OnTextChanged", function(boxSelf, userInput)
			if not userInput then
				return
			end

			boxSelf:SetText(tostring(options.GetValue() or ""))
		end)
	else
		box:SetScript("OnEditFocusLost", Commit)
	end

	box:SetScript("OnEnterPressed", function(boxSelf)
		boxSelf:ClearFocus()

		if not readonly then
			Commit()
		end
	end)

	function box.MiniRefresh(boxSelf)
		local value = options.GetValue()
		boxSelf:SetText(tostring(value))
		boxSelf:SetCursorPosition(0)
	end

	box:MiniRefresh()

	GUI.AddControlForRefresh(options.Parent, box)

	return { EditBox = box, Label = label }
end

---@class EditBoxInsets
---@field Left number?
---@field Right number?
---@field Top number?
---@field Bottom number?

---@class EditboxOptions
---@field Parent table
---@field LabelText string?
---@field Numeric boolean?
---@field AllowNegatives boolean?
---@field MultiLine boolean?
---@field Readonly boolean?
---@field TextInsets EditBoxInsets?
---@field CustomStyling boolean? Override the framework-wide styling default for this box
---@field Width number?
---@field Height number?
---@field GetValue fun(): string|number
---@field SetValue fun(value: string|number)? required unless Readonly

---@class EditBoxReturn
---@field EditBox table
---@field Label table
