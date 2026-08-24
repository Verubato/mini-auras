---@type string, Addon
local _, addon = ...

local iconUtil = addon.Utils.IconUtil
local fontUtil = addon.Utils.FontUtil

addon.Modules.AllyKickTracker = addon.Modules.AllyKickTracker or {}

-- Resolved from the client's own font object on first layout. Non-Latin locales substitute a
-- file that actually has their glyphs, where a hardcoded western Friz Quadrata renders boxes.
local fontFile
local FONT_FLAGS = "OUTLINE"
-- Everything inside a bar is derived from its height, so one slider sizes the whole row.
local NAME_FONT_COEFFICIENT = 0.42
local COUNTDOWN_FONT_SCALE = 1.25
local ICON_PADDING_FACTOR = 1 / 10
local TEXT_INSET = 4
-- Below this the countdown reads better with a decimal. It is the same threshold the icon
-- cooldowns use for their own millisecond text.
local MILLISECONDS_THRESHOLD = 3
-- The raid marker sheet is 4x4, indexed the same way the raid target indices run.
local MARKER_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"
local MARKER_SHEET_COLUMNS = 4
local MARKER_SHEET_ROWS = 4

-- Fill colour for a kicker whose class did not resolve, or when class colouring is off.
local NEUTRAL_FILL = { 0.35, 0.45, 0.6 }

---@class AllyKickDisplay
local M = {}
addon.Modules.AllyKickTracker.Display = M

---@param seconds number
---@return string
local function CountdownText(seconds)
	if seconds < MILLISECONDS_THRESHOLD then
		return string.format("%.1f", seconds)
	end

	return tostring(math.ceil(seconds))
end

---The kicker's class colour. The class token is secret inside an instance and a table cannot be
---keyed by a secret, so the colour comes from the API call, which takes one. The colour handed
---back is itself secret, which the status bar's setter accepts and arithmetic on it does not.
---@param class string?
---@return table?
local function ClassColor(class)
	if class == nil then
		return nil
	end

	if C_ClassColor and C_ClassColor.GetClassColor then
		return C_ClassColor.GetClassColor(class)
	end

	-- Nothing but an old client gets here, where the token is never secret to begin with.
	if issecretvalue(class) then
		return nil
	end

	return RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] or nil
end

---Paints a raid marker onto a texture. The index is secret inside an instance, and the FrameXML
---helper works out its tex coords arithmetically, which throws on one. The sprite-sheet setter
---hands the index straight to the C side instead, so it is preferred wherever the client has it.
---@param texture table
---@param index number?
---@return boolean painted
local function PaintMarker(texture, index)
	if index == nil then
		return false
	end

	if texture.SetSpriteSheetCell then
		texture:SetTexture(MARKER_TEXTURE)
		texture:SetSpriteSheetCell(index, MARKER_SHEET_COLUMNS, MARKER_SHEET_ROWS)

		return true
	end

	-- Nothing but an old client gets here, where the index is never secret to begin with.
	if issecretvalue(index) then
		return false
	end

	SetRaidTargetIconTexture(texture, index)

	return true
end

---@param bar AllyKickBar
---@param options AllyKickDisplayOptions
local function LayoutBar(bar, options)
	local height = options.Height
	local padding = math.max(1, math.floor(height * ICON_PADDING_FACTOR))
	-- The marker keeps its column whether or not this row has one to show, so one appearing never
	-- shoves everything else sideways.
	local markerWidth = height + padding

	bar.Frame:SetSize(options.Width, height)

	bar.Marker:ClearAllPoints()
	bar.Marker:SetPoint("TOPLEFT", bar.Frame, "TOPLEFT", 0, 0)
	bar.Marker:SetSize(height, height)

	-- Flush against the fill so the icon reads as the bar's own head.
	bar.Icon:ClearAllPoints()
	bar.Icon:SetPoint("TOPLEFT", bar.Frame, "TOPLEFT", markerWidth, 0)
	bar.Icon:SetSize(height, height)
	-- Icon art carries a transparent border. Trimming it by the same amount the config previews do
	-- squares the icon up with the bar's edges.
	bar.Icon:SetTexCoord(iconUtil:TexCoord())

	bar.Bar:ClearAllPoints()
	bar.Bar:SetPoint("TOPLEFT", bar.Frame, "TOPLEFT", markerWidth + height, 0)
	bar.Bar:SetPoint("BOTTOMRIGHT", bar.Frame, "BOTTOMRIGHT", 0, 0)
	bar.Bar:SetStatusBarTexture(options.FillTexture)

	local nameSize = math.max(6, math.floor(height * NAME_FONT_COEFFICIENT * (options.FontScale or 1)))

	fontFile = fontFile or (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"

	fontUtil:Apply(bar.Name, nameSize, FONT_FLAGS, fontFile)
	fontUtil:Apply(bar.Time, math.floor(nameSize * COUNTDOWN_FONT_SCALE), FONT_FLAGS, fontFile)
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
	-- and steps negative, so the anchor stays put whichever way the rows run.
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

---Paints everything about a row that does not move: the kicker's name and class colour, the
---interrupted spell's icon and the mob's marker. All four can be secret, so this runs once when
---the row is assigned. The repaint loop compares what it last pushed to a widget, and comparing
---a secret is not allowed.
---@param bar AllyKickBar
---@param record AllyKickRecord
local function PaintRecord(bar, record)
	bar.Icon:SetTexture(record.Icon)
	bar.Name:SetText(record.Name)

	bar.Marker:SetShown(PaintMarker(bar.Marker, record.Marker))

	local color = ClassColor(record.Class)

	if color then
		bar.Bar:SetStatusBarColor(color.r, color.g, color.b)
	else
		bar.Bar:SetStatusBarColor(NEUTRAL_FILL[1], NEUTRAL_FILL[2], NEUTRAL_FILL[3])
	end

	wipe(bar.Applied)
end

---Repaints the part of a row that does move. Both numbers here are the display's own, so unlike
---everything in PaintRecord they can be compared freely.
---@param instance AllyKickDisplayInstance
---@param bar AllyKickBar
---@param record AllyKickRecord
---@param now number
local function RenderTimer(instance, bar, record, now)
	local remaining = record.ExpireAt - now

	if remaining <= 0 then
		-- Only the player's own row gets here, since a history row leaves the list the moment it
		-- expires. A ready row is static, so it is painted once and then left alone.
		if bar.Applied.Countdown ~= false then
			bar.Bar:SetValue(1)
			bar.Time:SetText(instance.ReadyLabel)
			bar.Applied.Countdown = false
		end

		return
	end

	bar.Bar:SetValue(remaining / record.Duration)

	-- The text is compared as the number it will render as, so the string is only built on the
	-- ticks where it actually changes.
	local countdown = remaining < MILLISECONDS_THRESHOLD and math.floor(remaining * 10) or math.ceil(remaining)

	if bar.Applied.Countdown ~= countdown then
		bar.Time:SetText(CountdownText(remaining))
		bar.Applied.Countdown = countdown
	end
end

---Creates a row list. The instance owns its frame, and the caller positions and shows it.
---@param parent table
---@param readyLabel string  shown instead of a countdown once the player's own interrupt is up
---@return AllyKickDisplayInstance
function M:New(parent, readyLabel)
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetClampedToScreen(true)
	frame:SetSize(1, 1)

	---@type AllyKickDisplayInstance
	local instance = {
		Frame = frame,
		Bars = {},
		Records = {},
		BarCount = 0,
		ReadyLabel = readyLabel,
		Options = {
			Width = 260,
			Height = 35,
			Spacing = 2,
			Grow = "DOWN",
			FillTexture = "Interface\\TargetingFrame\\UI-StatusBar",
		},
	}

	return setmetatable(instance, { __index = M })
end

---@param options AllyKickDisplayOptions
function M:SetOptions(options)
	for key, value in pairs(options) do
		self.Options[key] = value
	end

	for index = 1, self.BarCount do
		LayoutBar(self.Bars[index], self.Options)
		-- Geometry and the fill texture both reset what the row was showing, so its record is
		-- painted back on rather than left half-applied.
		PaintRecord(self.Bars[index], self.Records[index])
	end

	Arrange(self, self.BarCount)
	self:Update()
end

---Assigns records to rows. They are rendered in the order given, so any sorting is the caller's
---to do.
---@param records AllyKickRecord[]
function M:SetRecords(records)
	local previousCount = self.BarCount

	self.Records = records
	self.BarCount = #records

	for index = 1, self.BarCount do
		local bar = GetBar(self, index)

		if index > previousCount then
			LayoutBar(bar, self.Options)
		end

		-- Which record sits on which row moves as rows expire, so every one is repainted rather
		-- than only the newly built ones.
		PaintRecord(bar, records[index])
		bar.Frame:Show()
	end

	for index = self.BarCount + 1, #self.Bars do
		self.Bars[index].Frame:Hide()
	end

	Arrange(self, self.BarCount)
	self:Update()
end

---Repaints every row's countdown.
function M:Update()
	local now = GetTime()

	for index = 1, self.BarCount do
		RenderTimer(self, self.Bars[index], self.Records[index], now)
	end
end

---@class AllyKickBar
---@field Frame table
---@field Icon table
---@field Marker table
---@field Bar table
---@field Name table
---@field Time table
---@field Applied table  the countdown last pushed to the widget, so a repaint only touches changes

---@class AllyKickDisplayOptions
---@field Width number
---@field Height number
---@field Spacing number  pixels between one row and the next
---@field Grow string  "DOWN" or "UP"
---@field FillTexture string  texture path for the bar fill
---@field FontScale number?  multiplier on both text sizes

---@class AllyKickDisplayInstance
---@field Frame table
---@field Bars AllyKickBar[]
---@field Records AllyKickRecord[]
---@field BarCount number
---@field ReadyLabel string
---@field Options AllyKickDisplayOptions
---@field SetOptions fun(self: AllyKickDisplayInstance, options: table)
---@field SetRecords fun(self: AllyKickDisplayInstance, records: AllyKickRecord[])
---@field Update fun(self: AllyKickDisplayInstance)
