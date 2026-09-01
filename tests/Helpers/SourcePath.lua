-- Turns an in-game asset path back into the repo file behind it, so a suite can check that what
-- the addon points at is actually shipped.

---@param asset string
---@return string?
return function(asset)
	local within = asset:match("\\AddOns\\[^\\]+\\(.+)$")

	return within and ("src/" .. within:gsub("\\", "/"))
end
