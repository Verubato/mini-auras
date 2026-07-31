-- Ordered lists of real addon files shared by the test entrypoints, mirroring TOC order.
-- When a refactor adds/renames a file, update the list here once instead of in every test.

local M = {}

-- Core framework (Core\Framework in the TOC)
M.framework = {
	"src/Core/Framework/Notify.lua",
	"src/Core/Framework/Tables.lua",
	"src/Core/Framework/Math.lua",
	"src/Core/Framework/SavedVars.lua",
	"src/Core/Framework/Settings.lua",
	"src/Core/Framework/AddonLoad.lua",
}

-- Db defaults + migration engine + migration chunks (Config in the TOC)
M.migrator = {
	"src/Config/Defaults.lua",
	"src/Config/Migrator.lua",
	"src/Config/Migrations/V01.lua",
	"src/Config/Migrations/V13.lua",
	"src/Config/Migrations/V19.lua",
	"src/Config/Migrations/V41.lua",
}

function M.load(files, addon)
	for _, path in ipairs(files) do
		assert(loadfile(path))("MiniCC", addon)
	end
end

return M
