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

	if not db.Alerts.Enabled then
		return
	end

	local slot = 1
	local slotsNeeded = 0

	for _, watcher in ipairs(watchers) do
		local defensivesData = watcher:GetDefensiveState()
		local importantData = watcher:GetImportantState()
		local needed = #defensivesData + (#importantData > 0 and 1 or 0)

		slotsNeeded = slotsNeeded + needed

		if #defensivesData > 0 then
			for _, data in ipairs(defensivesData) do
				anchor:ClearSlot(slot)
				anchor:SetSlotUsed(slot)

				anchor:SetLayer(
					slot,
					1,
					data.SpellIcon,
					data.StartTime,
					data.TotalDuration,
					data.IsDefensive,
					db.Alerts.Icons.Glow,
					db.Alerts.Icons.ReverseCooldown
				)

				anchor:FinalizeSlot(slot, 1)
				slot = slot + 1
			end
		else
			anchor:ClearSlot(slot)
			anchor:SetSlotUnused(slot)
		end

		if #importantData > 0 then
			anchor:SetSlotUsed(slot)

			local used = 0
			for _, data in ipairs(importantData) do
				used = used + 1
				anchor:SetLayer(
					slot,
					used,
					data.SpellIcon,
					data.StartTime,
					data.TotalDuration,
					data.IsImportant,
					db.Alerts.Icons.Glow,
					db.Alerts.Icons.ReverseCooldown
				)
			end

			anchor:FinalizeSlot(slot, used)
		else
			-- No spell data, mark slot as unused
			anchor:ClearSlot(slot)
			anchor:SetSlotUnused(slot)
		end
	end

	if slotsNeeded == 0 then
		anchor:ResetAllSlots()
	else
		-- clear any slots above what we used
		for i = slotsNeeded + 1, anchor.Count do
			anchor:ClearSlot(i)
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

	for _, watcher in ipairs(watchers) do
		watcher:Pause()
	end
end

function M:Resume()
	paused = false

	for _, watcher in ipairs(watchers) do
		watcher:Resume()
	end
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
