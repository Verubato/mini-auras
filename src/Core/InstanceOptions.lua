---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local testInstanceOptions
---@type Db
local db

---@class CrowdControlInstanceOptions
local M = {}

addon.Core.InstanceOptions = M

---@return CrowdControlInstanceOptions?
function M:GetInstanceOptions()
	local members = GetNumGroupMembers()
	return members > 5 and db.Modules.CCModule.Raid or db.Modules.CCModule.Default
end

---@return CrowdControlInstanceOptions?
function M:GetTestInstanceOptions()
	return testInstanceOptions
end

---@param options CrowdControlInstanceOptions?
function M:SetTestInstanceOptions(options)
	testInstanceOptions = options
end

function M:Init()
	db = mini:GetSavedVars()
end
