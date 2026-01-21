---@diagnostic disable: lowercase-global
local config = {
	std = "lua51",

	ignore = {
		-- line is too long
		"631",
		-- unused self argument
		"212",
		-- undefined globals
		"111",
		"112",
		"113"
	},
}

return config
