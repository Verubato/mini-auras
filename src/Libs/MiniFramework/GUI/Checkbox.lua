local addonName, addon = ...
local M = addon.Framework
local GUI = M.GUI
local L = M.L

local TRACK_WIDTH = 36
local TRACK_HEIGHT = 18
local KNOB_SIZE = 14
-- Track showing around the knob at rest.
local KNOB_MIN = 2
local KNOB_TRAVEL = TRACK_WIDTH - KNOB_SIZE - KNOB_MIN * 2
local SLIDE_SECONDS = 0.15
-- White shapes tinted with vertex colors; the client can only draw rectangles itself. The
-- path assumes the prescribed embed location, Libs\MiniFramework inside the addon.
local MEDIA_PATH = "Interface\\AddOns\\" .. addonName .. "\\Libs\\MiniFramework\\Media\\"
local PILL_TEXTURE = MEDIA_PATH .. "TogglePill.tga"
local KNOB_TEXTURE = MEDIA_PATH .. "ToggleKnob.tga"
-- Both textures keep a one-texel transparent margin so bilinear sampling can't bleed across
-- the border; cropping it keeps the drawn shape exactly the region's size.
local PILL_CROP = 1 / 64
local KNOB_CROP = 1 / 32
local LABEL_GAP = 6
-- Numeric sound kit ids arrived in 7.3; older clients take the sound name.
local SOUND_ON = SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or "igMainMenuOptionCheckBoxOn"
local SOUND_OFF = SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF or "igMainMenuOptionCheckBoxOff"
local KNOB_IDLE = { r = 0.91, g = 0.89, b = 0.85 }
local KNOB_HOVER = { r = 1, g = 1, b = 1 }
local TRACK_OFF = { r = 0.17, g = 0.15, b = 0.15 }
local TRACK_HOVER = { r = 0.26, g = 0.23, b = 0.22 }
-- A disabled toggle drops the accent entirely: grey fill plus a heavy dim, so an on-but-locked
-- switch can't be mistaken for one that is live.
local FILL_DISABLED = { r = 0.40, g = 0.38, b = 0.36 }
local DISABLED_ALPHA = 0.3

local function ShowTooltip(checkbox, options)
	GameTooltip:SetOwner(checkbox, "ANCHOR_RIGHT")

	local tooltipTitle = options.LabelText

	if not tooltipTitle or tooltipTitle:match("^%s*$") then
		tooltipTitle = L["Information"]
	end

	GameTooltip:SetText(tooltipTitle, 1, 0.82, 0)
	GameTooltip:AddLine(options.Tooltip, 1, 1, 1, true)
	GameTooltip:Show()
end

---Paints the fill from the toggle's current palette, with the opacity baked into the gradient
---colors: a gradient's vertex alpha wins over SetAlpha, so fading the texture does nothing.
local function ApplyFill(toggle, alpha)
	local color = toggle.__fillColor

	GUI.TintGradientH(
		toggle.Fill,
		color.r * 0.6,
		color.g * 0.6,
		color.b * 0.6,
		alpha,
		color.r,
		color.g,
		color.b,
		alpha
	)
end

local function SetProgress(toggle, progress)
	toggle.__progress = progress
	ApplyFill(toggle, progress)
	toggle.Knob:SetPoint("LEFT", toggle.Track, "LEFT", KNOB_MIN + KNOB_TRAVEL * progress, 0)
end

local function OnSlideUpdate(toggle, elapsed)
	local target = toggle:GetChecked() and 1 or 0
	local progress = toggle.__progress
	local step = elapsed / SLIDE_SECONDS

	if progress < target then
		progress = math.min(target, progress + step)
	else
		progress = math.max(target, progress - step)
	end

	if progress == target then
		toggle:SetScript("OnUpdate", nil)
	end

	SetProgress(toggle, progress)
end

local function Snap(toggle)
	toggle:SetScript("OnUpdate", nil)
	SetProgress(toggle, toggle:GetChecked() and 1 or 0)
end

---Replacement SetChecked so state set from outside (refresh, panel code) moves the visuals too.
local function ToggleSetChecked(toggle, checked)
	toggle.__baseSetChecked(toggle, checked)
	Snap(toggle)
end

local function OnToggleClick(toggle)
	local options = toggle.__options

	-- Write the flipped source value rather than reading GetChecked: going back to the source
	-- keeps a vetoing setter authoritative, and works the same on clients that toggle the
	-- button natively and ones that don't.
	options.SetValue(not options.GetValue())

	local checked = options.GetValue() and true or false

	toggle.__baseSetChecked(toggle, checked)
	toggle:SetScript("OnUpdate", OnSlideUpdate)

	if PlaySound then
		PlaySound(checked and SOUND_ON or SOUND_OFF)
	end
end

local function OnToggleEnter(toggle)
	toggle.Track:SetVertexColor(TRACK_HOVER.r, TRACK_HOVER.g, TRACK_HOVER.b, 1)
	toggle.Knob:SetVertexColor(KNOB_HOVER.r, KNOB_HOVER.g, KNOB_HOVER.b, 1)

	if toggle.__options.Tooltip then
		ShowTooltip(toggle, toggle.__options)
	end
end

local function OnToggleLeave(toggle)
	toggle.Track:SetVertexColor(TRACK_OFF.r, TRACK_OFF.g, TRACK_OFF.b, 1)
	toggle.Knob:SetVertexColor(KNOB_IDLE.r, KNOB_IDLE.g, KNOB_IDLE.b, 1)
	GameTooltip:Hide()
end

local function OnToggleDisable(toggle)
	toggle.__fillColor = FILL_DISABLED
	toggle:SetAlpha(DISABLED_ALPHA)
	ApplyFill(toggle, toggle.__progress)
end

local function OnToggleEnable(toggle)
	toggle.__fillColor = GUI.Accent
	toggle:SetAlpha(1)
	ApplyFill(toggle, toggle.__progress)
end

---A pill-shaped sliding switch: dark track, crimson fill when on, round knob that slides
---between the ends.
local function BuildToggle(options)
	local pixel = GUI.Pixel
	local toggle = CreateFrame("CheckButton", nil, options.Parent)

	-- Same height as the stock checkbox so rows keep their vertical rhythm either way.
	toggle:SetSize(TRACK_WIDTH, 26)
	toggle.__options = options

	-- Pill-shaped track, tinted white-on-shape so hover can re-tint it.
	local track = toggle:CreateTexture(nil, "BACKGROUND")
	pixel.SetSize(track, TRACK_WIDTH, TRACK_HEIGHT)
	track:SetPoint("LEFT", toggle, "LEFT", 0, 0)
	track:SetTexture(PILL_TEXTURE)
	track:SetTexCoord(PILL_CROP, 1 - PILL_CROP, PILL_CROP, 1 - PILL_CROP)
	track:SetVertexColor(TRACK_OFF.r, TRACK_OFF.g, TRACK_OFF.b, 1)
	toggle.Track = track

	-- The on state: the same pill tinted with the accent gradient, faded in by the slide.
	local fill = toggle:CreateTexture(nil, "BACKGROUND", nil, 1)
	fill:SetAllPoints(track)
	fill:SetTexture(PILL_TEXTURE)
	fill:SetTexCoord(PILL_CROP, 1 - PILL_CROP, PILL_CROP, 1 - PILL_CROP)
	toggle.Fill = fill
	toggle.__fillColor = GUI.Accent

	local knob = toggle:CreateTexture(nil, "ARTWORK")
	pixel.SetSize(knob, KNOB_SIZE, KNOB_SIZE)
	knob:SetTexture(KNOB_TEXTURE)
	knob:SetTexCoord(KNOB_CROP, 1 - KNOB_CROP, KNOB_CROP, 1 - KNOB_CROP)
	knob:SetVertexColor(KNOB_IDLE.r, KNOB_IDLE.g, KNOB_IDLE.b, 1)
	toggle.Knob = knob

	local label = toggle:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	label:SetPoint("LEFT", toggle, "RIGHT", LABEL_GAP, 0)
	label:SetText(options.LabelText or "")
	label:SetTextColor(1, 1, 1, 1)
	toggle.Text = label

	-- Clicking the label toggles too, as a switch is expected to behave.
	local labelWidth = label.GetStringWidth and label:GetStringWidth() or 0

	if labelWidth > 0 then
		toggle:SetHitRectInsets(0, -(labelWidth + LABEL_GAP), 0, 0)
	end

	toggle.__baseSetChecked = toggle.SetChecked
	toggle.SetChecked = ToggleSetChecked
	toggle:SetChecked(options.GetValue())

	toggle:SetScript("OnClick", OnToggleClick)
	toggle:SetScript("OnEnter", OnToggleEnter)
	toggle:SetScript("OnLeave", OnToggleLeave)
	toggle:SetScript("OnDisable", OnToggleDisable)
	toggle:SetScript("OnEnable", OnToggleEnable)

	function toggle.MiniRefresh()
		toggle:SetChecked(options.GetValue())
	end

	return toggle
end

local function BuildStockCheckbox(options)
	local checkbox = CreateFrame("CheckButton", nil, options.Parent, "UICheckButtonTemplate")

	local labelText = GUI.GetCheckboxLabel(checkbox)

	if labelText then
		labelText:SetText(" " .. (options.LabelText or ""))
		labelText:SetFontObject("GameFontNormal")
	end

	checkbox:SetChecked(options.GetValue())
	checkbox:HookScript("OnClick", function(chkSelf)
		options.SetValue(not options.GetValue())

		-- check the value changed at the source
		chkSelf:SetChecked(options.GetValue())
	end)

	if options.Tooltip then
		checkbox:SetScript("OnEnter", function(chkSelf)
			ShowTooltip(chkSelf, options)
		end)

		checkbox:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end

	function checkbox.MiniRefresh()
		checkbox:SetChecked(options.GetValue())
	end

	return checkbox
end

---Creates a boolean control using the specified options: a sliding toggle switch under the
---accented restyle, the stock Blizzard checkbox otherwise. Both answer SetChecked/GetChecked.
---@param options CheckboxOptions
---@return table checkbox
function M:Checkbox(options)
	if not options then
		error("Checkbox - options must not be nil.")
	end

	if not options.Parent or not options.GetValue or not options.SetValue then
		error("Checkbox - invalid options.")
	end

	local checkbox

	if GUI.IsStyled(options) then
		checkbox = BuildToggle(options)
	else
		checkbox = BuildStockCheckbox(options)
	end

	GUI.AddControlForRefresh(options.Parent, checkbox)

	return checkbox
end

---@class CheckboxOptions
---@field Parent table
---@field LabelText string
---@field Tooltip string?
---@field CustomStyling boolean? Override the framework-wide styling default for this checkbox
---@field GetValue fun(): boolean
---@field SetValue fun(value: boolean)
