local addonName, addon = ...
local L = addon.L

---@class MiniFramework
local M = {
	VerticalSpacing = 16,
	HorizontalSpacing = 20,
	TextMaxWidth = 600,
}
addon.Core.Framework = M

function M:Notify(msg, ...)
	local formatted = string.format(msg, ...)
	print(addonName .. " - " .. formatted)
end

function M:NotifyCombatLockdown()
	M:Notify(L["Can't do that during combat."])
end

function M:IsSecret(value)
	if not issecretvalue then
		return false
	end

	return issecretvalue(value)
end
