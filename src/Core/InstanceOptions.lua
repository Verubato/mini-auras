---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local testInstanceOptions
---@type Db
local db

---@class CcInstanceOptions
local M = {}

addon.Core.InstanceOptions = M

---@return CcInstanceOptions?
function M:GetInstanceOptions()
	local members = GetNumGroupMembers()
	return members > 5 and db.Modules.CcModule.Raid or db.Modules.CcModule.Default
end

---@return CcInstanceOptions?
function M:GetTestInstanceOptions()
	return testInstanceOptions
end

---@param options CcInstanceOptions?
function M:SetTestInstanceOptions(options)
	testInstanceOptions = options
end

function M:Init()
	db = mini:GetSavedVars()
end
