---@type string, Addon
local _, addon = ...
local mini = addon.Framework

---@class DebugOptions
local M = {}

addon.Core.DebugOptions = M

---Whether the player wants extra chat messages that help track down problems.
---@return boolean
function M:Enabled()
	local db = mini:GetSavedVars()

	return db.DebugMode ~= false
end
