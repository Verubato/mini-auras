---@type string, Addon
local _, addon = ...
local artTextures = addon.Core.ArtTextures

-- Stand-in art for previews, shaped like the texture an AuraContainer draws, so a group being
-- positioned has something to grab before its aura is up. Nothing here touches aura data.
--
-- One slot, always: a texture group draws its art once while any tracked aura is up. The rest of
-- the surface (SetSlot, SetSlotUnused, ResetAllSlots, Count) matches the other stand-in containers,
-- so a caller can swap between the three by shape alone.

local DEFAULT_SIZE = 64

local frameIdCounter = 0

---@class TextureSlotContainer
local M = {}
M.__index = M

addon.Core.TextureSlotContainer = M

local function NextFrameName()
	frameIdCounter = frameIdCounter + 1
	return "MiniAuras_TextureSlot_" .. frameIdCounter
end

---@param instance TextureSlotContainer
local function ApplyLayout(instance)
	instance.Frame:SetSize(instance.Width, instance.Height)
	instance.Art:SetAllPoints(instance.Frame)
end

---@param parent table Frame to attach to.
---@param width number Texture width in pixels.
---@param height number Texture height in pixels.
---@param moduleName string? MiniCCModule label set on Frame, so other addons can find it.
---@return TextureSlotContainer
function M:New(parent, width, height, moduleName)
	local instance = setmetatable({}, M)

	instance.Frame = CreateFrame("Frame", NextFrameName(), parent)
	instance.Frame:SetIgnoreParentScale(true)
	instance.Frame.MiniCCModule = moduleName or nil
	instance.Art = instance.Frame:CreateTexture(nil, "ARTWORK")
	instance.Art:Hide()
	instance.Width = tonumber(width) or DEFAULT_SIZE
	instance.Height = tonumber(height) or DEFAULT_SIZE
	instance.Count = 1

	ApplyLayout(instance)

	return instance
end

---@param width number
---@param height number
function M:SetTextureSize(width, height)
	width = tonumber(width) or self.Width
	height = tonumber(height) or self.Height

	if width <= 0 or height <= 0 or (self.Width == width and self.Height == height) then
		return
	end

	self.Width = width
	self.Height = height
	ApplyLayout(self)
end

---Fills the one slot. Index and option names match the other stand-in containers, so the preview
---renderer treats all three the same way.
---@param slotIndex number
---@param options ArtTextureSpec
function M:SetSlot(slotIndex, options)
	if slotIndex ~= 1 then
		return
	end

	artTextures:Apply(self.Art, options)
end

---@param slotIndex number
function M:SetSlotUnused(slotIndex)
	if slotIndex == 1 then
		self.Art:Hide()
	end
end

function M:ResetAllSlots()
	self.Art:Hide()
end

---@class TextureSlotContainer
---@field Frame table
---@field Art table
---@field Count number
---@field Width number
---@field Height number
