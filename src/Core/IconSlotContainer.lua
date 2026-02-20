---@type string, Addon
local _, addon = ...
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local fontUtil = addon.Utils.FontUtil
local cachedDb = nil

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

local function CreateLayer(parentFrame, level, iconSize)
	local layerFrame = CreateFrame("Frame", nil, parentFrame)
	layerFrame:SetAllPoints()

	-- Explicitly set size to match parent frame size
	-- This ensures LibCustomGlow has correct dimensions immediately
	local w, h = parentFrame:GetSize()
	if w and h and w > 0 and h > 0 then
		layerFrame:SetSize(w, h)
	end

	if level then
		layerFrame:SetFrameLevel(level)
	end

	local icon = layerFrame:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()

	local cd = CreateFrame("Cooldown", nil, layerFrame, "CooldownFrameTemplate")
	cd:SetAllPoints()
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	cd:SetSwipeColor(0, 0, 0, 0.8)

	local border = layerFrame:CreateTexture(nil, "OVERLAY")
	-- make the border 1px larger than the icon
	border:SetPoint("TOPLEFT", layerFrame, "TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", layerFrame, "BOTTOMRIGHT", 1, -1)
	-- refer to https://github.com/Gethe/wow-ui-source/blob/aa3d9bc8633244ba017bf2058bf5e84900397ab5/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.xml#L31
	border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
	border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)

	-- Set initial font size based on icon size
	if iconSize then
		cd.DesiredIconSize = iconSize
		-- FontScale will be set when SetLayer is called
		cd.FontScale = 1.0
		fontUtil:UpdateCooldownFontSize(cd, iconSize, nil, cd.FontScale)
	end

	return {
		Frame = layerFrame,
		Border = border,
		Icon = icon,
		Cooldown = cd,
	}
end

local function EnsureLayer(slot, layerIndex, iconSize)
	local slotLevel = slot.Frame:GetFrameLevel() or 0
	local baseLevel = slotLevel + 1

	-- Create any missing layers
	-- Use +2 per layer to ensure cooldown text doesn't overlap next icon
	for l = #slot.Layers + 1, layerIndex do
		slot.Layers[l] = CreateLayer(slot.Frame, baseLevel + ((l - 1) * 2), iconSize)
	end

	-- re-apply levels to existing layers (covers cases where slot level changes)
	for l = 1, #slot.Layers do
		local layer = slot.Layers[l]
		if layer and layer.Frame then
			layer.Frame:SetFrameLevel(baseLevel + ((l - 1) * 2))
		end
	end

	return slot.Layers[layerIndex]
end

function M:Layout()
	local usedSlots = {}

	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot and slot.IsUsed then
			usedSlots[#usedSlots + 1] = i
		end
	end

	-- Build a cheap signature from the current size and used slot indices.
	-- If it matches the last run, the visual result would be identical so we
	-- can skip all the SetPoint/SetSize/Show/Hide calls.  This keeps Layout()
	-- synchronous (no timer deferral) while avoiding redundant frame work
	-- when it is called multiple times in a row with the same slot state.
	local sig = self.Size .. ":" .. table.concat(usedSlots, ",")
	if self.LayoutSignature == sig then
		return
	end
	self.LayoutSignature = sig

	local usedCount = #usedSlots
	local totalWidth = (usedCount * self.Size) + ((usedCount - 1) * self.Spacing)
	self.Frame:SetSize((usedCount > 0) and totalWidth or self.Size, self.Size)

	-- Ensure container alpha is 1 when showing icons
	if usedCount > 0 then
		self.Frame:SetAlpha(1)
	end

	-- Position used slots contiguously
	for displayIndex, slotIndex in ipairs(usedSlots) do
		local slot = self.Slots[slotIndex]
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

			-- Update cooldown font sizes and layer frame sizes
			for _, layer in ipairs(slot.Layers) do
				if layer and layer.Cooldown then
					layer.Cooldown.DesiredIconSize = self.Size
					local fontScale = layer.Cooldown.FontScale or 1.0
					fontUtil:UpdateCooldownFontSize(layer.Cooldown, self.Size, nil, fontScale)
				end

				-- Update layer frame size to match new slot size
				if layer and layer.Frame then
					layer.Frame:SetSize(self.Size, self.Size)
				end
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
			Layers = {},
			LayerCount = 0,
			IsUsed = false,
		}
	end

	self:Layout()
end

---Sets a layer on a specific slot
---@param slotIndex number Slot index (1-based)
---@param layerIndex number Layer index (1-based, higher = on top)
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
function M:SetLayer(slotIndex, layerIndex, options)
	if slotIndex < 1 or slotIndex > self.Count then
		return
	end
	if layerIndex < 1 then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot then
		return
	end

	local layer = EnsureLayer(slot, layerIndex, self.Size)
	slot.LayerCount = math.max(slot.LayerCount or 0, layerIndex)

	if options.Texture and options.StartTime and options.Duration then
		layer.Icon:SetTexture(options.Texture)
		layer.Cooldown:SetReverse(options.ReverseCooldown)
		layer.Cooldown:SetCooldown(options.StartTime, options.Duration)
		layer.Frame:SetAlphaFromBoolean(options.AlphaBoolean)

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

		if LCG then
			local db = GetDb()
			local glowType = (db and db.GlowType) or "Proc Glow"

			if options.Glow then
				-- Check which glow types currently exist
				local hasProcGlow = layer.Frame._ProcGlow ~= nil
				local hasPixelGlow = layer.Frame._PixelGlow ~= nil
				local hasAutoCastGlow = layer.Frame._AutoCastGlow ~= nil

				-- Check if color has changed
				local colorChanged = false
				local newColorKey = nil

				if options.Color then
					-- in test mode color isn't secret, and we want to restart the glows if colour changed
					-- string.format is safe to use for secrets
					-- and options.Color may not be secret, but options.Color.r/g/b/a can be
					newColorKey = string.format(
						"%.2f_%.2f_%.2f_%.2f",
						options.Color.r or 1,
						options.Color.g or 1,
						options.Color.b or 1,
						options.Color.a or 1
					)
				end

				if not newColorKey or not issecretvalue(newColorKey) then
					if layer.Frame._GlowColorKey ~= newColorKey then
						colorChanged = true
						layer.Frame._GlowColorKey = newColorKey
					end
				end

				-- Determine if we need to start a new glow
				local needsGlow = false
				if glowType == "Proc Glow" and (not hasProcGlow or colorChanged) then
					needsGlow = true
					-- Stop other glow types
					if hasPixelGlow and LCG.PixelGlow_Stop then
						LCG.PixelGlow_Stop(layer.Frame)
					end
					if hasAutoCastGlow and LCG.AutoCastGlow_Stop then
						LCG.AutoCastGlow_Stop(layer.Frame)
					end
					-- Stop existing glow if color changed
					if hasProcGlow and colorChanged and LCG.ProcGlow_Stop then
						LCG.ProcGlow_Stop(layer.Frame)
					end
				elseif glowType == "Pixel Glow" and (not hasPixelGlow or colorChanged) then
					needsGlow = true
					-- Stop other glow types
					if hasProcGlow and LCG.ProcGlow_Stop then
						LCG.ProcGlow_Stop(layer.Frame)
					end
					if hasAutoCastGlow and LCG.AutoCastGlow_Stop then
						LCG.AutoCastGlow_Stop(layer.Frame)
					end
					-- Stop existing glow if color changed
					if hasPixelGlow and colorChanged and LCG.PixelGlow_Stop then
						LCG.PixelGlow_Stop(layer.Frame)
					end
				elseif glowType == "Autocast Shine" and (not hasAutoCastGlow or colorChanged) then
					needsGlow = true
					-- Stop other glow types
					if hasProcGlow and LCG.ProcGlow_Stop then
						LCG.ProcGlow_Stop(layer.Frame)
					end
					if hasPixelGlow and LCG.PixelGlow_Stop then
						LCG.PixelGlow_Stop(layer.Frame)
					end
					-- Stop existing glow if color changed
					if hasAutoCastGlow and colorChanged and LCG.AutoCastGlow_Stop then
						LCG.AutoCastGlow_Stop(layer.Frame)
					end
				end

				-- Only start glow if needed
				if needsGlow then
					local glowOptions = { startAnim = false }

					-- Apply color if provided
					if options.Color then
						glowOptions.color = { options.Color.r, options.Color.g, options.Color.b, options.Color.a }
					end

					-- Start the appropriate glow type
					if glowType == "Pixel Glow" and LCG.PixelGlow_Start then
						LCG.PixelGlow_Start(layer.Frame, glowOptions.color)
					elseif glowType == "Autocast Shine" and LCG.AutoCastGlow_Start then
						LCG.AutoCastGlow_Start(layer.Frame, glowOptions.color)
					else
						-- Default to Proc Glow
						LCG.ProcGlow_Start(layer.Frame, glowOptions)
					end
				end

				-- Always update alpha for the active glow type
				if glowType == "Proc Glow" then
					local procGlow = layer.Frame._ProcGlow
					if procGlow then
						procGlow:SetAlphaFromBoolean(options.AlphaBoolean)
					end
				elseif glowType == "Pixel Glow" then
					local pixelGlow = layer.Frame._PixelGlow
					if pixelGlow then
						pixelGlow:SetAlphaFromBoolean(options.AlphaBoolean)
					end
				elseif glowType == "Autocast Shine" then
					local autoCastGlow = layer.Frame._AutoCastGlow
					if autoCastGlow then
						autoCastGlow:SetAlphaFromBoolean(options.AlphaBoolean)
					end
				end

				-- Handle glow resizing for ProcGlow/ButtonGlow
				-- PixelGlow and AutoCastGlow auto-resize in their OnUpdate handlers
				if glowType == "Proc Glow" and layer.Frame._ProcGlow and LCG.ProcGlow_Start then
					-- ProcGlow_Start efficiently handles resize when glow already exists
					local glowOptions = { startAnim = false }
					if options.Color then
						glowOptions.color = { options.Color.r, options.Color.g, options.Color.b, options.Color.a }
					end
					LCG.ProcGlow_Start(layer.Frame, glowOptions)
				end
			else
				-- Stop all glow types only if any exist
				if layer.Frame._ProcGlow and LCG.ProcGlow_Stop then
					LCG.ProcGlow_Stop(layer.Frame)
				end
				if layer.Frame._PixelGlow and LCG.PixelGlow_Stop then
					LCG.PixelGlow_Stop(layer.Frame)
				end
				if layer.Frame._AutoCastGlow and LCG.AutoCastGlow_Stop then
					LCG.AutoCastGlow_Stop(layer.Frame)
				end
				-- Clear color key when glow is disabled
				layer.Frame._GlowColorKey = nil
			end
		end
	end
end

-- Clears a specific layer on a slot
---@param slotIndex number Slot index
---@param layerIndex number Layer index
function M:ClearLayer(slotIndex, layerIndex)
	if slotIndex < 1 or slotIndex > #self.Slots then
		return
	end

	local slot = self.Slots[slotIndex]
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
		-- Stop only the glow types that exist
		if layer.Frame._ProcGlow and LCG.ProcGlow_Stop then
			LCG.ProcGlow_Stop(layer.Frame)
		end
		if layer.Frame._PixelGlow and LCG.PixelGlow_Stop then
			LCG.PixelGlow_Stop(layer.Frame)
		end
		if layer.Frame._AutoCastGlow and LCG.AutoCastGlow_Stop then
			LCG.AutoCastGlow_Stop(layer.Frame)
		end
	end
end

-- Clears all layers on a slot
---@param slotIndex number Slot index
function M:ClearSlot(slotIndex)
	if slotIndex < 1 or slotIndex > #self.Slots then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot then
		return
	end

	for l = 1, #slot.Layers do
		self:ClearLayer(slotIndex, l)
	end

	slot.LayerCount = 0
end

-- Finalizes a slot by clearing unused layers
---@param slotIndex number Slot index
---@param usedCount number Number of layers actually used
function M:FinalizeSlot(slotIndex, usedCount)
	if slotIndex < 1 or slotIndex > #self.Slots then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot then
		return
	end

	usedCount = usedCount or 0

	for l = usedCount + 1, #slot.Layers do
		self:ClearLayer(slotIndex, l)
	end

	slot.LayerCount = usedCount
end

---Marks a slot as used and triggers layout update
---@param slotIndex number Slot index
function M:SetSlotUsed(slotIndex)
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

---Checks if a slot is currently used
---@param slotIndex number Slot index
---@return boolean indicating if slot is used
function M:IsSlotUsed(slotIndex)
	if slotIndex < 1 or slotIndex > self.Count then
		return false
	end
	local slot = self.Slots[slotIndex]
	if not slot then
		return false
	end
	return slot.IsUsed or false
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
	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot and slot.IsUsed then
			self:SetSlotUnused(i)
		end
	end
end

---@class IconLayer
---@field Frame table
---@field Icon table
---@field Cooldown table

---@class IconSlot
---@field Frame table
---@field Layers IconLayer[]
---@field LayerCount number
---@field IsUsed boolean

---@class IconSlotContainer
---@field Frame table
---@field Slots IconSlot[]
---@field Count number
---@field Size number
---@field Spacing number
---@field SetCount fun(self: IconSlotContainer, count: number)
---@field SetIconSize fun(self: IconSlotContainer, size: number)
---@field SetLayer fun(self: IconSlotContainer, slotIndex: number, layerIndex: number, options: IconLayerOptions)
---@field ClearLayer fun(self: IconSlotContainer, slotIndex: number, layerIndex: number)
---@field ClearSlot fun(self: IconSlotContainer, slotIndex: number)
---@field FinalizeSlot fun(self: IconSlotContainer, slotIndex: number, usedCount: number)
---@field SetSlotUsed fun(self: IconSlotContainer, slotIndex: number)
---@field SetSlotUnused fun(self: IconSlotContainer, slotIndex: number)
---@field IsSlotUsed fun(self: IconSlotContainer, slotIndex: number): boolean
---@field GetUsedSlotCount fun(self: IconSlotContainer): number
---@field ResetAllSlots fun(self: IconSlotContainer)
