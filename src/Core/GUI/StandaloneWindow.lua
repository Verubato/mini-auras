local addonName, addon = ...
local M = addon.Core.Framework
local GUI = addon.Core.GUI

---Creates a floating, draggable standalone config window.
---@param options table { Name, Title, Subtitle, Width, Height, OnClose }
---@return table window
function M:CreateStandaloneWindow(options)
	local accent = GUI.Accent

	local width = options.Width or 860
	local height = options.Height or 680
	local frameName = options.Name or (addonName .. "ConfigFrame")

	local window = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
	window:SetSize(width, height)
	window:SetPoint("CENTER", UIParent, "CENTER")
	window:SetFrameStrata("HIGH")
	window:SetMovable(true)
	window:EnableMouse(true)
	window:SetToplevel(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", function(windowSelf)
		windowSelf:StartMoving()
	end)
	window:SetScript("OnDragStop", function(windowSelf)
		windowSelf:StopMovingOrSizing()
		local point, relativeTo, relativePoint, x, y = windowSelf:GetPoint()
		windowSelf:ClearAllPoints()
		windowSelf:SetPoint(point, relativeTo, relativePoint, x, y)
	end)
	window:Hide()

	-- Border only - fill is provided by gradient textures below
	window:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	window:SetBackdropColor(0, 0, 0, 0.75)
	window:SetBackdropBorderColor(0.21, 0.17, 0.18, 1)

	-- Title bar (transparent bg; gradient above provides the fill)
	local titleBar = CreateFrame("Frame", nil, window, "BackdropTemplate")
	titleBar:SetPoint("TOPLEFT", window, "TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", window, "TOPRIGHT", -1, -1)
	titleBar:SetHeight(40)
	titleBar:SetBackdropColor(0, 0, 0, 0)
	titleBar:SetBackdropBorderColor(0, 0, 0, 0)

	-- Accent line beneath title bar: crimson fading out from the logo side.
	local accentLine = window:CreateTexture(nil, "ARTWORK")
	accentLine:SetHeight(1)
	accentLine:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
	accentLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
	GUI.SetGradientH(accentLine, accent.r, accent.g, accent.b, 0.9, accent.r, accent.g, accent.b, 0.04)

	-- Title text (warm white)
	local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	titleText:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
	titleText:SetText(options.Title or "")
	titleText:SetTextColor(0.9, 0.2, 0.2, 1)

	-- Optional subtitle / version beside title
	if options.Subtitle then
		local subtitleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		subtitleText:SetPoint("LEFT", titleText, "RIGHT", 8, -1)
		subtitleText:SetText(options.Subtitle)
		subtitleText:SetTextColor(0.80, 0.80, 0.80, 1)
		window.SubtitleText = subtitleText
	end

	-- Close (×) button
	local closeBtn = CreateFrame("Button", nil, titleBar)
	closeBtn:SetSize(28, 28)
	closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)

	local closeHighlight = closeBtn:CreateTexture(nil, "HIGHLIGHT")
	closeHighlight:SetAllPoints(closeBtn)
	closeHighlight:SetColorTexture(1, 1, 1, 0.07)

	local closeLabel = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	closeLabel:SetAllPoints(closeBtn)
	closeLabel:SetJustifyH("CENTER")
	closeLabel:SetJustifyV("MIDDLE")
	closeLabel:SetText("×")
	closeLabel:SetTextColor(0.5, 0.5, 0.5, 1)

	closeBtn:SetScript("OnEnter", function()
		closeLabel:SetTextColor(1, 0.3, 0.3, 1)
	end)
	closeBtn:SetScript("OnLeave", function()
		closeLabel:SetTextColor(0.5, 0.5, 0.5, 1)
	end)
	closeBtn:SetScript("OnClick", function()
		window:Hide()
		if options.OnClose then
			options.OnClose()
		end
	end)

	-- Content area (inset from window edges for breathing room)
	local pad = options.ContentPadding or 12
	local content = CreateFrame("Frame", nil, window)
	content:SetPoint("TOPLEFT", accentLine, "BOTTOMLEFT", pad, -(pad + 1))
	content:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -(pad + 1), pad + 1)

	-- ESC key closes this window (via OnKeyDown, not UISpecialFrames - avoids being
	-- closed when Blizzard's settings panel closes)
	window:SetPropagateKeyboardInput(true)
	window:EnableKeyboard(true)
	window:SetScript("OnKeyDown", function(windowSelf, key)
		if key == "ESCAPE" and windowSelf:IsShown() then
			windowSelf:Hide()
			if options.OnClose then
				options.OnClose()
			end
			if not InCombatLockdown() then
				windowSelf:SetPropagateKeyboardInput(false)
			end
		else
			if not InCombatLockdown() then
				windowSelf:SetPropagateKeyboardInput(true)
			end
		end
	end)

	window.TitleBar = titleBar
	window.TitleText = titleText
	window.Content = content
	window.CloseButton = closeBtn

	function window.Toggle(windowSelf)
		if windowSelf:IsShown() then
			windowSelf:Hide()
		else
			windowSelf:Show()
		end
	end

	return window
end
