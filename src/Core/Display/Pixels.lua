---@type string, Addon
local _, addon = ...
local mini = addon.Framework

---@class Pixels
local M = {}

addon.Core.Pixels = M

-- WoW measures the interface against a 768 unit tall screen, whatever the monitor is. A region's
-- effective scale is not how many screen pixels one interface unit covers: on a 1440p screen at
-- scale 0.64 the scale says 0.64 and the truth is 0.64 * 1440 / 768 = 1.2. Sizing anything against
-- the scale on its own lands nowhere near a whole pixel.
local REFERENCE_HEIGHT = 768

---A value the addon is allowed to do arithmetic on. On 12.1 a region hands back secret numbers
---for its geometry, which cannot be compared or added to, only passed straight back to the API.
---@param value any
---@return number?
function M:Number(value)
	if value == nil or mini:IsSecret(value) then
		return nil
	end

	if type(value) ~= "number" then
		return nil
	end

	return value
end

---How many screen pixels one interface unit covers for this region.
---@param region table
---@return number? nil when the client will not say how big the screen is
function M:PerUnit(region)
	local scale = M:Number(region:GetEffectiveScale())

	if not scale or scale <= 0 then
		return nil
	end

	local height

	if GetPhysicalScreenSize then
		local _, physicalHeight = GetPhysicalScreenSize()
		height = M:Number(physicalHeight)
	end

	-- UIParent covers the screen, so its own height in pixels is the screen's.
	if not height and UIParent then
		local parentScale = M:Number(UIParent:GetEffectiveScale())
		local parentHeight = M:Number(UIParent:GetHeight())

		if parentScale and parentScale > 0 and parentHeight then
			height = parentHeight * parentScale
		end
	end

	if not height or height <= 0 then
		return nil
	end

	return scale * height / REFERENCE_HEIGHT
end

---The nearest size that covers a whole number of screen pixels, never rounding away to nothing.
---@param units number size in interface units
---@param perUnit number screen pixels per interface unit
---@return number size in interface units
function M:Snap(units, perUnit)
	local pixels = math.max(1, math.floor(units * perUnit + 0.5))

	return pixels / perUnit
end

---An icon size taken as a share of a frame's height, snapped to whole pixels. Unit frames are
---sized very differently between a party profile and a raid one, so anything drawn on them is
---measured against the frame rather than given a size of its own.
---@param frame table
---@param share number percentage of the frame's height
---@param fallback number size to use when the client will not say how big anything is
---@return number
function M:ShareOfHeight(frame, share, fallback)
	local perUnit = M:PerUnit(frame)

	if not perUnit then
		return fallback
	end

	local height = M:Number(frame:GetHeight())
	local size = height and height > 0 and height * share / 100 or fallback

	return M:Snap(size, perUnit)
end
