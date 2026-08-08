local addonName, addon = ...
local M = addon.Framework
local L = M.L

-- Chat colour for the addon-name prefix (RRGGBB). An addon can override this before its first
-- notify to brand the prefix.
M.NotifyColor = M.NotifyColor or "ffd100"

---Prints a plain chat message with no addon-name prefix.
function M:Notify(msg, ...)
	print(string.format(msg, ...))
end

---Prints a chat message prefixed with the coloured addon name.
function M:NotifyWithPrefix(msg, ...)
	print("|cff" .. M.NotifyColor .. addonName .. "|r - " .. string.format(msg, ...))
end

---Prints the standard "can't do that in combat" message.
function M:NotifyCombatLockdown()
	M:NotifyWithPrefix(L["Can't do that during combat."])
end
