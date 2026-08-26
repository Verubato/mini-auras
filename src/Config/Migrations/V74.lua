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
