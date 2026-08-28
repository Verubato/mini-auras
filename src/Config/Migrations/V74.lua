---@diagnostic disable: unused-function
local _, addon = ...
local L = addon.L
local M = addon.Config.Migrator

-- This step has to keep moving the same twelve tables whatever a later version renames.
local RENAMED_MODULES = {
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

-- Every table that carried a ShowCC switch, under the module names the rename above leaves behind.
local SHOW_CC_OWNERS = {
	{ "Nameplates", "Friendly", "Bar1" },
	{ "Nameplates", "Friendly", "Bar2" },
	{ "Nameplates", "Enemy", "Bar1" },
	{ "Nameplates", "Enemy", "Bar2" },
	{ "ImportantAuras", "Default" },
	{ "ImportantAuras", "Raid" },
	{ "FrameAuras", "Debuffs" },
}

-- The alerts grow directions this step moves between, frozen so a later change to the shipped
-- default cannot move what it decided.
local PREVIOUS_ALERTS_GROW = "RIGHT"
local CENTRED_ALERTS_GROW = "CENTER"
-- LibSharedMedia carries its own "None" entry as the number 1, and the engine takes a file name,
-- so a sound left on it played nothing.
local LSM_NONE = "None"
-- "File" is the pre-split key, which Groups folds onto Applied, so it has to be caught here or
-- the fold puts the entry back.
local PERSONAL_AURA_SOUND_KEYS = { "Applied", "Stacks", "Removed", "File" }

---Moves one key's value onto another and drops the old key.
---@param owner table The table holding both keys.
local function MoveKey(owner, from, to)
	if owner[from] == nil then
		return
	end

	-- Only when the new key is untaken: a table already carrying one has been through this step,
	-- and the old key beside it is the stale half.
	if owner[to] == nil then
		owner[to] = owner[from]
	end

	owner[from] = nil
end

local function Resolve(modules, path)
	local owner = modules

	for _, key in ipairs(path) do
		if type(owner) ~= "table" then
			return nil
		end

		owner = owner[key]
	end

	return type(owner) == "table" and owner or nil
end

---Spells CC out in full in the settings nested under a module. Public because an exported string
---with no version stamp cannot be replayed through the chain, so the import repairs it by hand.
---@param vars table The live saved variables, or one profile's snapshot of them.
function M:SpellOutCrowdControlKeys(vars)
	local modules = vars and vars.Modules

	if type(modules) ~= "table" then
		return
	end

	for _, path in ipairs(SHOW_CC_OWNERS) do
		local owner = Resolve(modules, path)

		if owner then
			MoveKey(owner, "ShowCC", "ShowCrowdControl")
		end
	end

	local nameplates = modules.Nameplates

	if type(nameplates) == "table" then
		MoveKey(nameplates, "CCColor", "CrowdControlColor")
	end
end

---Drops the "Module" suffix from every module key and spells CC out in full.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function RenameModuleKeys(vars)
	local modules = vars and vars.Modules

	if type(modules) ~= "table" then
		return
	end

	for _, rename in ipairs(RENAMED_MODULES) do
		MoveKey(modules, rename[1], rename[2])
	end

	M:SpellOutCrowdControlKeys(vars)
end

function M:UpgradeToVersion74(vars)
	if vars.Version ~= 73 then return false end

	RenameModuleKeys(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still holding
	-- the old keys would put them straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			RenameModuleKeys(profile)
		end
	end

	vars.Version = 74
	return true
end

function M:UpgradeToVersion75(vars)
	if vars.Version ~= 74 then return false end

	local locale = GetLocale()
	local note

	-- Only the locales a pack is offered to get a note; the silence elsewhere is deliberate.
	if locale == "koKR" then
		note = L["There is now a Korean voice pack for the alert announcements: MiniAuras - Korean Voice Pack, on CurseForge. Install it to hear the spell names spoken in Korean."]
	elseif locale == "frFR" then
		note = L["There is now a French voice pack for the alert announcements: MiniAuras - French Voice Pack, on CurseForge. Install it to hear the spell names spoken in French."]
	elseif locale == "esES" or locale == "esMX" then
		note = L["There is now a Spanish voice pack for the alert announcements: MiniAuras - Spanish Voice Pack, on CurseForge. Install it to hear the spell names spoken in Spanish."]
	elseif locale == "zhCN" or locale == "zhTW" then
		note = L["The Mandarin voices Amy, Anna Su, and Jason Chen have moved into their own addon: MiniAuras - Chinese Voice Pack, on CurseForge. Install it to keep using them."]
	end

	if note then
		vars.WhatsNew = vars.WhatsNew or {}
		table.insert(vars.WhatsNew, note)
		vars.NotifiedChanges = false
	end

	vars.Version = 75
	return true
end

function M:UpgradeToVersion76(vars)
	if vars.Version ~= 75 then return false end

	vars.WhatsNew = vars.WhatsNew or {}
	table.insert(vars.WhatsNew, L["Tired of Blizzard buffs and debuffs overlapping on raid frames? Enable the new Frame Auras module to fix it."])
	vars.NotifiedChanges = false

	vars.Version = 76
	return true
end

---Moves the alerts bars onto the centred default. Anything other than the old shipped value is a
---direction the player chose, so it stays.
---@param vars table The live saved variables, or one profile's snapshot of them.
local function AdoptCentredAlerts(vars)
	local alerts = vars and vars.Modules and vars.Modules.Alerts

	if alerts and alerts.Grow == PREVIOUS_ALERTS_GROW then
		alerts.Grow = CENTRED_ALERTS_GROW
	end
end

function M:UpgradeToVersion77(vars)
	if vars.Version ~= 76 then return false end

	AdoptCentredAlerts(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still holding
	-- the old direction would put it straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			AdoptCentredAlerts(profile)
		end
	end

	vars.Version = 77
	return true
end

---The sound list no longer offers a name that cannot play, and the resolver falls back to the
---shipped default, so a setting left naming it would start making a noise nobody asked for.
---@param sound table? A settings table holding Enabled and File.
local function AdoptSilenceSwitch(sound)
	if sound and sound.File == LSM_NONE then
		sound.Enabled = false
		sound.File = nil
	end
end

---@param vars table The live saved variables, or one profile's snapshot of them.
local function AdoptExplicitSilence(vars)
	local modules = vars and vars.Modules

	if not modules then
		return
	end

	local alerts = modules.Alerts and modules.Alerts.Sound

	if alerts then
		AdoptSilenceSwitch(alerts.Important)
		AdoptSilenceSwitch(alerts.Defensive)
	end

	AdoptSilenceSwitch(modules.HealerCrowdControl and modules.HealerCrowdControl.Sound)

	local personalAuras = modules.PersonalAuras

	for _, group in ipairs(personalAuras and personalAuras.Groups or {}) do
		local sound = group.Sound

		if sound then
			for _, key in ipairs(PERSONAL_AURA_SOUND_KEYS) do
				-- Empty is this module's own silent value, and the dropdown still offers that row.
				if sound[key] == LSM_NONE then
					sound[key] = ""
				end
			end
		end
	end
end

function M:UpgradeToVersion78(vars)
	if vars.Version ~= 77 then return false end

	AdoptExplicitSilence(vars)

	-- A profile switch writes its snapshot back over the live db wholesale, so one still naming
	-- the entry would put it straight back.
	if vars.Profiles then
		for _, profile in pairs(vars.Profiles) do
			AdoptExplicitSilence(profile)
		end
	end

	vars.Version = 78
	return true
end
