---@type string, Addon
local _, addon = ...
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local fontUtil = addon.Utils.FontUtil
local cachedDb = nil
-- Reused across Layout() calls to avoid a table allocation on the hot path
local layoutScratch = {}

---@class IconSlotContainer
local M = {}
M.__index = M

addon.Core.IconSlotContainer = M

local function GetDb()
	if not cachedDb then
		local mini = addon.Core.Framework
		if mini and mini.GetSavedVars then
			cachedDb = mini:GetSavedVars()
		end
	end

	return cachedDb
end

local function EnsureContainer(slot, iconSize)
	if not slot.Container then
		-- place our icons on the 1st draw layer of background
		local icon = slot.Frame:CreateTexture(nil, "BACKGROUND", nil, 1)
		icon:SetAllPoints()

		local cd = CreateFrame("Cooldown", nil, slot.Frame, "CooldownFrameTemplate")
		cd:SetAllPoints()
		cd:SetDrawEdge(false)
		cd:SetDrawBling(false)
		cd:SetHideCountdownNumbers(false)
		cd:SetSwipeColor(0, 0, 0, 0.8)

		local border = slot.Frame:CreateTexture(nil, "OVERLAY")
		-- make the border 1px larger than the icon
		border:SetPoint("TOPLEFT", slot.Frame, "TOPLEFT", -1, 1)
		border:SetPoint("BOTTOMRIGHT", slot.Frame, "BOTTOMRIGHT", 1, -1)
		-- refer to https://github.com/Gethe/wow-ui-source/blob/aa3d9bc8633244ba017bf2058bf5e84900397ab5/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.xml#L31
		border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)

		if iconSize then
			cd.DesiredIconSize = iconSize
			-- FontScale will be set when SetSlot is called
			cd.FontScale = 1.0
			fontUtil:UpdateCooldownFontSize(cd, iconSize, nil, cd.FontScale)
		end

		slot.Container = { Border = border, Icon = icon, Cooldown = cd }
	end

	return slot.Container
end

---Updates glow effects on a layer frame
---@param layerFrame table The layer frame to update glow on
---@param options IconLayerOptions Options containing glow settings
local function UpdateGlow(layerFrame, options)
	if not LCG then
		return
	end

	local db = GetDb()
	local glowType = (db and db.GlowType) or "Proc Glow"

	if options.Glow then
		-- Check which glow types currently exist
		local hasProcGlow = layerFrame._ProcGlow ~= nil
		local hasPixelGlow = layerFrame._PixelGlow ~= nil
		local hasAutoCastGlow = layerFrame._AutoCastGlow ~= nil

		-- Check if color has changed
		local colorChanged = false
		local newColorKey = nil

		if options.Color then
			newColorKey = string.format(
				"%.2f_%.2f_%.2f_%.2f",
				options.Color.r or 1,
				options.Color.g or 1,
				options.Color.b or 1,
				options.Color.a or 1
			)
		end

		if not newColorKey or not issecretvalue(newColorKey) then
			if layerFrame._GlowColorKey ~= newColorKey then
				colorChanged = true
				layerFrame._GlowColorKey = newColorKey
			end
		elseif newColorKey and issecretvalue(newColorKey) then
			colorChanged = true
		end

		-- Determine if we need to start a new glow
		local needsGlow = false
		if glowType == "Proc Glow" and (not hasProcGlow or colorChanged) then
			needsGlow = true
			if hasPixelGlow and LCG.PixelGlow_Stop then
				LCG.PixelGlow_Stop(layerFrame)
			end
			if hasAutoCastGlow and LCG.AutoCastGlow_Stop then
				LCG.AutoCastGlow_Stop(layerFrame)
			end
			if hasProcGlow and colorChanged and LCG.ProcGlow_Stop then
				LCG.ProcGlow_Stop(layerFrame)
			end
		elseif glowType == "Pixel Glow" and (not hasPixelGlow or colorChanged) then
			needsGlow = true
			if hasProcGlow and LCG.ProcGlow_Stop then
				LCG.ProcGlow_Stop(layerFrame)
			end
			if hasAutoCastGlow and LCG.AutoCastGlow_Stop then
				LCG.AutoCastGlow_Stop(layerFrame)
			end
			if hasPixelGlow and colorChanged and LCG.PixelGlow_Stop then
				LCG.PixelGlow_Stop(layerFrame)
			end
		elseif glowType == "Autocast Shine" and (not hasAutoCastGlow or colorChanged) then
			needsGlow = true
			if hasProcGlow and LCG.ProcGlow_Stop then
				LCG.ProcGlow_Stop(layerFrame)
			end
			if hasPixelGlow and LCG.PixelGlow_Stop then
				LCG.PixelGlow_Stop(layerFrame)
			end
			if hasAutoCastGlow and colorChanged and LCG.AutoCastGlow_Stop then
				LCG.AutoCastGlow_Stop(layerFrame)
			end
		end

		-- Only start glow if needed
		if needsGlow then
			local glowOptions = { startAnim = false }

			if options.Color then
				glowOptions.color = { options.Color.r, options.Color.g, options.Color.b, options.Color.a }
			end

			if glowType == "Pixel Glow" and LCG.PixelGlow_Start then
				LCG.PixelGlow_Start(layerFrame, glowOptions.color)
			elseif glowType == "Autocast Shine" and LCG.AutoCastGlow_Start then
				LCG.AutoCastGlow_Start(layerFrame, glowOptions.color)
			else
				LCG.ProcGlow_Start(layerFrame, glowOptions)
			end
		end

		-- Always update alpha for the active glow type
		if glowType == "Proc Glow" then
			local procGlow = layerFrame._ProcGlow
			if procGlow then
				procGlow:SetAlphaFromBoolean(options.AlphaBoolean)
			end
		elseif glowType == "Pixel Glow" then
			local pixelGlow = layerFrame._PixelGlow
			if pixelGlow then
				pixelGlow:SetAlphaFromBoolean(options.AlphaBoolean)
			end
		elseif glowType == "Autocast Shine" then
			local autoCastGlow = layerFrame._AutoCastGlow
			if autoCastGlow then
				autoCastGlow:SetAlphaFromBoolean(options.AlphaBoolean)
			end
		end

		-- Handle glow resizing for ProcGlow/ButtonGlow
		if glowType == "Proc Glow" and layerFrame._ProcGlow and LCG.ProcGlow_Start then
			local glowOptions = { startAnim = false }
			if options.Color then
				glowOptions.color = { options.Color.r, options.Color.g, options.Color.b, options.Color.a }
			end
			LCG.ProcGlow_Start(layerFrame, glowOptions)
		end
	else
		-- Stop all glow types only if any exist
		if layerFrame._ProcGlow and LCG.ProcGlow_Stop then
			LCG.ProcGlow_Stop(layerFrame)
		end
		if layerFrame._PixelGlow and LCG.PixelGlow_Stop then
			LCG.PixelGlow_Stop(layerFrame)
		end
		if layerFrame._AutoCastGlow and LCG.AutoCastGlow_Stop then
			LCG.AutoCastGlow_Stop(layerFrame)
		end
		layerFrame._GlowColorKey = nil
	end
end

---Creates a new IconSlotContainer instance
---@param parent table frame to attach to
---@param count number of slots to create (default: 3)
---@param size number of each icon slot (default: 20)
---@param spacing number between slots (default: 2)
---@return IconSlotContainer
function M:New(parent, count, size, spacing)
	local instance = setmetatable({}, M)

	count = count or 3
	size = size or 20
	spacing = spacing or 2

	instance.Frame = CreateFrame("Frame", nil, parent)
	instance.Slots = {}
	instance.Count = 0
	instance.Size = size
	instance.Spacing = spacing

	instance:SetCount(count)

	return instance
end

function M:Layout()
	-- Populate scratch table with used slot indices
	local n = 0
	for i = 1, self.Count do
		if self.Slots[i] and self.Slots[i].IsUsed then
			n = n + 1
			layoutScratch[n] = i
		end
	end

	-- Build a cheap signature from the current size and used slot indices.
	-- If it matches the last run, the visual result would be identical so we
	-- can skip all the SetPoint/SetSize/Show/Hide calls.
	local sig = self.Size .. ":" .. table.concat(layoutScratch, ",", 1, n)
	if self.LayoutSignature == sig then
		return
	end
	self.LayoutSignature = sig

	-- Trim stale entries left over from a previous call with more slots
	for i = n + 1, #layoutScratch do
		layoutScratch[i] = nil
	end

	local usedCount = n
	local totalWidth = (usedCount * self.Size) + ((usedCount - 1) * self.Spacing)
	self.Frame:SetSize((usedCount > 0) and totalWidth or self.Size, self.Size)

	-- Ensure container alpha is 1 when showing icons
	if usedCount > 0 then
		self.Frame:SetAlpha(1)
	end

	-- Position used slots contiguously
	for displayIndex = 1, usedCount do
		local slot = self.Slots[layoutScratch[displayIndex]]
		local x = (displayIndex - 1) * (self.Size + self.Spacing) - (totalWidth / 2) + (self.Size / 2)
		slot.Frame:ClearAllPoints()
		slot.Frame:SetPoint("CENTER", self.Frame, "CENTER", x, 0)
		slot.Frame:SetSize(self.Size, self.Size)
		slot.Frame:Show()
	end

	-- Hide unused active slots
	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot and not slot.IsUsed then
			slot.Frame:Hide()
		end
	end

	-- Always hide inactive pooled slots
	for i = self.Count + 1, #self.Slots do
		local slot = self.Slots[i]
		if slot then
			slot.IsUsed = false
			slot.Frame:Hide()
		end
	end
end

---Sets the icon size for all slots
---@param newSize number
function M:SetIconSize(newSize)
	---@diagnostic disable-next-line: cast-local-type
	newSize = tonumber(newSize)
	if not newSize or newSize <= 0 then
		return
	end
	if self.Size == newSize then
		return
	end

	self.Size = newSize

	-- Resize active slots and update cooldown font sizes
	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot and slot.Frame then
			slot.Frame:SetSize(self.Size, self.Size)

			local layer = slot.Container
			if layer and layer.Cooldown then
				layer.Cooldown.DesiredIconSize = self.Size
				local fontScale = layer.Cooldown.FontScale or 1.0
				fontUtil:UpdateCooldownFontSize(layer.Cooldown, self.Size, nil, fontScale)
			end
		end
	end

	self:Layout()
end

---Sets the total number of slots
---@param newCount number of slots to maintain
function M:SetCount(newCount)
	newCount = math.max(0, newCount or 0)

	-- If shrinking, disable anything beyond newCount (pooled slots)
	if newCount < self.Count then
		for i = newCount + 1, #self.Slots do
			local slot = self.Slots[i]
			if slot then
				slot.IsUsed = false
				self:ClearSlot(i)
				slot.Frame:Hide()
			end
		end
	end

	self.Count = newCount

	-- Grow pool if needed
	for i = #self.Slots + 1, newCount do
		local slotFrame = CreateFrame("Frame", nil, self.Frame)
		slotFrame:SetSize(self.Size, self.Size)

		self.Slots[i] = {
			Frame = slotFrame,
			Container = nil,
			IsUsed = false,
		}
	end

	self:Layout()
end

---Sets the layer on a specific slot
---@param slotIndex number Slot index (1-based)
---@param options IconLayerOptions Options for the layer
---@class IconLayerOptions
---@field Texture string Texture path/ID
---@field StartTime number? Cooldown start time (GetTime())
---@field Duration number? Cooldown duration in seconds
---@field AlphaBoolean boolean? Control alpha (true = 1.0, false = dimmed)
---@field Glow boolean? Whether to show glow effect (requires LibCustomGlow)
---@field ReverseCooldown boolean? Whether to reverse the cooldown animation
---@field Color table? RGBA color table {r, g, b, a} for glow and border color
---@field FontScale number? Font scale multiplier for cooldown text (default: 1.0)
function M:SetSlot(slotIndex, options)
	if slotIndex < 1 or slotIndex > self.Count then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot then
		return
	end

	if not slot.IsUsed then
		slot.IsUsed = true
		self:Layout()
	end

	local layer = EnsureContainer(slot, self.Size)

	if options.Texture and options.StartTime and options.Duration then
		layer.Icon:SetTexture(options.Texture)
		layer.Cooldown:SetReverse(options.ReverseCooldown)
		layer.Cooldown:SetCooldown(options.StartTime, options.Duration)
		slot.Frame:SetAlphaFromBoolean(options.AlphaBoolean)

		-- Set border color if provided
		if options.Color and layer.Border then
			layer.Border:SetVertexColor(
				options.Color.r or 1,
				options.Color.g or 1,
				options.Color.b or 1,
				options.Color.a or 1
			)
			layer.Border:Show()
		elseif layer.Border then
			layer.Border:Hide()
		end

		-- Update font scale if provided
		if options.FontScale then
			layer.Cooldown.FontScale = options.FontScale
			fontUtil:UpdateCooldownFontSize(layer.Cooldown, self.Size, nil, options.FontScale)
		end

		UpdateGlow(slot.Frame, options)
	end
end

-- Clears the layer on a slot
---@param slotIndex number Slot index
function M:ClearSlot(slotIndex)
	if slotIndex < 1 or slotIndex > #self.Slots then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot then
		return
	end

	local layer = slot.Container
	if not layer then
		return
	end

	layer.Icon:SetTexture(nil)
	layer.Cooldown:Clear()

	if LCG then
		if slot.Frame._ProcGlow and LCG.ProcGlow_Stop then
			LCG.ProcGlow_Stop(slot.Frame)
		end
		if slot.Frame._PixelGlow and LCG.PixelGlow_Stop then
			LCG.PixelGlow_Stop(slot.Frame)
		end
		if slot.Frame._AutoCastGlow and LCG.AutoCastGlow_Stop then
			LCG.AutoCastGlow_Stop(slot.Frame)
		end
	end
end

---Marks a slot as unused and triggers layout update
---This will shift all other used slots to fill the gap
---@param slotIndex number Slot index
function M:SetSlotUnused(slotIndex)
	if slotIndex < 1 or slotIndex > self.Count then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot then
		return
	end

	if slot.IsUsed then
		slot.IsUsed = false
		self:ClearSlot(slotIndex)
		self:Layout()
	end
end

---Gets the number of currently used slots
---@return number Count of used slots
function M:GetUsedSlotCount()
	local count = 0
	for i = 1, self.Count do
		if self.Slots[i] and self.Slots[i].IsUsed then
			count = count + 1
		end
	end
	return count
end

---Resets all slots to unused (active range only)
function M:ResetAllSlots()
	local needsLayout = false
	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot and slot.IsUsed then
			slot.IsUsed = false
			self:ClearSlot(i)
			needsLayout = true
		end
	end
	if needsLayout then
		self:Layout()
	end
end

---@class IconLayer
---@field Icon table
---@field Cooldown table
---@field Border table

---@class IconSlot
---@field Frame table
---@field Container IconLayer?
---@field IsUsed boolean

---@class IconSlotContainer
---@field Frame table
---@field Slots IconSlot[]
---@field Count number
---@field Size number
---@field Spacing number
---@field SetCount fun(self: IconSlotContainer, count: number)
---@field SetIconSize fun(self: IconSlotContainer, size: number)
---@field SetSlot fun(self: IconSlotContainer, slotIndex: number, options: IconLayerOptions)
---@field ClearSlot fun(self: IconSlotContainer, slotIndex: number)
---@field SetSlotUnused fun(self: IconSlotContainer, slotIndex: number)
---@field GetUsedSlotCount fun(self: IconSlotContainer): number
---@field ResetAllSlots fun(self: IconSlotContainer)
