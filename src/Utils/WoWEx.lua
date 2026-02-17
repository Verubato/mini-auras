---@type string, Addon
local _, addon = ...

---@class WoWEx
local M = {}

addon.Utils.WoWEx = M

function M:IsAddOnEnabled(addonName)
    return C_AddOns.GetAddOnEnableState(addonName, UnitName("player")) == 2
end

function M:IsDandersEnabled()
    return M:IsAddOnEnabled("DandersFrames")
end
