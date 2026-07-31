local _, addon = ...
local M = addon.Core.Framework

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
