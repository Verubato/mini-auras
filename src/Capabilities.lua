---@type string, Addon
local _, addon = ...

---@class Capabilities
local M = {}

addon.Capabilities = M

local hasNewFilters

-- TODO: remove this now that we only support 12.0.1
function M:HasNewFilters()
	return hasNewFilters
end

local _, _, _, build = GetBuildInfo()
hasNewFilters = build >= 120001
