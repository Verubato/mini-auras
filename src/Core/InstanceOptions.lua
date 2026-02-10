---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local testInstanceOptions
---@type Db
local db

---@class InstanceOptions
local M = {}

addon.Core.InstanceOptions = M

function M:GetInstanceOptions()
	local inInstance, instanceType = IsInInstance()
	local isBgOrRaid = inInstance and (instanceType == "pvp" or instanceType == "raid")
	return isBgOrRaid and db.Raid or db.Default
end

function M:GetTestInstanceOptions()
    return testInstanceOptions
end

function M:SetTestInstanceOptions(options)
    testInstanceOptions = options
end

function M:Init()
    db = mini:GetSavedVars()
end
