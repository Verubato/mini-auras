local _, addon = ...
local M = addon.Framework
local GUI = M.GUI
local pixel = GUI.Pixel

---Blizzard icons carry a baked border that the standard 0.08 crop trims away;
---an addon's own textures are full-bleed art and render uncropped.
local function SetTabIcon(texture, icon)
	texture:SetTexture(icon)

	if type(icon) == "number" or not icon:find("AddOns", 1, true) then
		texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
end

---@param options TabOptions
---@return TabReturn
function M:CreateTabs(options)
	assert(options and options.Parent, "CreateTabs: options.Parent required")
	assert(options.Tabs and #options.Tabs > 0, "CreateTabs: options.Tabs required")

	local accent = GUI.Accent
	local accentHi = GUI.AccentHi
	local tabTextIdle = GUI.TabTextIdle
	local tabTextHover = GUI.TabTextHover
	local tabTextSelected = GUI.TabTextSelected
	local tabTextBright = GUI.TabTextBright
	local dividerGold = GUI.DividerGold
	local dividerLine = GUI.DividerLine

	local parent = options.Parent
	local vertical = options.Vertical
	local tabHeight = options.TabHeight or 22
	-- Nav icon edge; a size above the row height simply overflows it, which reads fine for
	-- the round addon art.
	local tabIconSize = options.TabIconSize or 20
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
	GUI.SetSolid(baseline, 1, 1, 1, vertical and 0.10 or 0.15)

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
			btn.Text:SetTextColor(tabTextSelected.r, tabTextSelected.g, tabTextSelected.b, 1)
			btn.Highlight:Hide()

			if btn.Wash then btn.Wash:Show() end

			if vertical then
				if btn.Indicator then btn.Indicator:Show() end
			else
				if btn.Accent then btn.Accent:Show() end
			end
		else
			local idle = vertical and tabTextHover or tabTextIdle
			btn.Text:SetTextColor(idle.r, idle.g, idle.b, 1)

			if btn.Wash then btn.Wash:Hide() end

			if vertical then
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
	-- The strip frame itself, so callers can hang a footer in space held back by FooterReserve.
	controller.Strip = strip

	-- A def of { Separator = true } draws a grouping line before the NEXT tab instead of a
	-- button, and { Heading = "Title" } draws a gold section label in the panel-divider style.
	-- Filtered out here so the button loop, the key index and the content list only ever see
	-- real tabs; horizontal strips ignore both entirely.
	local defs = {}
	local separatorBefore = {}
	for _, def in ipairs(options.Tabs) do
		if def.Separator or def.Heading then
			separatorBefore[#defs + 1] = def.Heading or true
		else
			defs[#defs + 1] = def
		end
	end

	-- Height the separators and headings add over plain button-to-button spacing, so
	-- TabFitToParent can hand out only what is actually left for the buttons.
	local decorationHeight = 0

	---Builds a section heading: the panel divider's gold label at strip size, with the tail
	---fading out toward the right edge. Anchored below anchorTo, or to the strip top for a
	---heading that opens the list. Returns the frame the next button anchors to.
	local function CreateHeading(title, anchorTo)
		local head = CreateFrame("Frame", nil, strip)
		head:SetHeight(18)

		if anchorTo then
			head:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -tabSpacing - 4)
			head:SetPoint("TOPRIGHT", anchorTo, "BOTTOMRIGHT", 0, -tabSpacing - 4)
			decorationHeight = decorationHeight + 24
		else
			head:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, 0)
			head:SetPoint("TOPRIGHT", strip, "TOPRIGHT", 0, 0)
			decorationHeight = decorationHeight + 20
		end

		local label = head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetText(tostring(title):upper())
		label:SetTextColor(dividerGold.r, dividerGold.g, dividerGold.b, 1)
		label:SetPoint("BOTTOMLEFT", head, "BOTTOMLEFT", 10, 2)

		local tail = head:CreateTexture(nil, "OVERLAY")
		pixel.SetHeight(tail, 1)
		GUI.SetGradientH(tail, dividerLine.r, dividerLine.g, dividerLine.b, 0.6,
			dividerLine.r, dividerLine.g, dividerLine.b, 0)
		pixel.SetPoint(tail, "LEFT", label, "RIGHT", 8, -1)
		pixel.SetPoint(tail, "RIGHT", head, "RIGHT", -8, -1)

		return head
	end

	local prev
	for i, def in ipairs(defs) do
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
					btn.Text:SetTextColor(tabTextBright.r, tabTextBright.g, tabTextBright.b, 1)
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
				btn.Icon:SetSize(tabIconSize, tabIconSize)
				btn.Icon:SetPoint("LEFT", btn, "LEFT", 8, 0)
				SetTabIcon(btn.Icon, def.Icon)
				btn.Text:SetPoint("LEFT", btn.Icon, "RIGHT", 8, 0)
			else
				btn.Text:SetPoint("LEFT", btn, "LEFT", 12, 0)
			end

			local heading = type(separatorBefore[i]) == "string" and separatorBefore[i] or nil

			if heading then
				local head = CreateHeading(heading, prev)
				btn:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -2)
				btn:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", 0, -2)
			elseif not prev then
				btn:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, 0)
				btn:SetPoint("TOPRIGHT", strip, "TOPRIGHT", 0, 0)
			elseif separatorBefore[i] then
				-- Inset from both edges so it reads as a grouping line, not a border. The
				-- button undoes the inset to get back to the strip's full width.
				local line = strip:CreateTexture(nil, "OVERLAY")
				pixel.SetHeight(line, 1)
				GUI.SetSolid(line, 1, 1, 1, 0.10)
				line:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 8, -tabSpacing - 4)
				line:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", -8, -tabSpacing - 4)
				btn:SetPoint("TOPLEFT", line, "BOTTOMLEFT", -8, -tabSpacing - 4)
				btn:SetPoint("TOPRIGHT", line, "BOTTOMRIGHT", 8, -tabSpacing - 4)
				decorationHeight = decorationHeight + tabSpacing + 9
			else
				btn:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -tabSpacing)
				btn:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -tabSpacing)
			end
		else
			GUI.SetSolid(btn.Highlight, 1, 1, 1, 0.05)
			btn.Text:SetPoint("CENTER", btn, "CENTER", 0, 0)

			-- A faint plate under every tab: bare labels over the page read as text, not as a
			-- control, and users were missing the strip entirely.
			btn.Plate = btn:CreateTexture(nil, "BACKGROUND", nil, 1)
			btn.Plate:SetAllPoints(btn)
			GUI.SetSolid(btn.Plate, 1, 1, 1, 0.06)

			-- Selection wash rising from the underline, matching the vertical sidebar's wash, so
			-- the active tab is marked by more than text color.
			btn.Wash = btn:CreateTexture(nil, "BACKGROUND", nil, 3)
			btn.Wash:SetAllPoints(btn)
			GUI.SetGradientV(btn.Wash, accent.r, accent.g, accent.b, 0.30, accent.r, accent.g, accent.b, 0)
			btn.Wash:Hide()

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

			-- Fixed page header above the scroll area: the tab's icon and title anchor the page
			-- and never scroll away with it. The panel's own content flows underneath.
			local headerOffset = 0
			if options.PageHeader and def.Title and def.PageHeader ~= false then
				local header = CreateFrame("Frame", nil, scrollContainer)
				header:SetHeight(30)
				header:SetPoint("TOPLEFT", scrollContainer, "TOPLEFT", 0, 0)
				header:SetPoint("TOPRIGHT", scrollContainer, "TOPRIGHT", -14, 0)

				local headerIcon
				if def.Icon then
					headerIcon = header:CreateTexture(nil, "ARTWORK")
					headerIcon:SetSize(26, 26)
					headerIcon:SetPoint("LEFT", header, "LEFT", 0, 2)
					SetTabIcon(headerIcon, def.Icon)
				end

				local headerTitle = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
				if headerIcon then
					headerTitle:SetPoint("LEFT", headerIcon, "RIGHT", 8, 0)
				else
					headerTitle:SetPoint("LEFT", header, "LEFT", 0, 2)
				end
				-- The section dividers' muted gold, so the page title and the dividers under it
				-- read as one family.
				headerTitle:SetText(def.Title)
				headerTitle:SetTextColor(dividerGold.r, dividerGold.g, dividerGold.b, 1)

				headerOffset = 30 + 10
			end

			-- The one scroll range the wheel and the scrollbar both clamp against. The engine's
			-- GetVerticalScrollRange lags behind scroll-child resizes, so trusting it would let
			-- the wheel scroll a page whose scrollbar is hidden.
			local maxScroll = 0

			local scrollFrame = CreateFrame("ScrollFrame", nil, scrollContainer)
			scrollFrame:SetPoint("TOPLEFT", scrollContainer, "TOPLEFT", 0, -headerOffset)
			scrollFrame:SetPoint("BOTTOMRIGHT", scrollContainer, "BOTTOMRIGHT", -14, 0)
			scrollFrame:EnableMouseWheel(true)
			scrollFrame:SetScript("OnMouseWheel", function(sf, delta)
				local step = 40
				local cur = sf:GetVerticalScroll()
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
			scrollBar:SetOrientation("VERTICAL")
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

			-- A vertical slider's minimum sits at its TOP, exactly like the scroll offset, so the
			-- two map onto each other directly; Blizzard's own scrollbars feed SetVerticalScroll
			-- the raw slider value the same way.

			---@param scroll number
			---@return number
			local function ScrollToValue(scroll)
				return math.min(math.max(scroll, 0), maxScroll)
			end

			local function UpdateScrollBar()
				local frameH = scrollFrame:GetHeight()
				local childH = scrollChild:GetHeight()
				if frameH == 0 then
					return
				end
				maxScroll = math.max(0, childH - frameH)
				if maxScroll > 0.5 then
					scrollBar:Show()
					scrollBar:SetMinMaxValues(0, maxScroll)
					scrollBar:SetValue(ScrollToValue(scrollFrame:GetVerticalScroll()))
					thumb:SetHeight(math.max(20, scrollBar:GetHeight() * (frameH / childH)))
				else
					scrollBar:Hide()
					scrollFrame:SetVerticalScroll(0)
				end
			end

			scrollBar:SetScript("OnValueChanged", function(_, val)
				scrollFrame:SetVerticalScroll(val)
			end)

			scrollFrame:SetScript("OnScrollRangeChanged", function()
				UpdateScrollBar()
			end)

			scrollFrame:HookScript("OnMouseWheel", function()
				scrollBar:SetValue(ScrollToValue(scrollFrame:GetVerticalScroll()))
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
					local contentHeight = math.ceil(top - minBottom)
					local frameHeight = scrollFrame:GetHeight()

					-- Bottom margin only when the page scrolls anyway; adding it to a page
					-- that fits would itself create the scrollbar.
					if contentHeight > frameHeight then
						scrollChild:SetHeight(contentHeight + 20)
					else
						scrollChild:SetHeight(frameHeight)
					end
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
				local reserved = decorationHeight + (options.FooterReserve or 0)
				local btnH = math.floor((h - reserved - tabSpacing * (#tabs - 1)) / #tabs)
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
---@field TabIconSize? number  Vertical nav icon size, default 20
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
---@field PageHeader? boolean  ScrollBody only: fixed icon + title band above each page's scroll area. A tab def may opt out with PageHeader = false.
---@field FooterReserve? number  Vertical strips only: height held back from TabFitToParent for a caller footer

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
