---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx
local fontUtil = addon.Utils.FontUtil
local iconUtil = addon.Utils.IconUtil
local barTextures = addon.Core.BarTextures
local outline = addon.Core.Outline

-- Stand-in bars for previews, shaped like the ones an AuraContainer draws, so a group being
-- positioned has something to grab before any aura lands. Nothing here touches aura data.
--
-- IconSlotContainer's slots are square by construction, so bars live here instead. The surface
-- (SetSlot, SetSlotUnused, ResetAllSlots, Count) matches the other stand-in containers, so a caller
-- can swap between them by shape alone.

-- Gap between the icon and the fill, and how far text sits inside the fill. Matching
-- AuraContainerDisplay's bar buttons, so the preview and the real thing line up.
local TEXT_INSET = 3
local NAME_COEFFICIENT = 0.5
local COUNTDOWN_COEFFICIENT = 0.4
-- Border thickness, matching the live bars.
local BORDER_THICKNESS = 1
-- Below this many seconds the countdown shows tenths, like the icon countdowns.
local MILLISECONDS_THRESHOLD = 5
-- The spent part of a bar, matching AuraContainerDisplay's live bars.
local TRACK_COLOR = { 0.09, 0.09, 0.09 }
local DEFAULT_WIDTH = 150
local DEFAULT_HEIGHT = 20
local DEFAULT_SPACING = 2
-- Fill drained by the preview's own clock, so it refreshes on a timer rather than per frame.
local UPDATE_INTERVAL = 0.05

local frameIdCounter = 0

---@class BarSlotContainer
local M = {}
M.__index = M

addon.Core.BarSlotContainer = M

local function NextFrameName()
	frameIdCounter = frameIdCounter + 1
	return "MiniAuras_BarSlot_" .. frameIdCounter
end

---@param remaining number
---@return string
local function CountdownText(remaining)
	if remaining < MILLISECONDS_THRESHOLD then
		return string.format("%.1f", remaining)
	end

	if remaining < 60 then
		return tostring(math.ceil(remaining))
	end

	return math.ceil(remaining / 60) .. "m"
end

---@param instance BarSlotContainer
---@param parent table
---@return table
local function CreateBar(instance, parent)
	local frame = CreateFrame("Frame", nil, parent)

	local icon = frame:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	icon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
	icon:SetTexCoord(iconUtil:TexCoord())

	local bar = CreateFrame("StatusBar", nil, frame)
	bar:SetPoint("TOPLEFT", icon, "TOPRIGHT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(1)

	-- The stand-in owns its own clock, so its fill drains directly rather than through the
	-- inside-out trick the live bars need. The track colour matches theirs so the two look alike.
	local background = bar:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints(bar)
	background:SetColorTexture(TRACK_COLOR[1], TRACK_COLOR[2], TRACK_COLOR[3], 1)

	local time = bar:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	time:SetPoint("RIGHT", bar, "RIGHT", -TEXT_INSET, 0)
	time:SetJustifyH("RIGHT")

	-- The name gives way to the countdown rather than running underneath it.
	local name = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	name:SetPoint("LEFT", bar, "LEFT", TEXT_INSET, 0)
	name:SetPoint("RIGHT", time, "LEFT", -TEXT_INSET, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)

	-- Around the icon and the fill together, like the live bars, and hidden until a slot asks for
	-- it. On its own frame above the status bar rather than on the slot frame: a child frame draws
	-- over its parent's regions, so an outline built on the slot showed only where it crossed the
	-- icon and vanished along the fill.
	local overlay = CreateFrame("Frame", nil, frame)
	overlay:SetAllPoints(frame)
	overlay:SetFrameLevel(bar:GetFrameLevel() + 1)

	local border = outline:Create(overlay, 0, BORDER_THICKNESS)

	frame:Hide()

	local slot = {
		Frame = frame,
		Icon = icon,
		Bar = bar,
		Name = name,
		Time = time,
		Border = border,
		BorderOverlay = overlay,
		IsUsed = false,
	}

	instance.Slots[#instance.Slots + 1] = slot

	return slot
end

---Drains every used bar from the expiry its caller supplied. Nothing here is an aura clock: the
---duration objects come from WoWEx:CreateDuration, which is the addon's own.
---@param instance BarSlotContainer
local function Drain(instance)
	local now = GetTime()

	for index = 1, instance.Count do
		local slot = instance.Slots[index]

		if slot and slot.IsUsed and slot.Expiry and slot.Duration and slot.Duration > 0 then
			local remaining = math.max(0, slot.Expiry - now)

			slot.Bar:SetValue(remaining / slot.Duration)
			slot.Time:SetText(CountdownText(remaining))
		end
	end
end

---@param instance BarSlotContainer
local function ApplyLayout(instance)
	local width = instance.Width
	local height = instance.Height
	local spacing = instance.Spacing
	local vertical = instance.Grow == "UP" or instance.Grow == "DOWN"
	local used = 0

	for index = 1, instance.Count do
		local slot = instance.Slots[index]

		if slot and slot.IsUsed then
			used = used + 1
		end
	end

	local span = used > 0 and (used * (vertical and height or width) + (used - 1) * spacing)
		or (vertical and height or width)
	local totalWidth = vertical and width or span
	local totalHeight = vertical and span or height
	local placed = 0

	instance.Frame:SetSize(totalWidth, totalHeight)

	for index = 1, instance.Count do
		local slot = instance.Slots[index]

		if slot and slot.IsUsed then
			local x, y = 0, 0

			if vertical then
				local step = placed * (height + spacing)
				-- Growing up puts the first bar at the bottom, nearest the anchor.
				y = instance.Grow == "UP"
					and (-totalHeight / 2 + height / 2 + step)
					or (totalHeight / 2 - height / 2 - step)
			else
				x = placed * (width + spacing) - totalWidth / 2 + width / 2
			end

			slot.Frame:ClearAllPoints()
			slot.Frame:SetPoint("CENTER", instance.Frame, "CENTER", x, y)
			slot.Frame:SetSize(width, height)
			slot.Icon:SetWidth(height)
			fontUtil:UpdateFontSize(slot.Name, height, NAME_COEFFICIENT, slot.FontScale)
			fontUtil:UpdateFontSize(slot.Time, height, COUNTDOWN_COEFFICIENT, slot.FontScale)
			slot.Frame:Show()
			placed = placed + 1
		elseif slot then
			slot.Frame:Hide()
		end
	end

	for index = instance.Count + 1, #instance.Slots do
		local slot = instance.Slots[index]

		if slot then
			slot.IsUsed = false
			slot.Frame:Hide()
		end
	end
end

---@param instance BarSlotContainer
local function ApplyTicker(instance)
	local wanted = false

	for index = 1, instance.Count do
		local slot = instance.Slots[index]

		if slot and slot.IsUsed and slot.Expiry then
			wanted = true
			break
		end
	end

	if wanted == (instance.Ticker ~= nil) then
		return
	end

	if wanted then
		instance.Ticker = C_Timer.NewTicker(UPDATE_INTERVAL, function()
			Drain(instance)
		end)
	else
		instance.Ticker:Cancel()
		instance.Ticker = nil
	end
end

---@param parent table Frame to attach to.
---@param count number How many bars to keep (default 3).
---@param width number Bar width in pixels (default 100).
---@param height number Bar height in pixels (default 20).
---@param spacing number Gap between bars (default 2).
---@param moduleName string? MiniCCModule label set on Frame, so other addons can find it.
---@return BarSlotContainer
function M:New(parent, count, width, height, spacing, moduleName)
	local instance = setmetatable({}, M)

	instance.Frame = CreateFrame("Frame", NextFrameName(), parent)
	instance.Frame:SetIgnoreParentScale(true)
	instance.Frame.MiniCCModule = moduleName or nil
	instance.Slots = {}
	instance.Count = 0
	instance.Width = width or DEFAULT_WIDTH
	instance.Height = height or DEFAULT_HEIGHT
	instance.Spacing = spacing or DEFAULT_SPACING
	instance.Grow = "DOWN"

	instance:SetCount(count or 3)

	return instance
end

---@param newCount number
function M:SetCount(newCount)
	newCount = math.max(0, math.floor(tonumber(newCount) or 0))

	if self.Count == newCount then
		return
	end

	self.Count = newCount

	while #self.Slots < newCount do
		CreateBar(self, self.Frame)
	end

	ApplyLayout(self)
end

---@param width number
---@param height number
function M:SetBarSize(width, height)
	width = tonumber(width) or self.Width
	height = tonumber(height) or self.Height

	if width <= 0 or height <= 0 or (self.Width == width and self.Height == height) then
		return
	end

	self.Width = width
	self.Height = height
	ApplyLayout(self)
end

---@param newSpacing number
function M:SetSpacing(newSpacing)
	newSpacing = tonumber(newSpacing)

	if not newSpacing or newSpacing < 0 or self.Spacing == newSpacing then
		return
	end

	self.Spacing = newSpacing
	ApplyLayout(self)
end

---Which way the stack runs, using the same option values as the live displays: UP and DOWN stack
---vertically, everything else lays the bars out in a row.
---@param grow string?
function M:SetGrow(grow)
	grow = grow or "DOWN"

	if self.Grow == grow then
		return
	end

	self.Grow = grow
	ApplyLayout(self)
end

---Fills one bar. The option names it shares with IconSlotContainer mean the same thing, so a
---preview renderer can hand the same table to either.
---@param slotIndex number
---@param options BarSlotOptions
function M:SetSlot(slotIndex, options)
	if slotIndex < 1 or slotIndex > self.Count or not options.Texture then
		return
	end

	local slot = self.Slots[slotIndex]

	if not slot then
		return
	end

	local wasUsed = slot.IsUsed
	local color = options.Color

	slot.IsUsed = true
	slot.FontScale = options.FontScale
	slot.Icon:SetTexture(options.Texture)
	slot.Name:SetText(options.Name or "")

	-- Both texts take the option's colour, matching the live bars; white is what the fonts
	-- already render in, so leaving the option out changes nothing.
	local textColor = options.TextColor
	local textR = textColor and textColor.r or 1
	local textG = textColor and textColor.g or 1
	local textB = textColor and textColor.b or 1

	slot.Name:SetTextColor(textR, textG, textB)
	slot.Time:SetTextColor(textR, textG, textB)

	-- Only on change: a status bar rebuilds its fill from scratch when the texture is swapped, and
	-- this runs for every slot on every preview render.
	local texture = barTextures:Resolve(options.BarTexture)

	if slot.BarTexturePath ~= texture then
		slot.BarTexturePath = texture
		slot.Bar:SetStatusBarTexture(texture)
	end

	-- After the texture: a fresh fill comes back untinted.
	slot.Bar:SetStatusBarColor(
		color and color.r or 1,
		color and color.g or 1,
		color and color.b or 1
	)

	-- Driven by the option alone, unlike the icon containers, where a border is what a colour
	-- draws and a running glow suppresses it. A bar has no glow and always carries its colour.
	outline:Apply(slot.Border, options.Border == true,
		color and color.r, color and color.g, color and color.b)

	local expiry = options.DurationObject and wowEx:GetDurationExpiry(options.DurationObject)

	slot.Expiry = expiry
	slot.Duration = expiry and math.max(0.001, expiry - GetTime()) or nil

	if not expiry then
		slot.Bar:SetValue(1)
		slot.Time:SetText("")
	end

	if not wasUsed then
		ApplyLayout(self)
	end

	Drain(self)
	ApplyTicker(self)
end

---@param slotIndex number
function M:SetSlotUnused(slotIndex)
	local slot = self.Slots[slotIndex]

	if not slot or not slot.IsUsed then
		return
	end

	slot.IsUsed = false
	slot.Expiry = nil
	slot.Duration = nil
	ApplyLayout(self)
	ApplyTicker(self)
end

function M:ResetAllSlots()
	for _, slot in ipairs(self.Slots) do
		slot.IsUsed = false
		slot.Expiry = nil
		slot.Duration = nil
	end

	ApplyLayout(self)
	ApplyTicker(self)
end

---@class BarSlotOptions
---@field Texture string|number Icon texture path or file ID.
---@field Name string? Text shown inside the fill.
---@field DurationObject table? A WoWEx:CreateDuration object; without one the bar sits full.
---@field Color table? {r, g, b} fill colour, which the border takes too.
---@field TextColor table? {r, g, b} for the name and countdown text; white leaves them as they come.
---@field Border boolean? Draw a border around the bar.
---@field FontScale number? Multiplier on both text sizes.
---@field BarTexture string? Fill texture name, resolved through Core/Display/Media/BarTextures.

---@class BarSlotContainer
---@field Frame table
---@field Slots table[]
---@field Count number
---@field Width number
---@field Height number
---@field Spacing number
---@field Grow string
---@field Ticker table?
