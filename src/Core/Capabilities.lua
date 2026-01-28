---@type string, Addon
local _, addon = ...

---@class Capabilities
local M = {}

addon.Capabilities = M

local manualSwitch = true
local supportsCrowdControlFiltering

function M:SupportsCrowdControlFiltering()
	return supportsCrowdControlFiltering and manualSwitch
end

local _, _, _, build = GetBuildInfo()
supportsCrowdControlFiltering = build >= 120001
