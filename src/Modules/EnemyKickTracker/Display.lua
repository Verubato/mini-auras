---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local iconSlotContainer = addon.Core.IconSlotContainer
local kickColors = addon.Core.KickColors
local fontUtil = addon.Utils.FontUtil
local moduleUtil = addon.Utils.ModuleUtil

addon.Modules.EnemyKickTracker = addon.Modules.EnemyKickTracker or {}

---@class EnemyKickTrackerDisplay
local M = {}
addon.Modules.EnemyKickTracker.Display = M

-- The Masque group these icons are skinned under, and the public MiniCCModule frame tag.
local MASQUE_GROUP = "Enemy Kicks"

-- Small enough that a name of ordinary length still fits the icon's width.
local NAME_FONT_COEFFICIENT = 0.25

local NAME_GAP = 2
local NAME_FONT_FLAGS = "OUTLINE"

---@type Db
local db
local testModeActive = false

---@type KickBar
local kickBar = {
	Container = nil, ---@type IconSlotContainer?
	Anchor = nil, ---@type table?
	ActiveSlots = {}, ---@type table<number, {Key: number, Timer: table}>
	Names = {}, ---@type table<number, table>
	MaxSlots = 10,
}

local function UpdateVisibility()
	if not kickBar.Container or not kickBar.Anchor then
		return
	end

	local usedCount = kickBar.Container:GetUsedSlotCount()
	if usedCount == 0 then
		kickBar.Anchor:Hide()
	else
		kickBar.Anchor:Show()
	end
end

local function CancelTimers()
	for _, slotData in pairs(kickBar.ActiveSlots) do
		if slotData.Timer then
			slotData.Timer:Cancel()
		end
	end

	wipe(kickBar.ActiveSlots)
end

local function GetNextAvailableSlot()
	for i = 1, kickBar.MaxSlots do
		if not kickBar.ActiveSlots[i] then
			return i
		end
	end
	return nil
end

---The label above a slot's icon, built on first use and reused for whatever lands in that slot.
---@param slotIndex number
---@return table?
local function GetNameText(slotIndex)
	local existing = kickBar.Names[slotIndex]
	if existing then
		return existing
	end

	local slot = kickBar.Container and kickBar.Container.Slots[slotIndex]
	if not slot or not slot.Frame then
		return nil
	end

	local text = slot.Frame:CreateFontString(nil, "OVERLAY")
	text:SetPoint("BOTTOM", slot.Frame, "TOP", 0, NAME_GAP)
	text:SetJustifyH("CENTER")
	-- A name is secret inside an instance, so it cannot be cut to a length here. Clamping the
	-- string to one line of the icon's width leaves the trimming to the client.
	text:SetWordWrap(false)

	kickBar.Names[slotIndex] = text

	return text
end

---@param slotIndex number
local function ClearName(slotIndex)
	local text = kickBar.Names[slotIndex]

	if text then
		text:SetText("")
		text:Hide()
	end
end

---A bare font string inherits no font, so one is set here.
---@param text table
---@param iconSize number
---@param fontScale number?
local function ApplyNameFont(text, iconSize, fontScale)
	local size = math.max(6, math.floor(iconSize * NAME_FONT_COEFFICIENT * (fontScale or 1)))

	fontUtil:Apply(text, size, NAME_FONT_FLAGS, fontUtil:GameFace())
end

---@param slotIndex number
---@param name any the interrupter's name, secret inside an instance
local function PaintName(slotIndex, name)
	local showName = db.Modules.EnemyKickTracker.ShowName ~= false

	if name == nil or not showName then
		ClearName(slotIndex)
		return
	end

	local text = GetNameText(slotIndex)
	if not text then
		return
	end

	local size = kickBar.Container.Size

	text:SetWidth(size)
	ApplyNameFont(text, size, db.Modules.EnemyKickTracker.FontScale)
	text:SetText(name)
	text:Show()
end

---@param duration number
---@param icon string|number
---@param name any the interrupter's name, secret inside an instance
---@param class any the interrupter's class token, secret inside an instance
local function AddIcon(duration, icon, name, class)
	if not kickBar.Container then
		return
	end

	local slotIndex = GetNextAvailableSlot()
	if not slotIndex then
		return
	end

	local key = math.random()
	local iconOptions = db.Modules.EnemyKickTracker.Icons

	kickBar.Container:SetSlot(slotIndex, {
		Texture = icon,
		DurationObject = wowEx:CreateDuration(GetTime(), duration),
		Alpha = true,
		ReverseCooldown = iconOptions.ReverseCooldown or false,
		Glow = iconOptions.Glow or false,
		-- Who kicked is worth more than the tint the user picked, so the class wins where it
		-- resolved.
		Color = kickColors:ClassColor(class) or moduleUtil:GetIconColor(iconOptions),
		FontScale = db.Modules.EnemyKickTracker.FontScale,
	})

	PaintName(slotIndex, name)

	local timer = not testModeActive and C_Timer.NewTimer(duration, function()
		local slotData = kickBar.ActiveSlots[slotIndex]
		if slotData and slotData.Key == key then
			kickBar.Container:SetSlotUnused(slotIndex)
			kickBar.ActiveSlots[slotIndex] = nil
			ClearName(slotIndex)
			UpdateVisibility()
		end
	end) or nil

	kickBar.ActiveSlots[slotIndex] = {
		Key = key,
		Timer = timer,
	}

	UpdateVisibility()
end

local function CreateFrames()
	local options = db.Modules.EnemyKickTracker
	local iconOptions = options.Icons
	local size = tonumber(iconOptions.Size) or 50
	local spacing = options.IconSpacing or 2

	local container = iconSlotContainer:New(UIParent, kickBar.MaxSlots, size, spacing, MASQUE_GROUP, nil, MASQUE_GROUP)
	-- Dragging is armed here and only switched on in test mode.
	container.Frame:SetMovable(false)
	container.Frame:EnableMouse(false)
	container.Frame:SetDontSavePosition(true)
	moduleUtil:MakeMovable(container.Frame, options)

	local relativeTo = _G[options.RelativeTo] or UIParent
	container.Frame:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)

	kickBar.Container = container
	kickBar.Anchor = container.Frame
end

function M:EnsureFrames()
	if kickBar.Container then
		return
	end

	CreateFrames()
end

---@param options EnemyKickTrackerModuleOptions
function M:ApplyOptions(options)
	local frame = kickBar.Anchor

	if frame then
		local relativeTo = _G[options.RelativeTo] or UIParent

		frame:ClearAllPoints()
		frame:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
	end

	if kickBar.Container then
		kickBar.Container:SetIconSize(tonumber(options.Icons.Size) or 50)
		kickBar.Container:SetSpacing(options.IconSpacing or 2)

		if options.ShowName ~= false then
			-- The icons under the labels have just moved, so a label already on screen follows its slot.
			for _, text in pairs(kickBar.Names) do
				if text:IsShown() then
					text:SetWidth(kickBar.Container.Size)
					ApplyNameFont(text, kickBar.Container.Size, options.FontScale)
				end
			end
		else
			for slotIndex in pairs(kickBar.Names) do
				ClearName(slotIndex)
			end
		end
	end
end

---@param duration number
---@param icon string|number
---@param name any the interrupter's name, secret inside an instance
---@param class any the interrupter's class token, secret inside an instance
function M:AddKick(duration, icon, name, class)
	AddIcon(duration, icon, name, class)
end

function M:Clear()
	CancelTimers()

	for slotIndex in pairs(kickBar.Names) do
		ClearName(slotIndex)
	end

	if kickBar.Container then
		kickBar.Container:ResetAllSlots()
	end

	UpdateVisibility()
end

function M:Show()
	if kickBar.Anchor then
		kickBar.Anchor:Show()
	end
end

function M:Hide()
	if kickBar.Anchor then
		kickBar.Anchor:Hide()
	end
end

---Puts the bar under the mouse so it can be dragged, and keeps it on screen while it is empty.
---@param active boolean
function M:SetAnchorInteractive(active)
	local anchor = kickBar.Anchor

	if not anchor then
		return
	end

	anchor:SetMovable(active)
	anchor:EnableMouse(active)
	moduleUtil:SetTestLabel(anchor, active and (L["Enemy Kicks_Short"] or L["Enemy Kicks"]) or nil)

	-- The anchor is the live bar's own frame. Leaving drag mode hands visibility back to the
	-- used-slot rule, so a bar mid-kick stays up.
	if active then
		anchor:Show()
	else
		UpdateVisibility()
	end
end

---@param active boolean
function M:SetTestMode(active)
	testModeActive = active
end

---Replaces whatever is on the bar with a fixed set of icons that never expire.
---@param entries { Duration: number, Icon: string|number, Name: string?, Class: string? }[]
function M:ShowTestKicks(entries)
	CancelTimers()

	for _, entry in ipairs(entries) do
		AddIcon(entry.Duration, entry.Icon, entry.Name, entry.Class)
	end

	if kickBar.Container then
		for i = #entries + 1, kickBar.Container.Count do
			kickBar.Container:SetSlotUnused(i)
			ClearName(i)
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()
end

---@class KickBar
---@field Container IconSlotContainer?
---@field Anchor table?
---@field ActiveSlots table<number, {Key: number, Timer: table}>
---@field Names table<number, table>  the kicker label above each slot's icon
---@field MaxSlots number
