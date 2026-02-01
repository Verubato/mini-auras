---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local auras = addon.CcHeader
local unitWatcher = addon.UnitAuraWatcher
local units = addon.Units
local ccManager = addon.CcManager
local paused = false
local soundFile = "Interface\\AddOns\\" .. addonName .. "\\Media\\Sonar.ogg"
---@type Db
local db
---@type table
local healerAnchor
---@type table<string, HealerWatchEntry>
local activePool = {}
---@type table<string, HealerWatchEntry>
local discardPool = {}

local lastCcdAlpha

---@class HealerWatchEntry
---@field Watcher Watcher
---@field Header CcHeader

---@class HealerCcManager
local M = {}
addon.HealerCcManager = M

local function OnHealerCcChanged()
	if paused then
		return
	end

	if not healerAnchor then
		return
	end

	---@type AuraInfo[]
	local ccAuraData = {}

	for _, watcher in pairs(activePool) do
		ccAuraData[#ccAuraData + 1] = watcher.Watcher:GetCcState()
	end

	local isCcdAlpha = ccManager:IsCcAppliedAlpha(ccAuraData)
	healerAnchor:SetAlpha(isCcdAlpha)

	if not db.Healer.Sound.Enabled then
		return
	end

	if mini:IsSecret(isCcdAlpha) then
		return
	end

	if isCcdAlpha == 1 and lastCcdAlpha ~= isCcdAlpha then
		M:PlaySound()
	end

	lastCcdAlpha = isCcdAlpha
end

local function DisableAll()
	local toDiscard = {}
	for unit in pairs(activePool) do
		toDiscard[#toDiscard + 1] = unit
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		if item then
			item.Header:Hide()
			item.Watcher:Pause()
			discardPool[unit] = item
			activePool[unit] = nil
		end
	end

	if healerAnchor then
		healerAnchor:SetAlpha(0)
	end

	lastCcdAlpha = nil
end

local function RefreshHeaders()
	local options = db.Healer
	local toDiscard = {}

	for unit, _ in pairs(activePool) do
		if not units:IsHealer(unit) then
			toDiscard[#toDiscard + 1] = unit
		end
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		item.Header:Hide()
		item.Watcher:Pause()
		discardPool[unit] = item
		activePool[unit] = nil
	end

	local healers = units:FindHealers()

	for _, healer in ipairs(healers) do
		local item = activePool[healer]

		if not item then
			-- see if we have a discarded entry to re-use
			item = discardPool[healer]

			if item then
				item.Watcher:Resume()
				item.Header:Show()

				-- move to the active pool
				activePool[healer] = item
				discardPool[healer] = nil
			end
		end

		if item then
			auras:Update(item.Header, healer, options.Icons)
		else
			item = { Header = auras:New(healer, options.Icons), Watcher = unitWatcher:New(healer) }
			item.Header:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
			item.Header:Show()

			item.Watcher:RegisterCallback(OnHealerCcChanged)
			activePool[healer] = item
		end
	end
end

function M:PlaySound()
	PlaySoundFile(soundFile, db.Healer.Sound.Channel or "Master")
end

function M:Init()
	db = mini:GetSavedVars()

	local options = db.Healer

	healerAnchor = CreateFrame("Frame", addonName .. "HealerContainer")
	healerAnchor:EnableMouse(true)
	healerAnchor:SetMovable(true)
	healerAnchor:RegisterForDrag("LeftButton")
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
end

function M:GetAnchor()
	return healerAnchor
end

function M:Refresh()
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

	local iconSize = db.Healer.Icons.Size
	local stringWidth = healerAnchor.HealerWarning:GetStringWidth()
	local stringHeight = healerAnchor.HealerWarning:GetStringHeight()

	healerAnchor:SetSize(math.max(iconSize, stringWidth), iconSize + stringHeight)

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

	RefreshHeaders()
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

function M:Pause()
	paused = true
end

function M:Resume()
	paused = false
end
