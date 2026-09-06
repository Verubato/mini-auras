---@type string, Addon
local _, addon = ...

-- Shared by both kick trackers, which paint an interrupter in their class colour.

---@class KickColors
local M = {}

addon.Core.KickColors = M

---The kicker's class colour. The class token is secret inside an instance and a table cannot be
---keyed by a secret, so the colour comes from the API call, which takes one. The colour handed
---back is itself secret, which a widget setter accepts and arithmetic on it does not.
---@param class string?
---@return table?
function M:ClassColor(class)
	if class == nil then
		return nil
	end

	if C_ClassColor and C_ClassColor.GetClassColor then
		return C_ClassColor.GetClassColor(class)
	end

	-- Nothing but an old client gets here, where the token is never secret to begin with.
	if issecretvalue(class) then
		return nil
	end

	return RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] or nil
end
