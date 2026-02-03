---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local unitWatcher = addon.UnitAuraWatcher
local iconSlotContainer = addon.IconSlotContainer
local paused = false
---@type Db
local db
---@type IconSlotContainer
local anchor
---@type Watcher[]
local watchers

---@class ImportantSpellsManager
local M = {}
addon.ImportantSpellsManager = M

local function OnAuraDataChanged()
	if paused then
		return
	end

	for i, watcher in ipairs(watchers) do
		local spellData = watcher:GetImportantState()

		-- Clear the slot first
		anchor:ClearSlot(i)

		if #spellData > 0 then
			-- Mark slot as used and add layers
			anchor:SetSlotUsed(i)

			local used = 0
			for _, data in ipairs(spellData) do
				used = used + 1
				anchor:SetLayer(
					i,
					used,
					data.SpellIcon,
					data.StartTime,
					data.TotalDuration,
					data.IsImportant,
					db.Alerts.Icons.Glow,
					db.Alerts.Icons.ReverseCooldown
				)
			end

			anchor:FinalizeSlot(i, used)
		else
			-- No spell data, mark slot as unused
			anchor:SetSlotUnused(i)
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()

	local options = db.Alerts
	local count = 3
	local size = options.Icons.Size

	anchor = iconSlotContainer:New(UIParent, count, size, 2)
	anchor.Frame:SetIgnoreParentScale(true)

	local initialRelativeTo = _G[options.RelativeTo] or UIParent
	anchor.Frame:SetPoint(options.Point, initialRelativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
	anchor.Frame:SetFrameStrata("HIGH")
	anchor.Frame:SetFrameLevel((initialRelativeTo:GetFrameLevel() or 0) + 5)
	anchor.Frame:EnableMouse(false)
	anchor.Frame:SetMovable(false)
	anchor.Frame:RegisterForDrag("LeftButton")
	anchor.Frame:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	anchor.Frame:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		options.Point = point
		options.RelativePoint = relativePoint
		options.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		options.Offset.X = x
		options.Offset.Y = y
	end)
	anchor.Frame:Show()

	watchers = {
		unitWatcher:New("arena1", { "ARENA_OPPONENT_UPDATE" }),
		unitWatcher:New("arena2", { "ARENA_OPPONENT_UPDATE" }),
		unitWatcher:New("arena3", { "ARENA_OPPONENT_UPDATE" }),
	}

	anchor:SetCount(#watchers)

	for _, watcher in ipairs(watchers) do
		watcher:RegisterCallback(OnAuraDataChanged)
	end
end

function M:GetAnchor()
	return anchor
end

function M:Refresh()
	local options = db.Alerts

	anchor.Frame:ClearAllPoints()
	anchor.Frame:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	anchor:SetIconSize(db.Alerts.Icons.Size)
end

function M:Pause()
	paused = true
end

function M:Resume()
	paused = false
end

function M:ClearAll()
	if not anchor then
		return
	end

	anchor:ResetAllSlots()
end

function M:RefreshData()
	OnAuraDataChanged()
end
