---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local unitWatcher = addon.UnitAuraWatcher
local paused = false
---@type Db
local db
---@type IconSlotContainer
local anchor
---@type Watcher[]
local watchers
local LCG = LibStub and LibStub("LibCustomGlow-1.0", false)

---@class ImportantSpellsManager
local M = {}
addon.ImportantSpellsManager = M

local function CreateIconSlotContainer(count, size, spacing)
	count = count or 3
	size = size or 20
	spacing = spacing or 2

	local frame = CreateFrame("Frame", nil, parent)
	local container = {
		Frame = frame,
		Slots = {},
		Count = 0,
		Size = size,
		Spacing = spacing,
	}

	local function Layout()
		local totalWidth = (container.Count * container.Size) + ((container.Count - 1) * container.Spacing)
		container.Frame:SetSize(totalWidth, container.Size)

		for i = 1, #container.Slots do
			local slot = container.Slots[i]
			if i <= container.Count then
				local x = (i - 1) * (container.Size + container.Spacing) - (totalWidth / 2) + (container.Size / 2)
				slot.Frame:ClearAllPoints()
				slot.Frame:SetPoint("CENTER", container.Frame, "CENTER", x, 0)
				slot.Frame:SetSize(container.Size, container.Size)
				slot.Frame:Show()
			else
				slot.Frame:Hide()
			end
		end
	end

	function container:SetIconSize(newSize)
		newSize = tonumber(newSize)
		if not newSize or newSize <= 0 then
			return
		end
		if container.Size == newSize then
			return
		end

		container.Size = newSize

		for i = 1, #container.Slots do
			local slot = container.Slots[i]
			if slot and slot.Frame then
				slot.Frame:SetSize(container.Size, container.Size)
			end
		end

		Layout()
	end

	local function CreateLayer(parentFrame)
		local layerFrame = CreateFrame("Frame", nil, parentFrame)
		layerFrame:SetAllPoints()

		local icon = layerFrame:CreateTexture(nil, "OVERLAY")
		icon:SetAllPoints()

		local cd = CreateFrame("Cooldown", nil, layerFrame, "CooldownFrameTemplate")
		cd:SetAllPoints()
		cd:SetDrawEdge(false)
		cd:SetDrawBling(false)
		cd:SetHideCountdownNumbers(false)
		cd:SetSwipeColor(0, 0, 0, 0.8)

		return {
			Frame = layerFrame,
			Icon = icon,
			Cooldown = cd,
		}
	end

	local function EnsureLayer(slot, layerIndex)
		for l = #slot.Layers + 1, layerIndex do
			slot.Layers[l] = CreateLayer(slot.Frame)
		end
		return slot.Layers[layerIndex]
	end

	function container:SetCount(newCount)
		newCount = math.max(0, newCount or 0)
		container.Count = newCount

		for i = #container.Slots + 1, newCount do
			local slotFrame = CreateFrame("Frame", nil, container.Frame)
			slotFrame:SetSize(container.Size, container.Size)

			container.Slots[i] = {
				Frame = slotFrame,
				Layers = {},
				Used = 0,
			}
		end

		Layout()
	end

	function container:SetLayer(
		slotIndex,
		layerIndex,
		texture,
		startTime,
		duration,
		alphaBoolean,
		glow,
		reverseCooldown
	)
		local slot = container.Slots[slotIndex]
		if not slot or slotIndex > container.Count then
			return
		end
		if layerIndex < 1 then
			return
		end

		local layer = EnsureLayer(slot, layerIndex)
		slot.Used = math.max(slot.Used or 0, layerIndex)

		if texture and startTime and duration then
			layer.Icon:SetTexture(texture)
			layer.Cooldown:SetReverse(reverseCooldown)
			layer.Cooldown:SetCooldown(startTime, duration)
			layer.Frame:SetAlphaFromBoolean(alphaBoolean)

			if LCG then
				if glow then
					LCG.ProcGlow_Start(layer.Frame, { startAnim = false })
					local procGlow = layer.Frame._ProcGlow
					if procGlow then
						procGlow:SetAlphaFromBoolean(alphaBoolean)
					end
				else
					LCG.ProcGlow_Stop(layer.Frame)
				end
			end
		end
	end

	function container:ClearLayer(slotIndex, layerIndex)
		local slot = container.Slots[slotIndex]
		if not slot then
			return
		end
		local layer = slot.Layers[layerIndex]
		if not layer then
			return
		end

		layer.Icon:SetTexture(nil)
		layer.Cooldown:Clear()

		if LCG then
			LCG.ProcGlow_Stop(layer.Frame)
		end
	end

	function container:ClearSlot(slotIndex)
		local slot = container.Slots[slotIndex]
		if not slot then
			return
		end

		for l = 1, #slot.Layers do
			container:ClearLayer(slotIndex, l)
		end

		slot.Used = 0
	end

	function container:FinalizeSlot(slotIndex, usedCount)
		local slot = container.Slots[slotIndex]
		if not slot then
			return
		end

		usedCount = usedCount or 0

		for l = usedCount + 1, #slot.Layers do
			container:ClearLayer(slotIndex, l)
		end

		slot.Used = usedCount
	end

	container:SetCount(count)
	return container
end

local function OnAuraDataChanged()
	if paused then
		return
	end

	for i, watcher in ipairs(watchers) do
		local spellData = watcher:GetImportantState()

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

		-- TODO: is this causing icons to flicker?
		--anchor:FinalizeSlot(i, used)
	end
end

function M:Init()
	db = mini:GetSavedVars()

	local options = db.Alerts
	local count = 3
	local size = options.Icons.Size

	anchor = CreateIconSlotContainer(count, size, 2)

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

	for i = 1, anchor.Count or 0 do
		anchor:ClearSlot(i)
	end
end

function M:RefreshData()
	OnAuraDataChanged()
end

---@class IconLayer
---@field Frame table
---@field Icon string
---@field Cooldown table

---@class IconSlot
---@field Frame table
---@field Layers IconLayer[]
---@field Used number

---@class IconSlotContainer
---@field Frame table
---@field Slots IconSlot[]
---@field Count number
---@field Size number
---@field Spacing number
---@field SetCount fun(self: IconSlotContainer, count: number)
---@field SetIconSize fun(self: IconSlotContainer, size: number)
---@field SetLayer fun(self: IconSlotContainer, slotIndex: number, layerIndex: number, texture: string, startTime: number?, duration: number?, alphaBoolean: boolean, glow: boolean, reverseCooldown: boolean)
---@field ClearLayer fun(self: IconSlotContainer, slotIndex: number, layerIndex: number)
---@field ClearSlot fun(self: IconSlotContainer, slotIndex: number)
---@field FinalizeSlot fun(self: IconSlotContainer, slotIndex: number, usedCount: number)
