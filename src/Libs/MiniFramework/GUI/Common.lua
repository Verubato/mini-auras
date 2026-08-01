local _, addon = ...
local M = addon.Framework
local GUI = M.GUI

-- The only keys M:SetPalette will accept. GUI holds compat helpers too, so overriding by
-- truthiness alone would let a caller replace a function with a color table.
local PALETTE_KEYS = {
	Accent = true,
	AccentHi = true,
	TabTextIdle = true,
	TabTextHover = true,
	DividerLine = true,
	DividerGold = true,
	TitleText = true,
}

-- Config-UI palette: one crimson accent (the MiniCC logo red) plus warm neutrals. Plain
-- tables at file scope; ColorMixins are created lazily because CreateColor only exists in
-- the real client. Override with M:SetPalette to rebrand.
GUI.Accent = { r = 0.78, g = 0.20, b = 0.24 }
GUI.AccentHi = { r = 0.88, g = 0.29, b = 0.32 }
-- Idle/hover text for tab buttons (warm greys; selected is pure white). Horizontal sub-tabs
-- dim when idle; the vertical sidebar stays bright, with only the wash/bar marking selection.
GUI.TabTextIdle = { r = 0.73, g = 0.70, b = 0.66 }
GUI.TabTextHover = { r = 0.91, g = 0.89, b = 0.85 }
-- Divider rules and label (muted gold - the one deliberate nod to the WoW default palette).
GUI.DividerLine = { r = 0.42, g = 0.35, b = 0.25 }
GUI.DividerGold = { r = 0.81, g = 0.66, b = 0.31 }
-- Standalone window title. Deliberately a touch brighter and less saturated than Accent.
GUI.TitleText = { r = 0.90, g = 0.20, b = 0.20 }

---Whether a widget should draw the accented restyle rather than stock Blizzard art.
---A per-widget CustomStyling wins over the framework-wide default, including when false.
---@return boolean
function GUI.IsStyled(options)
	if options and options.CustomStyling ~= nil then
		return options.CustomStyling and true or false
	end

	return M.CustomStyling and true or false
end

function GUI.AddControlForRefresh(panel, control)
	-- store controls for refresh behaviour
	panel.MiniControls = panel.MiniControls or {}
	panel.MiniControls[#panel.MiniControls + 1] = control

	if panel.MiniRefresh then
		return
	end

	panel.MiniRefresh = function(panelSelf)
		for _, c in ipairs(panelSelf.MiniControls or {}) do
			if c.MiniRefresh then
				c:MiniRefresh()
			end
		end

		if panel.OnMiniRefresh then
			panel:OnMiniRefresh()
		end
	end
end

function GUI.ConfigureNumericBox(box, allowNegative)
	if not allowNegative then
		box:SetNumeric(true)
		return
	end

	box:HookScript("OnTextChanged", function(boxSelf, userInput)
		if not userInput then
			return
		end

		local text = boxSelf:GetText()

		-- allow: "", "-", "-123", "123"
		if text == "" or text == "-" or text:match("^%-?%d+$") then
			return
		end

		-- strip invalid chars
		text = text:gsub("[^%d%-]", "")

		-- only one leading '-'
		text = text:gsub("%-+", "-")

		if text:sub(1, 1) ~= "-" then
			text = text:gsub("%-", "")
		else
			text = "-" .. text:sub(2):gsub("%-", "")
		end

		boxSelf:SetText(text)
	end)
end

---Turns the accented restyle on or off for every widget this addon creates.
---Call before building any widgets.
function M:SetCustomStyling(enabled)
	M.CustomStyling = enabled and true or false
end

---Overrides one or more palette colors so an addon can rebrand the config UI.
---Call before building any widgets.
---@param colors table<string, {r:number, g:number, b:number}>
function M:SetPalette(colors)
	if not colors then
		error("SetPalette - colors must not be nil.")
	end

	for key, color in pairs(colors) do
		-- An explicit whitelist, not `if GUI[key]`: GUI also holds the compat helpers, and a
		-- key collision would replace a function with a color table. A typo errors rather
		-- than silently doing nothing.
		if not PALETTE_KEYS[key] then
			error("SetPalette - unknown palette color: " .. tostring(key))
		end

		GUI[key] = { r = color.r, g = color.g, b = color.b }
	end
end
