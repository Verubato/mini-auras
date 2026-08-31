local addonName, addon = ...
local M = addon.Framework

local function NilKeys(target, template)
	for k, v in pairs(target) do
		local templateValue = template and template[k]

		if type(v) == "table" and type(templateValue) == "table" then
			-- An empty template says the user authors this table, so a reset leaves what they wrote.
			if next(templateValue) ~= nil then
				-- Closures elsewhere hold references into these tables, so the instance stays.
				NilKeys(v, templateValue)
			end
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

	_G[name] = vars

	NilKeys(vars, defaults)

	if defaults then
		return M:CopyTable(defaults, vars)
	end

	return vars
end
