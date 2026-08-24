local _, addon = ...
local M = addon.Framework

---Deep merge-copies src into dst, only filling keys that are nil in dst.
---@return table dst
function M:CopyTable(src, dst)
	if type(dst) ~= "table" then
		dst = {}
	end

	for k, v in pairs(src) do
		if type(v) == "table" then
			dst[k] = M:CopyTable(v, dst[k])
		elseif dst[k] == nil then
			dst[k] = v
		end
	end

	return dst
end

---Returns src verbatim for non-tables, otherwise a deep clone.
function M:CopyValueOrTable(src)
	if type(src) ~= "table" then
		return src
	end

	return M:CopyTable(src)
end

---Reverses the array in place and returns it.
function M:Reverse(array)
	local i, j = 1, #array

	while i < j do
		array[i], array[j] = array[j], array[i]
		i = i + 1
		j = j - 1
	end

	return array
end

---Appends all elements of src to the end of dst.
function M:Append(src, dst)
	for i = 1, #src do
		dst[#dst + 1] = src[i]
	end
end

---Removes any erronous values from the options table.
---An empty table in the template says the user authors its contents, so it is left whole.
---@param target table the target table to clean
---@param template table what the table should look like
---@param cleanValues any whether or not to clean values (both table and non-table)
---@param recurse any whether to recursively clean the table
function M:CleanTable(target, template, cleanValues, recurse)
	-- remove values that aren't ours
	if type(target) ~= "table" or type(template) ~= "table" then
		return
	end

	for key, value in pairs(target) do
		local templateValue = template[key]

		-- Remove unknown keys or keys with wrong types when cleanValues is true
		if cleanValues and templateValue == nil then
			target[key] = nil
		elseif cleanValues and type(value) == "table" and type(templateValue) ~= "table" then
			-- type mismatch: reset this key to default
			target[key] = templateValue
		elseif recurse and type(value) == "table" and type(templateValue) == "table" and next(templateValue) ~= nil then
			-- Recursively clean nested tables
			M:CleanTable(value, templateValue, cleanValues, recurse)
		end
	end
end
