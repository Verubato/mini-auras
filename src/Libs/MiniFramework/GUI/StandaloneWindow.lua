local addonName, addon = ...
local M = addon.Framework
local GUI = M.GUI

local BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Buttons\\WHITE8X8",
	edgeSize = 1,
}

local TITLE_BAR_HEIGHT = 40

-- Sizing handles sit on the window's own edges, but every widget the caller adds lives in a
-- descendant of Content and so draws at a higher level. Lift the handles clear of that stack.
local HANDLE_LEVEL_OFFSET = 50
local EDGE_THICKNESS = 6
local GRIP_SIZE = 14
local GRIP_DOT = 2
local GRIP_SPACING = 4

---Re-anchors a window to a single point. StartMoving/StartSizing rewrite the frame's anchors as
---a side effect, which leaves multi-point or screen-relative anchors behind; collapsing back to
---one point keeps later SetPoint calls predictable.
local function NormalizePoint(window)
	local point, relativeTo, relativePoint, x, y = window:GetPoint()

	if not point then
		return
	end

	window:ClearAllPoints()
	window:SetPoint(point, relativeTo, relativePoint, x, y)
end

---Diagonal dot triangle for the bottom-right corner grip. Drawn rather than textured because
---the stock chat-frame grabber art doesn't match the flat styling.
local function BuildGripDots(grip)
	local dots = {}

	for row = 1, 3 do
		for col = 1, 4 - row do
			local dot = grip:CreateTexture(nil, "OVERLAY")
			dot:SetSize(GRIP_DOT, GRIP_DOT)
			dot:SetPoint("BOTTOMRIGHT", grip, "BOTTOMRIGHT", -(col - 1) * GRIP_SPACING, (row - 1) * GRIP_SPACING)
			GUI.SetSolid(dot, 0.45, 0.45, 0.45, 1)
			dots[#dots + 1] = dot
		end
	end

	return dots
end

---@param window table
---@param direction string anchor point passed to StartSizing
---@param onResizeStop fun()?
---@return table handle
local function CreateSizingHandle(window, direction, onResizeStop)
	local handle = CreateFrame("Frame", nil, window)
	handle:EnableMouse(true)
	handle:SetFrameLevel(window:GetFrameLevel() + HANDLE_LEVEL_OFFSET)

	handle:SetScript("OnMouseDown", function()
		window:StartSizing(direction)
	end)

	handle:SetScript("OnMouseUp", function()
		window:StopMovingOrSizing()
		NormalizePoint(window)

		if onResizeStop then
			onResizeStop()
		end
	end)

	return handle
end

---Adds edge and corner drag handles. Width and height resize independently from the two edges;
---the corner grip does both at once.
local function MakeResizable(window, options, width, height)
	local screenWidth = UIParent and UIParent:GetWidth() or 0
	local screenHeight = UIParent and UIParent:GetHeight() or 0
	local minWidth = options.MinWidth or width
	local minHeight = options.MinHeight or height
	local maxWidth = options.MaxWidth or math.max(width, screenWidth)
	local maxHeight = options.MaxHeight or math.max(height, screenHeight)

	window:SetResizable(true)

	-- SetResizeBounds arrived in 9.0; before that the two limits were set separately.
	if window.SetResizeBounds then
		window:SetResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
	else
		GUI.TryCall(window, "SetMinResize", minWidth, minHeight)
		GUI.TryCall(window, "SetMaxResize", maxWidth, maxHeight)
	end

	local function OnResizeStop()
		if options.OnResizeStop then
			options.OnResizeStop(window:GetWidth(), window:GetHeight())
		end
	end

	-- Right edge - width only. Anchored to the window rather than the title bar so it covers the
	-- outermost pixel column; starting below the title bar keeps it off the close button.
	local rightEdge = CreateSizingHandle(window, "RIGHT", OnResizeStop)
	rightEdge:SetWidth(EDGE_THICKNESS)
	rightEdge:SetPoint("TOPRIGHT", window, "TOPRIGHT", 0, -(TITLE_BAR_HEIGHT + 1))
	rightEdge:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", 0, GRIP_SIZE)

	-- Bottom edge - height only.
	local bottomEdge = CreateSizingHandle(window, "BOTTOM", OnResizeStop)
	bottomEdge:SetHeight(EDGE_THICKNESS)
	bottomEdge:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 0, 0)
	bottomEdge:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -GRIP_SIZE, 0)

	-- Corner grip - both axes, and the only handle with any art.
	local grip = CreateSizingHandle(window, "BOTTOMRIGHT", OnResizeStop)
	grip:SetSize(GRIP_SIZE, GRIP_SIZE)
	grip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -2, 2)

	local dots = BuildGripDots(grip)

	grip:SetScript("OnEnter", function()
		for _, dot in ipairs(dots) do
			GUI.SetSolid(dot, 0.85, 0.85, 0.85, 1)
		end
	end)

	grip:SetScript("OnLeave", function()
		for _, dot in ipairs(dots) do
			GUI.SetSolid(dot, 0.45, 0.45, 0.45, 1)
		end
	end)

	-- Deliberately NOT window.RightEdge / window.BottomEdge. BackdropTemplateMixin keeps its
	-- backdrop piece textures in fields of exactly those names (alongside Center, TopEdge,
	-- LeftEdge and the four corners), so using them here replaces two textures with frames and
	-- the next re-tile calls SetTexCoord on a Frame.
	window.ResizeRight = rightEdge
	window.ResizeBottom = bottomEdge
	window.ResizeGrip = grip

	if options.OnResize then
		window:HookScript("OnSizeChanged", function(windowSelf, w, h)
			options.OnResize(w, h)
		end)
	end
end

---Creates a floating, draggable standalone config window.
---@param options StandaloneWindowOptions
---@return table window
function M:CreateStandaloneWindow(options)
	if not options then
		error("CreateStandaloneWindow - options must not be nil.")
	end

	local accent = GUI.Accent
	local titleColor = GUI.TitleText

	local width = options.Width or 860
	local height = options.Height or 680
	local frameName = options.Name or (addonName .. "ConfigFrame")

	local window = CreateFrame("Frame", frameName, UIParent, GUI.BackdropTemplate)
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
		NormalizePoint(windowSelf)
	end)
	window:Hide()

	-- Border only - fill is provided by gradient textures below
	GUI.ApplyBackdrop(window, BACKDROP, 0, 0, 0, 0.75, 0.21, 0.17, 0.18, 1)

	-- Title bar. Left without a backdrop of its own - the window fill shows through and the
	-- accent line below provides the only edge. Still a backdrop frame so callers can add one.
	local titleBar = CreateFrame("Frame", nil, window, GUI.BackdropTemplate)
	titleBar:SetPoint("TOPLEFT", window, "TOPLEFT", 1, -1)
	titleBar:SetPoint("TOPRIGHT", window, "TOPRIGHT", -1, -1)
	titleBar:SetHeight(TITLE_BAR_HEIGHT)

	-- Accent line beneath title bar: crimson fading out from the logo side.
	local accentLine = window:CreateTexture(nil, "ARTWORK")
	accentLine:SetHeight(1)
	accentLine:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
	accentLine:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
	GUI.SetGradientH(accentLine, accent.r, accent.g, accent.b, 0.9, accent.r, accent.g, accent.b, 0.04)

	-- Title text
	local titleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	titleText:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
	titleText:SetText(options.Title or "")
	titleText:SetTextColor(titleColor.r, titleColor.g, titleColor.b, 1)

	-- Optional subtitle / version beside the title: a size smaller and dimmer than the
	-- logotype, baseline-aligned, so it reads as a quiet annotation rather than debug output.
	if options.Subtitle then
		local subtitleText = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")

		-- The title's own face at two thirds the size, so the pair always match whatever font
		-- the logotype uses.
		local titleFont, titleSize, titleFlags = titleText:GetFont()
		local subtitleSize = math.floor((titleSize or 16) * 0.65 + 0.5)
		if titleFont then
			subtitleText:SetFont(titleFont, subtitleSize, titleFlags)
		end

		subtitleText:SetText(options.Subtitle)
		subtitleText:SetTextColor(0.55, 0.52, 0.48, 1)

		-- Bottom-anchoring two font sizes leaves the smaller text sitting low: a fontstring's
		-- bottom is baseline minus descent, and the larger font descends further. Lift by the
		-- descent difference (Friz Quadrata descends roughly a quarter of its size) so the two
		-- BASELINES line up instead of the frame edges.
		local lift = math.floor(((titleSize or 16) - subtitleSize) * 0.25 + 0.5)
		subtitleText:SetPoint("BOTTOMLEFT", titleText, "BOTTOMRIGHT", 8, lift)

		window.SubtitleText = subtitleText
	end

	-- Close (x) button
	local closeBtn = CreateFrame("Button", nil, titleBar)
	closeBtn:SetSize(28, 28)
	closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -6, 0)

	local closeHighlight = closeBtn:CreateTexture(nil, "HIGHLIGHT")
	closeHighlight:SetAllPoints(closeBtn)
	GUI.SetSolid(closeHighlight, 1, 1, 1, 0.07)

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
	GUI.TryCall(window, "SetPropagateKeyboardInput", true)
	window:EnableKeyboard(true)
	window:SetScript("OnKeyDown", function(windowSelf, key)
		if key == "ESCAPE" and windowSelf:IsShown() then
			windowSelf:Hide()

			if options.OnClose then
				options.OnClose()
			end

			if not InCombatLockdown() then
				GUI.TryCall(windowSelf, "SetPropagateKeyboardInput", false)
			end
		else
			if not InCombatLockdown() then
				GUI.TryCall(windowSelf, "SetPropagateKeyboardInput", true)
			end
		end
	end)

	window.TitleBar = titleBar
	window.TitleText = titleText
	window.Content = content
	window.CloseButton = closeBtn

	if options.Resizable then
		MakeResizable(window, options, width, height)
	end

	function window.Toggle(windowSelf)
		if windowSelf:IsShown() then
			windowSelf:Hide()
		else
			windowSelf:Show()
		end
	end

	return window
end

---@class StandaloneWindowOptions
---@field Name string? global frame name, defaults to "<AddonName>ConfigFrame"
---@field Title string?
---@field Subtitle string?
---@field Width number?
---@field Height number?
---@field ContentPadding number?
---@field OnClose fun()?
---@field Resizable boolean? adds right/bottom edge handles and a bottom-right corner grip
---@field MinWidth number? defaults to Width
---@field MinHeight number? defaults to Height
---@field MaxWidth number? defaults to the screen width
---@field MaxHeight number? defaults to the screen height
---@field OnResize fun(width:number, height:number)? fires continuously while dragging
---@field OnResizeStop fun(width:number, height:number)? fires once the drag ends
