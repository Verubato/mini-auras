---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local wowEx = addon.Utils.WoWEx
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil

addon.Modules.EnemyKickTracker = addon.Modules.EnemyKickTracker or {}

---@class EnemyKickTrackerDisplay
local M = {}
addon.Modules.EnemyKickTracker.Display = M

-- The Masque group these icons are skinned under, and the public MiniCCModule frame tag.
local MASQUE_GROUP = "Enemy Kicks"

---@type Db
local db
local testModeActive = false

---@type KickBar
local kickBar = {
	Container = nil, ---@type IconSlotContainer?
	Anchor = nil, ---@type table?
	ActiveSlots = {}, ---@type table<number, {Key: number, Timer: table}>
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

---@param duration number
---@param icon string|number
local function AddIcon(duration, icon)
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
		Color = moduleUtil:GetIconColor(iconOptions),
		FontScale = db.FontScale,
	})

	local timer = not testModeActive and C_Timer.NewTimer(duration, function()
		local slotData = kickBar.ActiveSlots[slotIndex]
		if slotData and slotData.Key == key then
			kickBar.Container:SetSlotUnused(slotIndex)
			kickBar.ActiveSlots[slotIndex] = nil
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
	end
end

---@param duration number
---@param icon string|number
function M:AddKick(duration, icon)
	AddIcon(duration, icon)
end

function M:Clear()
	CancelTimers()

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
---@param entries { Duration: number, Icon: string|number }[]
function M:ShowTestKicks(entries)
	CancelTimers()

	for _, entry in ipairs(entries) do
		AddIcon(entry.Duration, entry.Icon)
	end

	if kickBar.Container then
		for i = #entries + 1, kickBar.Container.Count do
			kickBar.Container:SetSlotUnused(i)
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
---@field MaxSlots number
