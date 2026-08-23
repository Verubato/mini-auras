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
local OPAQUE_CACHE_KEYS = { "SpecCache", "WhatsNew", "NotifiedChanges", "Profiles", "ActiveProfile", "AutoSwitch" }
-- The announcement categories whose TTS opt-out lists need the same protection.
local TTS_MUTE_CATEGORIES = { "Important", "Defensive", "EnemyDebuff" }

---The alert module's TTS options, or nil on a db that predates them.
local function TtsOptions(vars)
	return vars.Modules and vars.Modules.AlertsModule and vars.Modules.AlertsModule.TTS
end

local function SaveOpaqueCaches(vars)
	local saved = {}
	for _, key in ipairs(OPAQUE_CACHE_KEYS) do
		saved[key] = mini:CopyValueOrTable(vars[key])
	end
	-- The auras module's tracked-spell deltas are spellId -> true hashes against an empty schema,
	-- so CleanTable would strip every key; save and restore them like the top-level caches.
	local importantAurasSpells = vars.Modules and vars.Modules.ImportantAurasModule
		and vars.Modules.ImportantAurasModule.Spells
	saved._ImportantAurasDisabledSpells = importantAurasSpells and mini:CopyValueOrTable(importantAurasSpells.Disabled) or {}
	saved._ImportantAurasCustomSpells = importantAurasSpells and mini:CopyValueOrTable(importantAurasSpells.Custom) or {}
	saved._ImportantAurasEnabledSpells = importantAurasSpells and mini:CopyValueOrTable(importantAurasSpells.Enabled) or {}
	-- Custom aura groups are authored entirely by the user, so the schema has nothing to compare
	-- them against and CleanTable would strip every one of them.
	local customAuras = vars.Modules and vars.Modules.CustomAurasModule
	saved._CustomAuraGroups = customAuras and mini:CopyValueOrTable(customAuras.Groups) or {}
	-- Same shape again: a spellId -> true hash against an empty schema.
	local portrait = vars.Modules and vars.Modules.PortraitModule
	saved._PortraitCustomSpells = portrait and mini:CopyValueOrTable(portrait.CustomSpells) or {}
	-- The TTS per-spell switches are the same shape: spellId -> boolean against an empty schema.
	local tts = TtsOptions(vars)
	saved._TtsMutedSpells = {}
	for _, category in ipairs(TTS_MUTE_CATEGORIES) do
		local options = tts and tts[category]
		saved._TtsMutedSpells[category] = options and mini:CopyValueOrTable(options.MutedSpellIds) or {}
	end
	return saved
end

local function RestoreOpaqueCaches(vars, saved)
	for _, key in ipairs(OPAQUE_CACHE_KEYS) do
		vars[key] = saved[key]
	end
	local importantAurasModule = vars.Modules and vars.Modules.ImportantAurasModule
	if importantAurasModule then
		importantAurasModule.Spells = importantAurasModule.Spells or {}
		importantAurasModule.Spells.Disabled = saved._ImportantAurasDisabledSpells or {}
		importantAurasModule.Spells.Custom = saved._ImportantAurasCustomSpells or {}
		importantAurasModule.Spells.Enabled = saved._ImportantAurasEnabledSpells or {}
	end
	local customAuras = vars.Modules and vars.Modules.CustomAurasModule
	if customAuras then
		customAuras.Groups = saved._CustomAuraGroups or {}
	end
	local portrait = vars.Modules and vars.Modules.PortraitModule
	if portrait then
		portrait.CustomSpells = saved._PortraitCustomSpells or {}
	end
	local tts = TtsOptions(vars)
	if tts then
		for _, category in ipairs(TTS_MUTE_CATEGORIES) do
			if tts[category] then
				tts[category].MutedSpellIds = saved._TtsMutedSpells[category] or {}
			end
		end
	end
end

---Drops any setting the addon no longer ships from a stored profile payload, matching it against
---the same defaults CleanTable uses on the live db.
---
---An empty table in the defaults is the schema's way of saying "the user authors this" (custom
---aura groups, the spell-id hashes), so those are left whole rather than recursed into - the same
---carve-out SaveOpaqueCaches makes for the live db.
local function PruneToDefaults(value, defaults)
	if type(value) ~= "table" or type(defaults) ~= "table" or next(defaults) == nil then
		return
	end

	for key, sub in pairs(value) do
		if defaults[key] == nil then
			value[key] = nil
		else
			PruneToDefaults(sub, defaults[key])
		end
	end
end

---Applies that to every stored profile. CleanTable cannot reach them: Profiles is opaque to it,
---so a snapshot keeps whatever the addon had when it was saved. Switching to that profile writes
---the whole payload back over the live db, so without this a retired setting round-trips forever.
local function PruneRemovedSettingsFromProfiles(vars)
	if type(vars.Profiles) ~= "table" then
		return
	end

	local payloadKeys = addon.Core.ProfileManager.PayloadKeys
	local isPayloadKey = {}
	for _, key in ipairs(payloadKeys) do
		isPayloadKey[key] = true
	end

	for _, payload in pairs(vars.Profiles) do
		if type(payload) == "table" then
			-- A snapshot only ever holds payload keys, so one dropped from that list (a retired
			-- top-level setting) is as stale as a value the defaults no longer describe.
			for key in pairs(payload) do
				if not isPayloadKey[key] then
					payload[key] = nil
				end
			end
			for _, key in ipairs(payloadKeys) do
				PruneToDefaults(payload[key], dbDefaults[key])
			end
		end
	end
end

---Seeds MiniAurasDB from the MiniCC-era saved variable the first time the renamed addon runs.
---MiniCCDB is loaded by the stub MiniCC folder we still ship, which the toc lists as an
---optional dependency so it loads first. The old table is copied rather than adopted, so
---rolling back to MiniCC leaves the user's old settings intact.
---TEMPORARY: goes away with the stub folder once MiniCCDB is dropped.
local function AdoptLegacyDb()
	if MiniAurasDB ~= nil or type(MiniCCDB) ~= "table" then
		return
	end

	MiniAurasDB = mini:CopyTable(MiniCCDB)
end

---@return Db
function M:GetAndUpgradeDb()
	AdoptLegacyDb()

	local isFirstTimeSetup = MiniAurasDB == nil

	if isFirstTimeSetup then
		local vars = mini:GetSavedVars(dbDefaults)

		-- Reaching first-time setup means AdoptLegacyDb found no MiniCCDB, and the adoption
		-- above never runs again once MiniAurasDB exists. If the old table was merely not
		-- loaded (bridge disabled, out of date or missing), it can still surface on a later
		-- login; this flag is what lets LegacyAddon offer it for import then.
		vars.MissedLegacyImport = true

		return vars
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
		PruneRemovedSettingsFromProfiles(vars)
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
	PruneRemovedSettingsFromProfiles(vars)

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
