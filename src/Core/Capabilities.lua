---@type string, Addon
local _, addon = ...

---@class Capabilities
local M = {}

addon.Capabilities = M

function M:SupportsCrowdControlFiltering()
    return false
	-- local _, _, _, build = GetBuildInfo()
	--
	-- return build >= 120001
end
