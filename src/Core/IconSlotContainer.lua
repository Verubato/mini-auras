---@type string, Addon
local _, addon = ...
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local Masque = LibStub and LibStub("Masque", true)
-- Debounce table keyed by group object: one deferred ReSkin per group per frame
local masqueReskinPending = {}
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

local function ScheduleMasqueReSkin(group)
	if not group or masqueReskinPending[group] then
		return
	end
	masqueReskinPending[group] = true
	C_Timer.After(0, function()
		masqueReskinPending[group] = nil
		group:ReSkin()
	end)
end

local function CreateLayer(parentFrame, level, iconSize)
	local f = CreateFrame("Frame", nil, parentFrame)
	f:SetAllPoints()

	if level then
		f:SetFrameLevel(level)
	end

	-- place our icons on the 1st draw layer of background
	local icon = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	icon:SetAllPoints()

	local cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
	cd:SetAllPoints()
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	cd:SetSwipeColor(0, 0, 0, 0.8)

	-- make the border 1px larger than the icon
	-- refer to https://github.com/Gethe/wow-ui-source/blob/aa3d9bc8633244ba017bf2058bf5e84900397ab5/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.xml#L31
	local border = f:CreateTexture(nil, "OVERLAY")
	border:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, -1)
	border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
	border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
	border:Hide()

	if iconSize then
		cd.DesiredIconSize = iconSize
		-- FontScale will be set when SetSlot is called
		cd.FontScale = 1.0
		fontUtil:UpdateCooldownFontSize(cd, iconSize, nil, cd.FontScale)
	end

	return { Frame = f, Border = border, Icon = icon, Cooldown = cd }
end

local function EnsureContainer(slot, iconSize, group)
	if slot.Container then
		return slot.Container
	end

	-- Wrap in its own frame so its alpha doesn't propagate to extra layers,
	-- which are siblings (also children of slot.Frame) rather than descendants.
	local slotLevel = slot.Frame:GetFrameLevel() or 0
	slot.Container = CreateLayer(slot.Frame, slotLevel + 1, iconSize)

	if group then
		group:AddButton(slot.Container.Frame, {
			Icon = slot.Container.Icon,
			Cooldown = slot.Container.Cooldown,
		})
	end

	return slot.Container
end

-- layerIndex is the public layer number (2, 3, …); extra layer 1 lives at slot.ExtraLayers[1], etc.
local function EnsureExtraLayer(slot, layerIndex, iconSize)
	local extraIdx = layerIndex - 1
	if not slot.ExtraLayers then
		slot.ExtraLayers = {}
	end

	local slotLevel = slot.Frame:GetFrameLevel() or 0
	-- Base layer (slot.Container) occupies slotLevel+1.
	-- Extra layer l (1-based) sits at slotLevel + 1 + l*2 so each layer clears
	-- the cooldown text draw layer of the one below it.
	local baseLevel = slotLevel + 1

	for l = #slot.ExtraLayers + 1, extraIdx do
		slot.ExtraLayers[l] = CreateLayer(slot.Frame, baseLevel + l * 2, iconSize)
	end

	-- Re-apply levels if the slot frame level has changed since last time.
	if slot.LastExtraBaseLevel ~= baseLevel then
		slot.LastExtraBaseLevel = baseLevel
		for l = 1, #slot.ExtraLayers do
			local el = slot.ExtraLayers[l]
			if el and el.Frame then
				el.Frame:SetFrameLevel(baseLevel + l * 2)
			end
		end
	end

	return slot.ExtraLayers[extraIdx]
end

local function ApplyAlpha(target, alpha)
	if type(alpha) == "number" then
		target:SetAlpha(alpha)
	else
		target:SetAlphaFromBoolean(alpha)
	end
end

local function ClearLayerData(layer, glowFrame)
	if not layer then
		return
	end
	layer.Icon:SetTexture(nil)
	layer.Cooldown:Clear()
	if LCG then
		if glowFrame._ProcGlow and LCG.ProcGlow_Stop then
			LCG.ProcGlow_Stop(glowFrame)
		end
		if glowFrame._PixelGlow and LCG.PixelGlow_Stop then
			LCG.PixelGlow_Stop(glowFrame)
		end
		if glowFrame._AutoCastGlow and LCG.AutoCastGlow_Stop then
			LCG.AutoCastGlow_Stop(glowFrame)
		end
	end
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
		local alpha = options.Alpha
		if glowType == "Proc Glow" then
			local procGlow = layerFrame._ProcGlow
			if procGlow then
				ApplyAlpha(procGlow, alpha)
			end
		elseif glowType == "Pixel Glow" then
			local pixelGlow = layerFrame._PixelGlow
			if pixelGlow then
				ApplyAlpha(pixelGlow, alpha)
			end
		elseif glowType == "Autocast Shine" then
			local autoCastGlow = layerFrame._AutoCastGlow
			if autoCastGlow then
				ApplyAlpha(autoCastGlow, alpha)
			end
		end

		-- calling ProcGlow_Start on an existing glow will reset its size to match the current icon size
		-- the other glow types already handle resizing properly on their own, so we only need to do this for Proc Glow
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
---@param groupName string? Masque sub-group name (e.g. "CC", "Trinkets"). Omit to skip Masque.
---@return IconSlotContainer
function M:New(parent, count, size, spacing, groupName)
	local instance = setmetatable({}, M)

	count = count or 3
	size = size or 20
	spacing = spacing or 2

	instance.Frame = CreateFrame("Frame", nil, parent)
	instance.Frame:SetIgnoreParentScale(true)
	instance.Frame:SetIgnoreParentAlpha(true)
	instance.Slots = {}
	instance.Count = 0
	instance.Size = size
	instance.Spacing = spacing
	instance.MasqueGroup = Masque and groupName and Masque:Group("MiniCC", groupName) or nil

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

---Sets the spacing between slots
---@param newSpacing number
function M:SetSpacing(newSpacing)
	---@diagnostic disable-next-line: cast-local-type
	newSpacing = tonumber(newSpacing)
	if not newSpacing or newSpacing < 0 then
		return
	end
	if self.Spacing == newSpacing then
		return
	end

	self.Spacing = newSpacing
	self.LayoutSignature = nil
	self:Layout()
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

			if slot.ExtraLayers then
				for _, el in ipairs(slot.ExtraLayers) do
					if el then
						if el.Frame then
							el.Frame:SetSize(self.Size, self.Size)
						end
						if el.Cooldown then
							el.Cooldown.DesiredIconSize = self.Size
							local fontScale = el.Cooldown.FontScale or 1.0
							fontUtil:UpdateCooldownFontSize(el.Cooldown, self.Size, nil, fontScale)
						end
					end
				end
			end
		end
	end

	-- Re-apply the Masque skin at the new size, debounced per group.
	ScheduleMasqueReSkin(self.MasqueGroup)

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
		local slotFrame = CreateFrame(self.MasqueGroup and "Button" or "Frame", nil, self.Frame)
		slotFrame:SetSize(self.Size, self.Size)
		slotFrame:EnableMouse(false)

		self.Slots[i] = {
			Frame = slotFrame,
			Container = nil,
			ExtraLayers = {},
			IsUsed = false,
		}
	end

	self:Layout()
end

---Sets an icon on a specific slot, optionally on a stacked layer above it.
---@param slotIndex number Slot index (1-based)
---@param options IconLayerOptions Options for the layer
---@class IconLayerOptions
---@field Texture string Texture path/ID
---@field StartTime number? Cooldown start time (GetTime())
---@field Duration number? Cooldown duration in seconds
---@field Alpha number|boolean? Control alpha: number sets it directly, boolean uses SetAlphaFromBoolean
---@field Glow boolean? Whether to show glow effect (requires LibCustomGlow)
---@field ReverseCooldown boolean? Whether to reverse the cooldown animation
---@field Color table? RGBA color table {r, g, b, a} for glow and border color
---@field FontScale number? Font scale multiplier for cooldown text (default: 1.0)
---@field Layer number? Which layer to render on (1 = base, 2+ = stacked above; default: 1)
function M:SetSlot(slotIndex, options)
	if slotIndex < 1 or slotIndex > self.Count then
		return
	end

	if not options.Texture or not options.StartTime or not options.Duration then
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

	local layerIndex = options.Layer or 1
	local layer
	
	if layerIndex <= 1 then
		layer = EnsureContainer(slot, self.Size, self.MasqueGroup)
	else
		layer = EnsureExtraLayer(slot, layerIndex, self.Size)
	end

	layer.Icon:SetTexture(options.Texture)
	layer.Cooldown:SetReverse(options.ReverseCooldown)
	layer.Cooldown:SetCooldown(options.StartTime, options.Duration)

	ApplyAlpha(layer.Frame, options.Alpha)

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

	if options.FontScale then
		layer.Cooldown.FontScale = options.FontScale
		fontUtil:UpdateCooldownFontSize(layer.Cooldown, self.Size, nil, options.FontScale)
	end

	UpdateGlow(layer.Frame, options)
end

-- Clears all layers on a slot
---@param slotIndex number Slot index
function M:ClearSlot(slotIndex)
	if slotIndex < 1 or slotIndex > #self.Slots then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot or not slot.Container then
		return
	end

	ClearLayerData(slot.Container, slot.Container.Frame)

	if slot.ExtraLayers then
		for _, el in ipairs(slot.ExtraLayers) do
			if el then
				ClearLayerData(el, el.Frame)
			end
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
---@field ExtraLayers IconLayer[]
---@field IsUsed boolean

---@class IconSlotContainer
---@field Frame table
---@field MasqueGroup table?
---@field Slots IconSlot[]
---@field Count number
---@field Size number
---@field Spacing number
---@field SetCount fun(self: IconSlotContainer, count: number)
---@field SetSpacing fun(self: IconSlotContainer, spacing: number)
---@field SetIconSize fun(self: IconSlotContainer, size: number)
---@field SetSlot fun(self: IconSlotContainer, slotIndex: number, options: IconLayerOptions)
---@field ClearSlot fun(self: IconSlotContainer, slotIndex: number)
---@field SetSlotUnused fun(self: IconSlotContainer, slotIndex: number)
---@field GetUsedSlotCount fun(self: IconSlotContainer): number
---@field ResetAllSlots fun(self: IconSlotContainer)
