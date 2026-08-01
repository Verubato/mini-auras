local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local pixel = GUI.Pixel

---@param options TabOptions
---@return TabReturn
function M:CreateTabs(options)
	assert(options and options.Parent, "CreateTabs: options.Parent required")
	assert(options.Tabs and #options.Tabs > 0, "CreateTabs: options.Tabs required")

	local accent = GUI.Accent
	local accentHi = GUI.AccentHi
	local tabTextIdle = GUI.TabTextIdle
	local tabTextHover = GUI.TabTextHover

	local parent = options.Parent
	local vertical = options.Vertical
	local tabHeight = options.TabHeight or 22
	local tabMinWidth = options.TabMinWidth or 80
	-- Vertical rows are flat (no boxes), so they sit nearly flush.
	local tabSpacing = options.TabSpacing or (vertical and 2 or 6)
	local stripHeight = options.StripHeight or 28
	local stripWidth = options.StripWidth or 130
	local horizontalPadding = options.HorizontalPadding or 0

	local insets = options.ContentInsets or {}
	local insetL = insets.Left or 0
	local insetR = insets.Right or 0
	local insetT = insets.Top or 0
	local insetB = insets.Bottom or 10

	local strip = CreateFrame("Frame", nil, parent, GUI.BackdropTemplate)
	if vertical then
		strip:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
		strip:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, 0)
		strip:SetWidth(stripWidth)
	else
		strip:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
		strip:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, 0)
		strip:SetHeight(stripHeight)
	end

	local body = CreateFrame("Frame", nil, parent)
	if vertical then
		body:SetPoint("TOPLEFT", strip, "TOPRIGHT", horizontalPadding + insetL, -insetT)
		body:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -insetR, insetB)
	else
		body:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", insetL, -insetT)
		body:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -insetR, insetB)
	end

	---@type {Key:string, Title:string, Button:table, Content:table}[]
	local tabs = {}
	local keyToIndex = {}
	local selectedKey

	local function GetIndex(keyOrIndex)
		if type(keyOrIndex) == "number" then
			return keyOrIndex
		end
		if type(keyOrIndex) == "string" then
			return keyToIndex[keyOrIndex]
		end
	end

	local function SizeToText(btn)
		local fs = btn.Text
		local w = tabMinWidth
		if fs and fs.GetUnboundedStringWidth then
			w = math.max(tabMinWidth, fs:GetUnboundedStringWidth() + 26)
		elseif fs and fs.GetStringWidth then
			w = math.max(tabMinWidth, fs:GetStringWidth() + 26)
		end
		btn:SetWidth(w)
	end

	-- Horizontal mode: single continuous baseline under every tab; the selected tab's accent
	-- underline overlays it. Anchored after the tab loop.
	local baseline = strip:CreateTexture(nil, "OVERLAY")
	pixel.SetHeight(baseline, 1)
	GUI.SetSolid(baseline, 1, 1, 1, 0.10)

	-- Vertical mode: static right-edge separator line. The bottom edge is anchored to the last
	-- button after the tab loop (the strip itself extends past it to the parent's bottom).
	local vLine
	if vertical then
		vLine = strip:CreateTexture(nil, "OVERLAY")
		pixel.SetWidth(vLine, 1)
		GUI.SetSolid(vLine, 1, 1, 1, 0.10)
		pixel.SetPoint(vLine, "TOPRIGHT", strip, "TOPRIGHT", 0, 0)
	end

	-- Assigned after the tab loop; anchors the separator/baseline end points.
	local lastBtn

	local function SetSelected(btn, isSelected)
		if isSelected then
			btn.Text:SetTextColor(1, 1, 1, 1)
			btn.Highlight:Hide()

			if vertical then
				if btn.Wash then btn.Wash:Show() end
				if btn.Indicator then btn.Indicator:Show() end
			else
				if btn.Accent then btn.Accent:Show() end
			end
		else
			local idle = vertical and tabTextHover or tabTextIdle
			btn.Text:SetTextColor(idle.r, idle.g, idle.b, 1)

			if vertical then
				if btn.Wash then btn.Wash:Hide() end
				if btn.Indicator then btn.Indicator:Hide() end
			else
				if btn.Accent then btn.Accent:Hide() end
			end
		end
	end

	local controller = {}

	function controller.GetSelected(_)
		return selectedKey
	end

	function controller.GetContent(_, keyOrIndex)
		local i = GetIndex(keyOrIndex)
		return i and tabs[i] and tabs[i].Content
	end

	function controller.GetTabButton(_, keyOrIndex)
		local i = GetIndex(keyOrIndex)
		return i and tabs[i] and tabs[i].Button
	end

	function controller.Select(_, keyOrIndex)
		local i = GetIndex(keyOrIndex)
		if not i or not tabs[i] then
			return
		end

		selectedKey = tabs[i].Key

		for j = 1, #tabs do
			local isSel = (j == i)
			GUI.SetShown(tabs[j].Container, isSel)
			SetSelected(tabs[j].Button, isSel)
		end

		if tabs[i].Container.SetVerticalScroll then
			tabs[i].Container:SetVerticalScroll(0)
		end

		if options.OnTabChanged then
			options.OnTabChanged(selectedKey, i)
		end
	end

	controller.Tabs = tabs

	local prev
	for i, def in ipairs(options.Tabs) do
		assert(def.Key and def.Key ~= "", "CreateTabs: each tab needs Key")
		assert(not keyToIndex[def.Key], "CreateTabs: duplicate Key: " .. def.Key)

		-- Flat buttons: no boxes or borders; selection is carried by the accent bar/underline,
		-- a gradient wash, and text color.
		local btn = CreateFrame("Button", nil, strip)
		-- Plain SetHeight/SetPoint (no PixelUtil): pixel-snapping the frame pushed 1px details
		-- off the physical-pixel grid on some pages, making them vanish.
		btn:SetHeight(tabHeight)
		btn.Text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		btn.Text:SetText(def.Title or def.Key)

		-- Hover fill managed by OnEnter/OnLeave rather than a HIGHLIGHT-layer texture:
		-- SetGradient replaces vertex alpha, so SetAlpha can't dim a gradient highlight -
		-- the faintness has to be baked into the gradient colors themselves.
		btn.Highlight = btn:CreateTexture(nil, "BACKGROUND", nil, 2)
		btn.Highlight:SetAllPoints(btn)
		btn.Highlight:Hide()

		btn:SetScript("OnEnter", function()
			if selectedKey ~= def.Key then
				if vertical then
					btn.Text:SetTextColor(1, 1, 1, 1)
				else
					btn.Text:SetTextColor(tabTextHover.r, tabTextHover.g, tabTextHover.b, 1)
				end
				btn.Highlight:Show()
			end
		end)
		btn:SetScript("OnLeave", function()
			if selectedKey ~= def.Key then
				local idle = vertical and tabTextHover or tabTextIdle
				btn.Text:SetTextColor(idle.r, idle.g, idle.b, 1)
			end
			btn.Highlight:Hide()
		end)

		if vertical then
			-- Hover wash fading out to the right, matching the selection wash below.
			GUI.SetGradientH(btn.Highlight, 1, 1, 1, 0.06, 1, 1, 1, 0)

			-- Selection wash: accent gradient fading out to the right.
			btn.Wash = btn:CreateTexture(nil, "BACKGROUND")
			btn.Wash:SetAllPoints(btn)
			GUI.SetGradientH(btn.Wash, accent.r, accent.g, accent.b, 0.20, accent.r, accent.g, accent.b, 0)
			btn.Wash:Hide()

			-- Left-edge accent bar for selected state
			btn.Indicator = btn:CreateTexture(nil, "OVERLAY")
			pixel.SetWidth(btn.Indicator, 3)
			btn.Indicator:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
			btn.Indicator:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
			GUI.SetGradientV(btn.Indicator, accent.r, accent.g, accent.b, 1, accentHi.r, accentHi.g, accentHi.b, 1)
			btn.Indicator:Hide()

			-- Optional icon (spell/interface texture path or fileID), always full color;
			-- selection is carried by the wash and edge bar alone.
			if def.Icon then
				btn.Icon = btn:CreateTexture(nil, "ARTWORK")
				btn.Icon:SetSize(16, 16)
				btn.Icon:SetPoint("LEFT", btn, "LEFT", 10, 0)
				btn.Icon:SetTexture(def.Icon)
				btn.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
				btn.Text:SetPoint("LEFT", btn.Icon, "RIGHT", 8, 0)
			else
				btn.Text:SetPoint("LEFT", btn, "LEFT", 12, 0)
			end

			if not prev then
				btn:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, 0)
				btn:SetPoint("TOPRIGHT", strip, "TOPRIGHT", 0, 0)
			else
				btn:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -tabSpacing)
				btn:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -tabSpacing)
			end
		else
			GUI.SetSolid(btn.Highlight, 1, 1, 1, 0.05)
			btn.Text:SetPoint("CENTER", btn, "CENTER", 0, 0)

			-- Bottom-edge accent underline for selected state; overlays the shared baseline.
			btn.Accent = btn:CreateTexture(nil, "OVERLAY", nil, 1)
			pixel.SetHeight(btn.Accent, 2)
			btn.Accent:SetPoint("BOTTOMLEFT",  btn, "BOTTOMLEFT",  0, 0)
			btn.Accent:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
			GUI.SetGradientH(btn.Accent, accent.r, accent.g, accent.b, 1, accentHi.r, accentHi.g, accentHi.b, 1)
			btn.Accent:Hide()

			SizeToText(btn)

			-- Anchor all buttons to a single shared bottom baseline (the tabs' bottom).
			if not prev then
				btn:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 1)
			else
				btn:SetPoint("BOTTOMLEFT", prev, "BOTTOMRIGHT", tabSpacing, 0)
			end
		end

		prev = btn

		local container, content

		if options.ScrollBody then
			-- Wrapper so scrollFrame + scrollBar hide together when the tab is deselected
			local scrollContainer = CreateFrame("Frame", nil, body)
			scrollContainer:SetAllPoints(body)

			local scrollFrame = CreateFrame("ScrollFrame", nil, scrollContainer)
			scrollFrame:SetPoint("TOPLEFT", scrollContainer, "TOPLEFT", 0, 0)
			scrollFrame:SetPoint("BOTTOMRIGHT", scrollContainer, "BOTTOMRIGHT", -14, 0)
			scrollFrame:EnableMouseWheel(true)
			scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
				local step = 40
				local cur = sf:GetVerticalScroll()
				local maxScroll = sf:GetVerticalScrollRange()
				sf:SetVerticalScroll(delta > 0 and math.max(cur - step, 0) or math.min(cur + step, maxScroll))
			end)

			-- Scroll child must have an explicit size (no anchor points).
			-- SetScrollChild takes ownership of the child's position, so anchors conflict.
			local scrollChild = CreateFrame("Frame", nil, scrollFrame)
			local childWidth = options.ScrollContentWidth or 800
			scrollChild:SetSize(childWidth, options.ScrollContentHeight or 100)
			scrollFrame:SetScrollChild(scrollChild)

			-- Scrollbar, visible only when content overflows
			local scrollBar = CreateFrame("Slider", nil, scrollContainer, GUI.BackdropTemplate)
			scrollBar:SetWidth(10)
			scrollBar:SetPoint("TOPRIGHT", scrollContainer, "TOPRIGHT", 0, -2)
			scrollBar:SetPoint("BOTTOMRIGHT", scrollContainer, "BOTTOMRIGHT", 0, 2)
			scrollBar:SetMinMaxValues(0, 1)
			scrollBar:SetValue(0)
			GUI.TryCall(scrollBar, "SetObeyStepOnDrag", true)
			GUI.ApplyBackdrop(scrollBar, {
				bgFile = "Interface\\Buttons\\WHITE8X8",
				edgeFile = "Interface\\Buttons\\WHITE8X8",
				edgeSize = 1,
			}, 0.10, 0.10, 0.10, 0.6, 0.25, 0.25, 0.25, 0.8)

			local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
			GUI.SetSolid(thumb, 0.55, 0.55, 0.55, 0.85)
			scrollBar:SetThumbTexture(thumb)

			local function UpdateScrollBar()
				local frameH = scrollFrame:GetHeight()
				local childH = scrollChild:GetHeight()
				if frameH == 0 then
					return
				end
				local maxScroll = math.max(0, childH - frameH)
				if maxScroll > 0.5 then
					scrollBar:Show()
					scrollBar:SetMinMaxValues(0, maxScroll)
					scrollBar:SetValue(math.min(scrollFrame:GetVerticalScroll(), maxScroll))
					thumb:SetHeight(math.max(20, scrollBar:GetHeight() * (frameH / childH)))
				else
					scrollBar:Hide()
				end
			end

			scrollBar:SetScript("OnValueChanged", function(_, val)
				scrollFrame:SetVerticalScroll(val)
			end)

			scrollFrame:SetScript("OnScrollRangeChanged", function()
				UpdateScrollBar()
			end)

			scrollFrame:HookScript("OnMouseWheel", function()
				scrollBar:SetValue(scrollFrame:GetVerticalScroll())
			end)

			scrollBar:Hide()

			-- Auto-size scroll child to actual content height on first show.
			-- GetTop/GetBottom require the frame to be on screen, so defer to OnShow.
			-- UpdateScrollBar must be defined before this closure.
			if not options.ScrollContentHeight then
				scrollContainer:SetScript("OnShow", function(scrollSelf)
					scrollSelf:SetScript("OnShow", nil)
					local top = scrollChild:GetTop()
					if not top then
						return
					end
					local minBottom = top
					for _, child in ipairs({ scrollChild:GetChildren() }) do
						local b = child:GetBottom()
						if b and b < minBottom then
							minBottom = b
						end
					end
					local needed = math.ceil(top - minBottom) + 20
					scrollChild:SetHeight(math.max(needed, scrollFrame:GetHeight()))
					UpdateScrollBar()
				end)
			end

			container = scrollContainer
			content = scrollChild
		else
			local contentFrame = CreateFrame("Frame", nil, body)
			contentFrame:SetAllPoints(body)
			container = contentFrame
			content = contentFrame
		end

		container:Hide()

		local tab =
			{ Key = def.Key, Title = def.Title or def.Key, Button = btn, Content = content, Container = container }
		tabs[i] = tab
		keyToIndex[def.Key] = i

		btn:SetScript("OnClick", function()
			controller:Select(i)
		end)

		if type(def.Build) == "function" then
			def.Build(content)
		end
	end

	lastBtn = tabs[#tabs] and tabs[#tabs].Button

	-- Vertical buttons span the full strip width, so the last button's corner is exactly
	-- where the separator should stop.
	if vLine and lastBtn then
		pixel.SetPoint(vLine, "BOTTOMRIGHT", lastBtn, "BOTTOMRIGHT", 0, 0)
	end

	-- Horizontal baseline sits at the buttons' shared bottom edge, full strip width.
	if not vertical then
		pixel.SetPoint(baseline, "BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 1)
		pixel.SetPoint(baseline, "BOTTOMRIGHT", strip, "BOTTOMRIGHT", 0, 1)
	end

	local initialIndex = 1
	if options.InitialKey and keyToIndex[options.InitialKey] then
		initialIndex = keyToIndex[options.InitialKey]
	end

	for i = 1, #tabs do
		local isSel = (i == initialIndex)
		GUI.SetShown(tabs[i].Container, isSel)
		SetSelected(tabs[i].Button, isSel)
	end
	selectedKey = tabs[initialIndex].Key

	if options.OnTabChanged then
		options.OnTabChanged(selectedKey, initialIndex)
	end

	if options.TabFitToParent then
		if vertical then
			local function DistributeTabs(h)
				if h == 0 or #tabs == 0 then
					return
				end
				local btnH = math.floor((h - tabSpacing * (#tabs - 1)) / #tabs)
				for _, tab in ipairs(tabs) do
					tab.Button:SetHeight(math.max(16, btnH))
				end
			end
			strip:SetScript("OnSizeChanged", function(_, _, h)
				DistributeTabs(h)
			end)
			local h = strip:GetHeight()
			if h and h > 0 then
				DistributeTabs(h)
			end
		else
			local function DistributeTabs(w)
				if w == 0 or #tabs == 0 then
					return
				end
				local available = w - tabSpacing * (#tabs - 1)
				local btnW = math.floor(available / #tabs)
				local remainder = available - btnW * #tabs
				for i, tab in ipairs(tabs) do
					tab.Button:SetWidth(i == #tabs and btnW + remainder or btnW)
				end
			end
			strip:SetScript("OnSizeChanged", function(s, w)
				DistributeTabs(w)
			end)
			local w = strip:GetWidth()
			if w and w > 0 then
				DistributeTabs(w)
			end
		end
	end

	return controller
end

---@class Tab
---@field Key string
---@field Title string
---@field Build? fun(content:table)
---@field Icon? string|number Icon texture path or fileID, shown left of the title (vertical tabs only)

---@class TabOptions
---@field Parent table
---@field Tabs Tab[]
---@field InitialKey? string
---@field Vertical? boolean  Render the strip as a left sidebar instead of a horizontal bar
---@field TabHeight? number
---@field TabMinWidth? number
---@field TabSpacing? number
---@field StripHeight? number  Height of a horizontal strip
---@field StripWidth? number   Width of a vertical strip (default 130)
---@field HorizontalPadding? number  Inset applied to each side of the strip
---@field ContentInsets? table
---@field OnTabChanged? fun(key:string, index:number)
---@field ScrollBody? boolean  Wrap each tab content in a scroll frame
---@field ScrollContentHeight? number  Height of the scroll child (default 1400)
---@field ScrollContentWidth? number   Explicit width of the scroll child (default 800)
---@field TabFitToParent? boolean  Distribute tab buttons evenly across the strip width

---@class TabReturn
---@field Select fun(keyOrIndex: string|number)
---@field GetSelected fun(): string
---@field GetContent fun(self: table, keyOrIndex: string|number): table?
---@field GetTabButton fun(self: table, keyOrIndex: string|number): table?
---@field Tabs Tab[]

---@class Insets
---@field Top number?
---@field Left number?
---@field Right number?
---@field Bottom number?
