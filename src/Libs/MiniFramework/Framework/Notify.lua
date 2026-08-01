local addonName, addon = ...
local M = addon.Framework
local L = M.L

---Prints a chat message prefixed with the addon name.
function M:Notify(msg, ...)
	local formatted = string.format(msg, ...)
	print(addonName .. " - " .. formatted)
end

---Prints the standard "can't do that in combat" message.
function M:NotifyCombatLockdown()
	M:Notify(L["Can't do that during combat."])
end
