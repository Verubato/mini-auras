---@type string, Addon
local _, addon = ...

addon.Modules.AllyKicks = addon.Modules.AllyKicks or {}

local FONT_FILE = "Fonts\\FRIZQT__.TTF"
local FONT_FLAGS = "OUTLINE"
-- Everything inside a bar is derived from its height, so one slider sizes the whole thing: the
-- name font is a fraction of it, the countdown is a touch larger again, and the icon column is
-- the height itself plus a hair of padding.
local NAME_FONT_COEFFICIENT = 0.42
local COUNTDOWN_FONT_SCALE = 1.25
local ICON_PADDING_FACTOR = 1 / 10
local TEXT_INSET = 4
-- Icon art carries a transparent border; trimming it by the same amount the config previews do
-- squares the icon up with the bar's edges.
local ICON_TRIM = 0.08
-- Below this the countdown reads better with a decimal, above it whole seconds are enough - the
-- same threshold the icon cooldowns use for their own millisecond text.
local MILLISECONDS_THRESHOLD = 3

-- Fill colour for a member whose class is unknown, or when class colouring is switched off.
local NEUTRAL_FILL = { 0.35, 0.45, 0.6 }

---@class AllyKickDisplay
local M = {}
addon.Modules.AllyKicks.Display = M

---@param seconds number
---@return string
local function CountdownText(seconds)
	if seconds < MILLISECONDS_THRESHOLD then
		return string.format("%.1f", seconds)
	end

	return tostring(math.ceil(seconds))
end

---@param bar AllyKickBar
---@param options AllyKickDisplayOptions
local function LayoutBar(bar, options)
	local height = options.Height
	local padding = math.max(1, math.floor(height * ICON_PADDING_FACTOR))
	local iconSize = options.ShowIcon and height or 0
	-- Flush against the fill: the icon reads as the bar's own head rather than a separate thing.
	local iconWidth = iconSize
	-- The marker keeps its column whether or not this particular bar has one to show, so one
	-- appearing mid-cooldown never shoves everything else sideways. It leads the row rather than
	-- sitting between the icon and the bar, so an empty column falls outside the pair and the
	-- spell icon stays flush against the fill it belongs to.
	local markerSize = options.ShowRaidTarget and height or 0
	local markerWidth = markerSize > 0 and (markerSize + padding) or 0

	bar.Frame:SetSize(options.Width, height)

	bar.Marker:ClearAllPoints()
	bar.Marker:SetPoint("TOPLEFT", bar.Frame, "TOPLEFT", 0, 0)
	bar.Marker:SetSize(markerSize, markerSize)

	bar.Icon:ClearAllPoints()
	bar.Icon:SetPoint("TOPLEFT", bar.Frame, "TOPLEFT", markerWidth, 0)
	bar.Icon:SetShown(options.ShowIcon)
	bar.Icon:SetSize(iconSize, iconSize)
	bar.Icon:SetTexCoord(ICON_TRIM, 1 - ICON_TRIM, ICON_TRIM, 1 - ICON_TRIM)

	bar.Bar:ClearAllPoints()
	bar.Bar:SetPoint("TOPLEFT", bar.Frame, "TOPLEFT", markerWidth + iconWidth, 0)
	bar.Bar:SetPoint("BOTTOMRIGHT", bar.Frame, "BOTTOMRIGHT", 0, 0)
	bar.Bar:SetStatusBarTexture(options.FillTexture)
	-- SetStatusBarTexture replaces the texture object, so the fill colour goes with it.
	wipe(bar.Applied)

	local nameSize = math.max(6, math.floor(height * NAME_FONT_COEFFICIENT))

	bar.Name:SetFont(FONT_FILE, nameSize, FONT_FLAGS)
	bar.Time:SetFont(FONT_FILE, math.floor(nameSize * COUNTDOWN_FONT_SCALE), FONT_FLAGS)
end

---@param parent table
---@return AllyKickBar
local function CreateBar(parent)
	local frame = CreateFrame("Frame", nil, parent)

	-- Both are anchored by LayoutBar, which is where the column widths are worked out.
	local icon = frame:CreateTexture(nil, "ARTWORK")

	local marker = frame:CreateTexture(nil, "ARTWORK")
	marker:Hide()

	local statusBar = CreateFrame("StatusBar", nil, frame)
	statusBar:SetMinMaxValues(0, 1)
	statusBar:SetValue(1)

	local background = statusBar:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(0, 0, 0, 0.6)

	local name = statusBar:CreateFontString(nil, "OVERLAY")
	name:SetPoint("LEFT", statusBar, "LEFT", TEXT_INSET, 0)
	name:SetJustifyH("LEFT")
	-- The class colour is carried by the fill behind it, so the text stays white and readable
	-- over every one of them.
	name:SetTextColor(1, 1, 1)

	local time = statusBar:CreateFontString(nil, "OVERLAY")
	time:SetPoint("RIGHT", statusBar, "RIGHT", -TEXT_INSET, 0)
	time:SetJustifyH("RIGHT")

	-- The name is what gets squeezed when a bar is narrow, so it gives way to the countdown
	-- rather than running underneath it.
	name:SetPoint("RIGHT", time, "LEFT", -TEXT_INSET, 0)
	name:SetWordWrap(false)

	---@type AllyKickBar
	return {
		Frame = frame,
		Icon = icon,
		Marker = marker,
		Bar = statusBar,
		Name = name,
		Time = time,
		Applied = {},
	}
end

---@param instance AllyKickDisplayInstance
---@param index number
---@return AllyKickBar
local function GetBar(instance, index)
	local bar = instance.Bars[index]

	if not bar then
		bar = CreateBar(instance.Frame)
		instance.Bars[index] = bar
	end

	return bar
end

---Stacks the visible bars from the anchor, in the configured direction.
---@param instance AllyKickDisplayInstance
---@param barCount number
local function Arrange(instance, barCount)
	local options = instance.Options
	local step = options.Height + options.Spacing
	-- Stacking up hangs the list off its bottom edge and steps positive, down off the top edge
	-- and steps negative, so the anchor stays put whichever way the bars run.
	local upward = options.Grow == "UP"
	local edge = upward and "BOTTOMLEFT" or "TOPLEFT"
	local direction = upward and 1 or -1

	for index = 1, barCount do
		local bar = instance.Bars[index]

		bar.Frame:ClearAllPoints()
		bar.Frame:SetPoint(edge, instance.Frame, edge, 0, (index - 1) * step * direction)
	end

	local height = barCount > 0 and (barCount * options.Height + (barCount - 1) * options.Spacing) or 1

	instance.Frame:SetSize(options.Width, height)
end

---Repaints one bar. This runs for every bar on every tick of the refresh loop, so each widget
---call is guarded by a comparison first: only the fill and the countdown text actually move
---while a cooldown runs, and a redundant SetText re-lays-out the font string for nothing.
---@param instance AllyKickDisplayInstance
---@param bar AllyKickBar
---@param entry AllyKickEntry
---@param now number
local function RenderBar(instance, bar, entry, now)
	local options = instance.Options
	local applied = bar.Applied
	local duration = entry.Duration or entry.Cooldown
	local remaining = entry.StartTime > 0 and (entry.StartTime + duration - now) or 0

	if applied.Texture ~= entry.Texture then
		bar.Icon:SetTexture(entry.Texture)
		applied.Texture = entry.Texture
	end

	if applied.Name ~= entry.Name then
		bar.Name:SetText(entry.Name)
		applied.Name = entry.Name
	end

	-- The marker only means anything while the cooldown it was captured with is running.
	local marker = options.ShowRaidTarget and remaining > 0 and entry.Marker or false

	if applied.Marker ~= marker then
		if marker then
			SetRaidTargetIconTexture(bar.Marker, marker)
		end

		bar.Marker:SetShown(marker and true or false)
		applied.Marker = marker
	end

	-- The class colour is the whole point of the fill; the neutral one is only for a member
	-- whose class could not be read, which 12.1 makes possible inside a match.
	local classColor = entry.Class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.Class] or nil
	-- Full strength in both states. How much of the bar is left, and the number on it, are what
	-- say whether the interrupt is up; nothing is dimmed, desaturated or faded to repeat it.
	local ready = remaining <= 0
	local fillR = classColor and classColor.r or NEUTRAL_FILL[1]
	local fillG = classColor and classColor.g or NEUTRAL_FILL[2]
	local fillB = classColor and classColor.b or NEUTRAL_FILL[3]

	if applied.FillR ~= fillR or applied.FillG ~= fillG or applied.FillB ~= fillB then
		bar.Bar:SetStatusBarColor(fillR, fillG, fillB)
		applied.FillR, applied.FillG, applied.FillB = fillR, fillG, fillB
	end

	if ready then
		-- A ready bar is completely static, so it is painted once and then left alone.
		if applied.Ready ~= true then
			bar.Bar:SetValue(1)
			bar.Time:SetText(instance.ReadyLabel)
			applied.Ready = true
			applied.Countdown = false
		end

		return
	end

	applied.Ready = false

	bar.Bar:SetValue(remaining / duration)

	-- The text is compared as the number it will render as, not as the string: whole seconds
	-- above the threshold and tenths below it. That way the string is only ever built on the
	-- ticks where it actually changes, which is once a second for most of a cooldown.
	local countdown = remaining < MILLISECONDS_THRESHOLD and math.floor(remaining * 10) or math.ceil(remaining)

	if applied.Countdown ~= countdown then
		bar.Time:SetText(CountdownText(remaining))
		applied.Countdown = countdown
	end
end

---Creates a bar list. The instance owns its frame; the caller positions and shows it.
---@param parent table
---@param readyLabel string
---@return AllyKickDisplayInstance
function M:New(parent, readyLabel)
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetClampedToScreen(true)
	frame:SetSize(1, 1)

	---@type AllyKickDisplayInstance
	local instance = {
		Frame = frame,
		Bars = {},
		Entries = {},
		BarCount = 0,
		ReadyLabel = readyLabel,
		Options = {
			Width = 260,
			Height = 35,
			Spacing = 2,
			Grow = "DOWN",
			FillTexture = "Interface\\TargetingFrame\\UI-StatusBar",
			ShowIcon = true,
			ShowRaidTarget = true,
		},
	}

	return setmetatable(instance, { __index = M })
end

---@param options AllyKickDisplayOptions
function M:SetOptions(options)
	for key, value in pairs(options) do
		self.Options[key] = value
	end

	-- Colours and alpha come from the options, so what each bar last applied is now unknown.
	for index = 1, #self.Bars do
		wipe(self.Bars[index].Applied)
	end

	for index = 1, self.BarCount do
		LayoutBar(self.Bars[index], self.Options)
	end

	Arrange(self, self.BarCount)
end

---Assigns entries to bars. Entries are rendered in the order given, so any sorting is the
---caller's to do.
---@param entries AllyKickEntry[]
function M:SetEntries(entries)
	local previousCount = self.BarCount

	self.Entries = entries
	self.BarCount = #entries

	for index = 1, self.BarCount do
		local bar = GetBar(self, index)

		if index > previousCount then
			LayoutBar(bar, self.Options)
		end

		bar.Frame:Show()
	end

	for index = self.BarCount + 1, #self.Bars do
		self.Bars[index].Frame:Hide()
	end

	Arrange(self, self.BarCount)
	self:Update()
end

---Repaints every bar from its entry's current cooldown state.
function M:Update()
	local now = GetTime()

	for index = 1, self.BarCount do
		RenderBar(self, self.Bars[index], self.Entries[index], now)
	end
end

---@class AllyKickBar
---@field Frame table
---@field Icon table
---@field Marker table
---@field Bar table
---@field Name table
---@field Time table
---@field Applied table  what was last pushed to the widgets, so a repaint only touches changes

---@class AllyKickDisplayOptions
---@field Width number
---@field Height number
---@field Spacing number  pixels between one bar and the next
---@field Grow string  "DOWN" or "UP"
---@field FillTexture string  texture path for the bar fill
---@field ShowIcon boolean
---@field ShowRaidTarget boolean  reserve a column for the interrupted target's raid marker

---@class AllyKickDisplayInstance
---@field Frame table
---@field Bars AllyKickBar[]
---@field Entries AllyKickEntry[]
---@field BarCount number
---@field ReadyLabel string
---@field Options AllyKickDisplayOptions
---@field SetOptions fun(self: AllyKickDisplayInstance, options: table)
---@field SetEntries fun(self: AllyKickDisplayInstance, entries: AllyKickEntry[])
---@field Update fun(self: AllyKickDisplayInstance)
