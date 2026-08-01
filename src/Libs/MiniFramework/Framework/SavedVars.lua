local addonName, addon = ...
local M = addon.Framework

local function NilKeys(target)
	for k, v in pairs(target) do
		if type(v) == "table" then
			NilKeys(v)
		else
			target[k] = nil
		end
	end
end

---Returns the account-wide saved variables table (`<AddonName>DB`), merging in defaults.
---The name must be declared in the addon's toc via `## SavedVariables`.
function M:GetSavedVars(defaults)
	local name = addonName .. "DB"
	local vars = _G[name] or {}

	_G[name] = vars

	if defaults then
		return M:CopyTable(defaults, vars)
	end

	return vars
end

---Returns the per-character saved variables table (`<AddonName>CharDB`), merging in defaults.
---The name must be declared in the addon's toc via `## SavedVariablesPerCharacter`.
function M:GetCharacterSavedVars(defaults)
	local name = addonName .. "CharDB"
	local vars = _G[name] or {}

	_G[name] = vars

	if defaults then
		return M:CopyTable(defaults, vars)
	end

	return vars
end

---Clears the account-wide saved variables back to defaults.
---@return table the same table instance, so existing references stay valid
function M:ResetSavedVars(defaults)
	local name = addonName .. "DB"
	local vars = _G[name] or {}

	-- don't create a new table because we're referencing that in the addon
	-- instead clear the existing keys and return the same instance (if one existed to begin with)
	NilKeys(vars)

	if defaults then
		return M:CopyTable(defaults, vars)
	end

	return vars
end
