---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local dbDefaults = addon.Config.Defaults

---@class DbMigrator
local M = {}
addon.Config.Migrator = M

-- Import and export shipped in version 24. Nothing genuine is stamped below it, and the steps
-- before it clean and rebind against the live saved variables rather than the table handed in.
local OLDEST_IMPORTABLE_VERSION = 24
-- Every module key a migration has renamed, oldest first so a chain collapses in one pass.
local RENAMED_MODULE_KEYS = {
	{ "CcModule", "CCModule" },
	{ "HealerCcModule", "HealerCCModule" },
	{ "PrecogGuesserModule", "PrecogModule" },
	{ "KickTimerModule", "EnemyKickTrackerModule" },
	{ "FriendlyIndicatorModule", "AurasModule" },
	{ "AurasModule", "RaidFrameAurasModule" },
	{ "RaidFrameAurasModule", "ImportantAurasModule" },
	{ "CustomAurasModule", "PersonalAurasModule" },
	-- Version 74 dropped the "Module" suffix every key carried and spelled CC out in full.
	{ "CCModule", "CrowdControl" },
	{ "PetCCModule", "PetCrowdControl" },
	{ "HealerCCModule", "HealerCrowdControl" },
	{ "PortraitModule", "Portrait" },
	{ "AlertsModule", "Alerts" },
	{ "NameplatesModule", "Nameplates" },
	{ "EnemyKickTrackerModule", "EnemyKickTracker" },
	{ "AllyKickTrackerModule", "AllyKickTracker" },
	{ "TrinketsModule", "Trinkets" },
	{ "ImportantAurasModule", "ImportantAuras" },
	{ "FrameAurasModule", "FrameAuras" },
	{ "PersonalAurasModule", "PersonalAuras" },
}

---Drops any setting the addon no longer ships from a stored profile payload, matching it against
---the same defaults CleanTable uses on the live db.
---
---An empty table in the defaults is the schema's way of saying "the user authors this", so those
---are left whole rather than recursed into.
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
			-- A snapshot only ever holds payload keys, so one dropped from that list is as stale as
			-- a value the defaults no longer describe.
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
---MiniCCDB comes from the stub MiniCC folder, which the toc lists as an optional dependency so it
---loads first. The old table is copied, so rolling back to MiniCC leaves the old settings intact.
---Temporary, until the stub folder and MiniCCDB are dropped.
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

		-- Adoption never runs again once MiniAurasDB exists. MiniCCDB can still surface on a later
		-- login if it was merely not loaded, and this flag is what lets LegacyAddon offer it then.
		vars.MissedLegacyImport = true

		return vars
	end

	local vars = mini:GetSavedVars()

	if vars.Version and vars.Version > dbDefaults.Version then
		-- A db stamped ahead of what we ship cannot be migrated down.
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
		-- Clean up any garbage left over from old versions.
		mini:CleanTable(vars, dbDefaults, true, true)
		PruneRemovedSettingsFromProfiles(vars)
	end

	return vars
end

---Runs the upgrade chain over an imported profile payload, from the version its export stamped
---to the one the addon ships. A whole saved-vars table is accepted too, and comes back cut down
---to the keys a profile carries.
---@param payload table The decoded payload, rewritten in place on success.
---@param fromVersion number? The db version the exporting build was on.
---@return boolean applied False leaves the payload untouched.
---@return boolean isNewer Whether it was refused for being stamped ahead of what we ship.
function M:MigrateProfilePayload(payload, fromVersion)
	if type(payload) ~= "table" or type(fromVersion) ~= "number" then
		return false, false
	end

	if fromVersion > dbDefaults.Version then
		return false, true
	end

	if fromVersion < OLDEST_IMPORTABLE_VERSION then
		return false, false
	end

	-- Migrated on a copy so a step that throws half way cannot leave the payload part upgraded.
	local working = mini:CopyValueOrTable(payload)
	working.Version = fromVersion
	-- Steps up to 39 append to this without checking it is there, and a profile does not carry it.
	working.WhatsNew = working.WhatsNew or {}

	while working.Version < dbDefaults.Version do
		local from = working.Version
		local upgradeFn = M["UpgradeToVersion" .. (from + 1)]

		if not upgradeFn then
			return false, false
		end

		local ok, result = pcall(upgradeFn, self, working)

		-- A step reporting success without moving the version has not done what it says, and the
		-- loop would call it forever.
		if not ok or not result or working.Version ~= from + 1 then
			return false, false
		end
	end

	-- Deferred on the live db because the UI scale is not readable at login. An import happens
	-- long after that, so it can be settled here.
	M:RunDeferredMigrations(working)

	for key in pairs(payload) do
		payload[key] = nil
	end

	-- Steps write outside a profile's slice, so only the payload keys come back.
	for _, key in ipairs(addon.Core.ProfileManager.PayloadKeys) do
		if working[key] ~= nil then
			payload[key] = working[key]
		end
	end

	return true, false
end

---Moves a profile payload's settings onto the names the addon uses now. For a string exported
---before the version stamp, where the migrations cannot be replayed.
---@param payload table? One profile's snapshot of the saved variables.
function M:RenameLegacyModuleKeys(payload)
	local modules = payload and payload.Modules

	if type(modules) ~= "table" then
		return
	end

	for _, rename in ipairs(RENAMED_MODULE_KEYS) do
		local from, to = rename[1], rename[2]

		if modules[from] ~= nil then
			-- A payload carrying both names has already been through this, so the old key beside
			-- the new one is the stale half.
			if modules[to] == nil then
				modules[to] = modules[from]
			end

			modules[from] = nil
		end
	end

	-- The prune on the next login drops any CC key still under its old name.
	M:SpellOutCrowdControlKeys(payload)
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

	mini:CleanTable(vars, dbDefaults, true, true)
	PruneRemovedSettingsFromProfiles(vars)

	-- The default-merge above only fills missing keys, so a stale Version would survive and leave
	-- the future-version case soft-resetting on every login. The data matches the current schema
	-- now, so stamp it as such.
	vars.Version = dbDefaults.Version

	return vars
end

---@return boolean true if any deferred migrations were applied
function M:RunDeferredMigrations(vars)
	local applied = false

	if vars.Pending and vars.Pending.ScaleMigration26 then
		local scale = UIParent:GetScale()
		if vars.Modules then
			local crowdControl = vars.Modules.CrowdControl
			if crowdControl then
				if crowdControl.Default and crowdControl.Default.Icons and crowdControl.Default.Icons.Size then
					crowdControl.Default.Icons.Size = math.floor(crowdControl.Default.Icons.Size * scale + 0.5)
				end
				if crowdControl.Raid and crowdControl.Raid.Icons and crowdControl.Raid.Icons.Size then
					crowdControl.Raid.Icons.Size = math.floor(crowdControl.Raid.Icons.Size * scale + 0.5)
				end
			end
			local petCrowdControl = vars.Modules.PetCrowdControl
			if petCrowdControl and petCrowdControl.Icons and petCrowdControl.Icons.Size then
				petCrowdControl.Icons.Size = math.floor(petCrowdControl.Icons.Size * scale + 0.5)
			end
		end
		vars.Pending.ScaleMigration26 = nil
		applied = true
	end

	return applied
end
