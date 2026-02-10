---@type string, Addon
local addonName, addon = ...
local capabilities = addon.Capabilities
local array = addon.Utils.Array
local mini = addon.Core.Framework
local iconSlotContainer = addon.Core.IconSlotContainer
local unitWatcher = addon.Core.UnitAuraWatcher
local units = addon.Utils.Units
local ccUtil = addon.Utils.CcUtil
local paused = false
local soundFile = "Interface\\AddOns\\" .. addonName .. "\\Media\\Sonar.ogg"

---@type Db
local db

---@type table
local healerAnchor

---@type IconSlotContainer
local iconsContainer

---@type table<string, HealerWatchEntry>
local activePool = {}
---@type table<string, HealerWatchEntry>
local discardPool = {}

local lastCcdAlpha
local eventsFrame

---@class HealerWatchEntry
---@field Unit string
---@field Watcher Watcher

---@class HealerCcModule : IModule
local M = {}
addon.Modules.HealerCcModule = M

local function UpdateAnchorSize()
	if not healerAnchor then
		return
	end

	local options = db.Healer
	local iconSize = tonumber(options.Icons.Size) or 32
	local text = healerAnchor.HealerWarning
	local stringWidth = text and text:GetStringWidth() or 0
	local stringHeight = text and text:GetStringHeight() or 0
	local containerWidth = (iconsContainer and iconsContainer.Frame and iconsContainer.Frame:GetWidth()) or iconSize
	local width = math.max(iconSize, stringWidth, containerWidth)
	local height = iconSize + stringHeight

	healerAnchor:SetSize(width, height)
end

local function OnAuraStateUpdated()
	if paused then
		return
	end

	if not healerAnchor or not iconsContainer then
		return
	end

	local options = db.Healer

	iconsContainer:ResetAllSlots()

	---@type AuraInfo[]
	local allCcAuraData = {}
	local slot = 0

	for _, watcher in pairs(activePool) do
		local ccState = watcher.Watcher:GetCcState()
		array:Append(ccState, allCcAuraData)

		if capabilities:HasNewFilters() then
			for _, aura in ipairs(ccState) do
				slot = slot + 1
				iconsContainer:SetSlotUsed(slot)
				iconsContainer:SetLayer(
					slot,
					1,
					aura.SpellIcon,
					aura.StartTime,
					aura.TotalDuration,
					aura.IsCC,
					options.Icons.Glow,
					options.Icons.ReverseCooldown
				)
				iconsContainer:FinalizeSlot(slot, 1)
			end
		elseif #ccState > 0 then
			slot = slot + 1
			local used = 0
			for _, aura in ipairs(ccState) do
				used = used + 1
				iconsContainer:SetSlotUsed(slot)
				iconsContainer:SetLayer(
					slot,
					used,
					aura.SpellIcon,
					aura.StartTime,
					aura.TotalDuration,
					aura.IsCC,
					options.Icons.Glow,
					options.Icons.ReverseCooldown
				)
			end
			iconsContainer:FinalizeSlot(slot, used)
		end
	end

	local isCcdAlpha = ccUtil:IsCcAppliedAlpha(allCcAuraData)
	healerAnchor:SetAlpha(isCcdAlpha)

	if db.Healer.Sound.Enabled and not mini:IsSecret(isCcdAlpha) then
		if isCcdAlpha == 1 and lastCcdAlpha ~= isCcdAlpha then
			M:PlaySound()
		end
	end

	lastCcdAlpha = isCcdAlpha

	UpdateAnchorSize()
end

local function DisableAll()
	local toDiscard = {}
	for unit in pairs(activePool) do
		toDiscard[#toDiscard + 1] = unit
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		if item then
			item.Watcher:Disable()
			discardPool[unit] = item
			activePool[unit] = nil
		end
	end

	if iconsContainer then
		iconsContainer:ResetAllSlots()
		iconsContainer:SetCount(0)
	end

	if healerAnchor then
		healerAnchor:SetAlpha(0)
	end

	lastCcdAlpha = nil
end

local function RefreshHealers()
	-- Remove anyone who is no longer a healer.
	local toDiscard = {}
	for unit in pairs(activePool) do
		if not units:IsHealer(unit) then
			toDiscard[#toDiscard + 1] = unit
		end
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		if item then
			item.Watcher:Disable()
			discardPool[unit] = item
			activePool[unit] = nil
		end
	end

	local healers = units:FindHealers()

	for _, healer in ipairs(healers) do
		local item = activePool[healer]

		if not item then
			item = discardPool[healer]

			if item then
				item.Watcher:Enable()
				activePool[healer] = item
				discardPool[healer] = nil
			end
		end

		if not item then
			item = {
				Unit = healer,
				Watcher = unitWatcher:New(healer, nil, {
					CC = true,
				}),
			}

			item.Watcher:RegisterCallback(OnAuraStateUpdated)
			activePool[healer] = item
		end
	end

	OnAuraStateUpdated()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		M:Refresh()
	end
end

function M:PlaySound()
	PlaySoundFile(soundFile, db.Healer.Sound.Channel or "Master")
end

function M:GetAnchor()
	return healerAnchor
end

function M:Show()
	if not healerAnchor then
		return
	end

	healerAnchor:EnableMouse(true)
	healerAnchor:SetMovable(true)
	healerAnchor:SetAlpha(1)
end

function M:Hide()
	if not healerAnchor then
		return
	end

	healerAnchor:EnableMouse(false)
	healerAnchor:SetMovable(false)
	healerAnchor:SetAlpha(0)
end

function M:Refresh()
	if not healerAnchor then
		return
	end

	local options = db.Healer

	healerAnchor:ClearAllPoints()
	healerAnchor:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	healerAnchor.HealerWarning:SetFont(options.Font.File, options.Font.Size, options.Font.Flags)

	iconsContainer:SetIconSize(tonumber(options.Icons.Size) or 32)

	if units:IsHealer("player") then
		DisableAll()
		return
	end

	if not options.Enabled then
		DisableAll()
		return
	end

	local inInstance, instanceType = IsInInstance()

	if instanceType == "arena" and not options.Filters.Arena then
		DisableAll()
		return
	end

	if instanceType == "pvp" and not options.Filters.BattleGrounds then
		DisableAll()
		return
	end

	if not inInstance and not options.Filters.World then
		DisableAll()
		return
	end

	RefreshHealers()
end

function M:Pause()
	paused = true
end

function M:Resume()
	paused = false
	OnAuraStateUpdated()
end

function M:Init()
	db = mini:GetSavedVars()

	local options = db.Healer

	healerAnchor = CreateFrame("Frame", addonName .. "HealerContainer")
	healerAnchor:EnableMouse(true)
	healerAnchor:SetMovable(true)
	healerAnchor:RegisterForDrag("LeftButton")
	healerAnchor:SetIgnoreParentScale(true)
	healerAnchor:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	healerAnchor:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		db.Healer.Point = point
		db.Healer.RelativePoint = relativePoint
		db.Healer.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		db.Healer.Offset.X = x
		db.Healer.Offset.Y = y
	end)

	local text = healerAnchor:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	text:SetPoint("TOP", healerAnchor, "TOP", 0, 6)
	text:SetFont(options.Font.File, options.Font.Size, options.Font.Flags)
	text:SetText("Healer in CC!")
	text:SetTextColor(1, 0.1, 0.1)
	text:SetShadowColor(0, 0, 0, 1)
	text:SetShadowOffset(1, -1)
	text:Show()

	healerAnchor.HealerWarning = text

	-- Icons sit at the bottom of the anchor, text sits at the top.
	iconsContainer = iconSlotContainer:New(healerAnchor, 5, tonumber(options.Icons.Size) or 32, 2)
	iconsContainer.Frame:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
	iconsContainer.Frame:Show()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	M:Refresh()
end
