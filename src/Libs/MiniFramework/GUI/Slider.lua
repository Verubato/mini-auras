local addonName, addon = ...
local M = addon.Framework
local GUI = M.GUI
local sliderId = 1

local function GetDecimalPlaces(step)
	local s = tostring(step)
	local dot = s:find("%.")

	if not dot then
		return 0
	end

	return #s - dot
end

local function GetMaxLetters(min, max, step)
	local decimals = GetDecimalPlaces(step)

	local maxAbs = math.max(math.abs(min), math.abs(max))
	local intDigits = #tostring(math.floor(maxAbs))

	local letters = intDigits

	if decimals > 0 then
		letters = letters + 1 + decimals -- dot + decimals
	end

	if min < 0 then
		letters = letters + 1 -- minus sign
	end

	return letters
end

---Creates a slider using the specified options.
---@param options SliderOptions
---@return SliderReturn
function M:Slider(options)
	if not options then
		error("Slider - options must not be nil.")
	end

	if
		not options.Parent
		or not options.GetValue
		or not options.SetValue
		or not options.Min
		or not options.Max
		or not options.Step
	then
		error("Slider - invalid options.")
	end

	local pixel = GUI.Pixel
	local accent = GUI.Accent

	-- OptionsSliderTemplate looks up its Low/High/Text font strings by global name.
	local slider = CreateFrame("Slider", addonName .. "Slider" .. sliderId, options.Parent, "OptionsSliderTemplate")
	sliderId = sliderId + 1

	local label = slider:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetPoint("BOTTOMLEFT", slider, "TOPLEFT", 0, 8)
	label:SetText(options.LabelText or "")

	slider:SetOrientation("HORIZONTAL")
	slider:SetMinMaxValues(options.Min, options.Max)
	slider:SetValue(options.GetValue())
	slider:SetValueStep(options.Step)
	GUI.TryCall(slider, "SetObeyStepOnDrag", true)
	slider:SetHeight(20)
	slider:SetWidth(options.Width or 400)

	local styled = GUI.IsStyled(options)

	if styled then
		-- Flat restyle: drop the template's ornate rail for a thin track with a crimson fill
		-- up to the thumb (the fill's right edge is anchored to the thumb texture, so it
		-- follows the value with no OnValueChanged bookkeeping).
		if slider.SetBackdrop then
			slider:SetBackdrop(nil)
		end

		local track = slider:CreateTexture(nil, "BACKGROUND")
		pixel.SetHeight(track, 4)
		track:SetPoint("LEFT", slider, "LEFT", 0, 0)
		track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
		GUI.SetSolid(track, GUI.FieldIdle.r, GUI.FieldIdle.g, GUI.FieldIdle.b, 1)

		-- The toggle's circle knob as the thumb, so the two controls read as siblings.
		slider:SetThumbTexture(GUI.KnobTexture)
		local thumb = slider:GetThumbTexture()
		thumb:SetSize(14, 14)
		GUI.CropIcon(thumb)
		thumb:SetVertexColor(GUI.KnobIdle.r, GUI.KnobIdle.g, GUI.KnobIdle.b, 1)

		local fill = slider:CreateTexture(nil, "BACKGROUND", nil, 1)
		pixel.SetHeight(fill, 4)
		fill:SetPoint("LEFT", track, "LEFT", 0, 0)
		fill:SetPoint("RIGHT", thumb, "CENTER", 0, 0)
		GUI.SetGradientH(fill, accent.r * 0.6, accent.g * 0.6, accent.b * 0.6, 1, accent.r, accent.g, accent.b, 1)

		slider:HookScript("OnEnter", function()
			thumb:SetVertexColor(GUI.KnobHover.r, GUI.KnobHover.g, GUI.KnobHover.b, 1)
		end)

		slider:HookScript("OnLeave", function()
			thumb:SetVertexColor(GUI.KnobIdle.r, GUI.KnobIdle.g, GUI.KnobIdle.b, 1)
		end)

		-- Same treatment as a disabled toggle: heavy dim and the accent swapped for grey. The
		-- box and label are children of the slider, so the alpha covers them too.
		slider:HookScript("OnDisable", function()
			slider:SetAlpha(GUI.DisabledAlpha)
			GUI.SetGradientH(
				fill,
				GUI.FillDisabled.r * 0.6,
				GUI.FillDisabled.g * 0.6,
				GUI.FillDisabled.b * 0.6,
				1,
				GUI.FillDisabled.r,
				GUI.FillDisabled.g,
				GUI.FillDisabled.b,
				1
			)
		end)

		slider:HookScript("OnEnable", function()
			slider:SetAlpha(1)
			GUI.SetGradientH(fill, accent.r * 0.6, accent.g * 0.6, accent.b * 0.6, 1, accent.r, accent.g, accent.b, 1)
		end)
	end

	local low = _G[slider:GetName() .. "Low"]
	local high = _G[slider:GetName() .. "High"]

	if low and high then
		low:SetText(options.Min)
		high:SetText(options.Max)
	end

	-- Hidden regardless of styling: the edit box below shows the value and is editable.
	local text = _G[slider:GetName() .. "Text"]
	if text then
		text:Hide()
	end

	local hasFloat = math.floor(options.Step) ~= options.Step
	local box = CreateFrame("EditBox", nil, slider, "InputBoxTemplate")

	if styled then
		-- A pill chip instead of the flat field, matching the toggle's geometry.
		if box.Left then
			box.Left:Hide()
		end
		if box.Middle then
			box.Middle:Hide()
		end
		if box.Right then
			box.Right:Hide()
		end

		local chip = GUI.PillField(box, 20, "BACKGROUND")
		chip:SetColor(GUI.FieldIdle.r, GUI.FieldIdle.g, GUI.FieldIdle.b, 1)
	end

	if not hasFloat then
		GUI.ConfigureNumericBox(box, options.Min < 0)
	end

	box:SetPoint("CENTER", slider, "CENTER", 0, 30)
	box:SetFontObject("GameFontWhite")
	box:SetSize(50, 20)
	box:SetAutoFocus(false)
	box:SetMaxLetters(GetMaxLetters(options.Min, options.Max, options.Step))
	box:SetText(tostring(options.GetValue()))
	box:SetJustifyH("CENTER")
	box:SetCursorPosition(0)

	slider:SetScript("OnValueChanged", function(_, sliderValue, userInput)
		if userInput ~= nil and not userInput then
			return
		end

		box:SetText(tostring(sliderValue))

		options.SetValue(sliderValue)
	end)

	box:SetScript("OnTextChanged", function(_, userInput)
		if not userInput then
			return
		end

		local value = tonumber(box:GetText())

		-- don't clamp values here, because they might still be typing out a number
		if not value then
			return
		end

		slider:SetValue(value)
		options.SetValue(value)
	end)

	function box.MiniRefresh(boxSelf)
		local value = options.GetValue()
		boxSelf:SetText(tostring(value))
		boxSelf:SetCursorPosition(0)
	end

	function slider.MiniRefresh(sliderSelf)
		local value = options.GetValue()
		sliderSelf:SetValue(value)
	end

	GUI.AddControlForRefresh(options.Parent, slider)
	GUI.AddControlForRefresh(options.Parent, box)

	return { Slider = slider, EditBox = box, Label = label }
end

---@class SliderOptions
---@field Parent table
---@field LabelText string?
---@field Min number
---@field Max number
---@field Step number
---@field Width number?
---@field CustomStyling boolean? Override the framework-wide styling default for this slider
---@field GetValue fun(): number
---@field SetValue fun(value: number)

---@class SliderReturn
---@field Label table
---@field EditBox table
---@field Slider table
