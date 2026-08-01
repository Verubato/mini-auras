local _, addon = ...
local M = addon.Framework

---Rounds v to the nearest integer and clamps it to [minV, maxV].
---@return number the clamped value, or fallback when v isn't a number
function M:ClampInt(v, minV, maxV, fallback)
	v = tonumber(v)

	if not v then
		return fallback
	end

	v = math.floor(v + 0.5)

	if v < minV then
		return minV
	end

	if v > maxV then
		return maxV
	end

	return v
end

---Clamps v to [minV, maxV] without rounding.
---@return number the clamped value, or fallback when v isn't a number
function M:ClampFloat(v, minV, maxV, fallback)
	v = tonumber(v)

	if not v then
		return fallback
	end

	if v < minV then
		return minV
	end

	if v > maxV then
		return maxV
	end

	return v
end
