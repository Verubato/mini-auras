local _, addon = ...

-- Internal helpers and palette shared by the GUI widget files. Not part of the public
-- Framework API - widgets themselves attach to addon.Core.Framework.
local GUI = {}
addon.Core.GUI = GUI

-- Config-UI palette: one crimson accent (the MiniCC logo red) plus warm neutrals. Plain
-- tables at file scope; ColorMixins are created lazily because CreateColor only exists in
-- the real client.
GUI.Accent = { r = 0.78, g = 0.20, b = 0.24 }
GUI.AccentHi = { r = 0.88, g = 0.29, b = 0.32 }
-- Idle/hover text for tab buttons (warm greys; selected is pure white). Horizontal sub-tabs
-- dim when idle; the vertical sidebar stays bright, with only the wash/bar marking selection.
GUI.TabTextIdle = { r = 0.73, g = 0.70, b = 0.66 }
GUI.TabTextHover = { r = 0.91, g = 0.89, b = 0.85 }
-- Divider rules and label (muted gold - the one deliberate nod to the WoW default palette).
GUI.DividerLine = { r = 0.42, g = 0.35, b = 0.25 }
GUI.DividerGold = { r = 0.81, g = 0.66, b = 0.31 }

---Turns a texture into a horizontal gradient (first color left, second right).
function GUI.SetGradientH(texture, r1, g1, b1, a1, r2, g2, b2, a2)
	texture:SetColorTexture(1, 1, 1, 1)
	texture:SetGradient("HORIZONTAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
end

---Turns a texture into a vertical gradient (first color bottom, second top).
function GUI.SetGradientV(texture, r1, g1, b1, a1, r2, g2, b2, a2)
	texture:SetColorTexture(1, 1, 1, 1)
	texture:SetGradient("VERTICAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
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
