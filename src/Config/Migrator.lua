---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local dbDefaults = addon.Config.Defaults

---@class DbMigrator
local M = {}
addon.Config.Migrator = M

-- Opaque per-player caches that CleanTable must not recurse into.
-- "Profiles", "ActiveProfile", and "AutoSwitch" are included here because CleanTable
-- would otherwise wipe all stored profile snapshots (profile names are unknown keys
-- relative to the dbDefaults.Profiles = {} template).
local OPAQUE_CACHE_KEYS = { "SpecCache", "TalentCache", "PvPTalentCache", "WhatsNew", "NotifiedChanges", "Profiles", "ActiveProfile", "AutoSwitch" }

local function SaveOpaqueCaches(vars)
	local saved = {}
	for _, key in ipairs(OPAQUE_CACHE_KEYS) do
		saved[key] = mini:CopyValueOrTable(vars[key])
	end
	-- DisabledSpells is a user-edited hash (spellId -> true) nested inside the module options.
	-- CleanTable would strip all SpellId keys because none are in the empty-table schema, so
	-- we save and restore each module's DisabledSpells the same way as top-level opaque caches.
	local fcdModule = vars.Modules and vars.Modules.FriendlyCooldownTrackerModule
	saved._FcdDisabledSpells = fcdModule and mini:CopyValueOrTable(fcdModule.DisabledSpells) or {}
	local ecdModule = vars.Modules and vars.Modules.EnemyCooldownTrackerModule
	saved._EcdDisabledSpells = ecdModule and mini:CopyValueOrTable(ecdModule.DisabledSpells) or {}
	-- Same shape again: the friendly indicator's tracked-spell deltas are spellId -> true hashes
	-- against an empty schema, so they would be cleaned away too.
	local fiSpells = vars.Modules and vars.Modules.FriendlyIndicatorModule
		and vars.Modules.FriendlyIndicatorModule.Spells
	saved._FiDisabledSpells = fiSpells and mini:CopyValueOrTable(fiSpells.Disabled) or {}
	saved._FiCustomSpells = fiSpells and mini:CopyValueOrTable(fiSpells.Custom) or {}
	return saved
end

local function RestoreOpaqueCaches(vars, saved)
	for _, key in ipairs(OPAQUE_CACHE_KEYS) do
		vars[key] = saved[key]
	end
	local fcdModule = vars.Modules and vars.Modules.FriendlyCooldownTrackerModule
	if fcdModule then
		fcdModule.DisabledSpells = saved._FcdDisabledSpells or {}
	end
	local ecdModule = vars.Modules and vars.Modules.EnemyCooldownTrackerModule
	if ecdModule then
		ecdModule.DisabledSpells = saved._EcdDisabledSpells or {}
	end
	local fiModule = vars.Modules and vars.Modules.FriendlyIndicatorModule
	if fiModule then
		fiModule.Spells = fiModule.Spells or {}
		fiModule.Spells.Disabled = saved._FiDisabledSpells or {}
		fiModule.Spells.Custom = saved._FiCustomSpells or {}
	end
end

---@return Db
function M:GetAndUpgradeDb()
	local isFirstTimeSetup = MiniCCDB == nil

	if isFirstTimeSetup then
		return mini:GetSavedVars(dbDefaults)
	end

	local vars = mini:GetSavedVars()

	if vars.Version and vars.Version > dbDefaults.Version then
		-- they are running some version ahead of us, let's reset to factory
		return M:SoftReset()
	end

	local isCorrupt = false

	while (vars.Version or 0) < dbDefaults.Version do
		local currentVersion = vars.Version or 0
		local nextVersion = currentVersion + 1
		local upgradeFn = M["UpgradeToVersion" .. nextVersion]

		isCorrupt = upgradeFn == nil

		if isCorrupt then
			break
		end

		local ok, result = pcall(upgradeFn, self, vars)

		if not ok or not result then
			isCorrupt = true
			break
		end
	end

	if isCorrupt then
		return M:SoftReset()
	end

	-- grab any new keys
	vars = mini:GetSavedVars(dbDefaults)

	if vars.Version == dbDefaults.Version then
		-- if we are running the latest version, clean up any garbage that may have been left over from old versions
		local caches = SaveOpaqueCaches(vars)
		mini:CleanTable(vars, dbDefaults, true, true)
		RestoreOpaqueCaches(vars, caches)
	end

	return vars
end

---Fills any missing keys in the live db from dbDefaults without overwriting existing values.
---Call this after a profile switch to ensure all settings have a value.
function M:FillDefaults()
	mini:GetSavedVars(dbDefaults)
end

---Returns a deep copy of the Modules portion of dbDefaults.
---Used by ProfileManager to reset a profile while preserving live table identities.
function M:GetModuleDefaults()
	return mini:CopyTable(dbDefaults.Modules, {})
end

---@return Db
function M:ResetToFactory()
	return mini:ResetSavedVars(dbDefaults)
end

function M:SoftReset()
	-- grab any new keys
	local vars = mini:GetSavedVars(dbDefaults)

	-- clean up any garbage
	local caches = SaveOpaqueCaches(vars)
	mini:CleanTable(vars, dbDefaults, true, true)
	RestoreOpaqueCaches(vars, caches)

	-- The default-merge above only fills MISSING keys, so a stale Version (from a corrupt
	-- migration chain or a db written by a newer addon version) would survive - leaving the
	-- future-version case soft-resetting on every single login. The data now matches the
	-- current schema, so stamp it as such.
	vars.Version = dbDefaults.Version

	return vars
end

---@return boolean true if any deferred migrations were applied
function M:RunDeferredMigrations(vars)
	local applied = false

	if vars.PendingScaleMigration26 then
		local scale = UIParent:GetScale()
		if vars.Modules then
			local ccModule = vars.Modules.CCModule
			if ccModule then
				if ccModule.Default and ccModule.Default.Icons and ccModule.Default.Icons.Size then
					ccModule.Default.Icons.Size = math.floor(ccModule.Default.Icons.Size * scale + 0.5)
				end
				if ccModule.Raid and ccModule.Raid.Icons and ccModule.Raid.Icons.Size then
					ccModule.Raid.Icons.Size = math.floor(ccModule.Raid.Icons.Size * scale + 0.5)
				end
			end
			local petCCModule = vars.Modules.PetCCModule
			if petCCModule and petCCModule.Icons and petCCModule.Icons.Size then
				petCCModule.Icons.Size = math.floor(petCCModule.Icons.Size * scale + 0.5)
			end
		end
		vars.PendingScaleMigration26 = nil
		applied = true
	end

	return applied
end
