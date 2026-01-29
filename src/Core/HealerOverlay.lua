---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local auras = addon.Auras
local units = addon.Units
local capabilities = addon.Capabilities
local testMode = addon.TestModeManager
---@type Db
local db
---@type table
local healerAnchor
---@type table<string, table>
local healerHeaders = {}

---@class HealerOverlay
local M = {}

addon.HealerOverlay = M

local function OnHealerCcChanged()
	if testMode:IsEnabled() then
		return
	end

	if not healerAnchor then
		return
	end

	if capabilities:SupportsCrowdControlFiltering() then
		local isCcd = false
		for _, header in pairs(healerHeaders) do
			isCcd = isCcd or header.IsCcApplied
			if isCcd then
				break
			end
		end
		healerAnchor:SetAlpha(isCcd and 1 or 0)
	else
		local ev = C_CurveUtil.EvaluateColorValueFromBoolean
		local result = 0
		for _, header in pairs(healerHeaders) do
			result = ev(header.IsCcApplied, 1, result)
		end
		healerAnchor:SetAlpha(result)
	end
end

local function RefreshHeaders()
	for unit, header in pairs(healerHeaders) do
		if not units:IsHealer(unit) or not options.Enabled then
			auras:ClearHeader(header)
			healerHeaders[unit] = nil
		end
	end

	local healers = units:FindHealers()

	for _, healer in ipairs(healers) do
		local header = healerHeaders[healer]
		if header then
			auras:UpdateHeader(header, healer, options.Icons)
		else
			header = auras:CreateHeader(healer, options.Icons)
			header:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
			header:RegisterCallback(OnHealerCcChanged)
			header:Show()
			healerHeaders[healer] = header
		end
	end
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
		return
	end

	if not options.Enabled then
		return
	end

	local inInstance, instanceType = IsInInstance()

	if instanceType == "arena" and not options.Filters.Arena then
		return
	end

	if instanceType == "pvp" and not options.Filters.BattleGrounds then
		return
	end

	if not inInstance and not options.Filters.World then
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
