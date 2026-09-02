-- Ordered lists of real addon files shared by the test entrypoints, mirroring TOC order.
-- When a refactor adds/renames a file, update the list here once instead of in every test.

local M = {}

-- Shared framework (Libs\MiniFramework\MiniFramework.xml in the TOC). Namespace.lua must come
-- first, because it creates addon.Framework, which every other file resolves at load time.
M.framework = {
	"src/Libs/MiniFramework/Namespace.lua",
	"src/Libs/MiniFramework/Framework/Notify.lua",
	"src/Libs/MiniFramework/Framework/Tables.lua",
	"src/Libs/MiniFramework/Framework/Math.lua",
	"src/Libs/MiniFramework/Framework/SavedVars.lua",
	"src/Libs/MiniFramework/Framework/Settings.lua",
	"src/Libs/MiniFramework/Framework/Secrets.lua",
	"src/Libs/MiniFramework/Framework/Combat.lua",
	"src/Libs/MiniFramework/Framework/AddonLoad.lua",
}

-- Db defaults + migration engine + migration chunks (Config in the TOC)
M.migrator = {
	"src/Config/Defaults.lua",
	"src/Config/Migrator.lua",
	"src/Config/Migrations/V01.lua",
	"src/Config/Migrations/V13.lua",
	"src/Config/Migrations/V19.lua",
	"src/Config/Migrations/V41.lua",
	"src/Config/Migrations/V69.lua",
	"src/Config/Migrations/V74.lua",
	"src/Config/Migrations/V79.lua",
	"src/Config/Migrations/V80.lua",
	"src/Config/Migrations/V81.lua",
	"src/Config/Migrations/V82.lua",
	"src/Config/Migrations/V83.lua",
}

function M.load(files, addon)
	for _, path in ipairs(files) do
		assert(loadfile(path))("MiniAuras", addon)
	end
end

return M
