-- Tests for Core/ProfileManager.lua against the REAL MiniFramework + Migrator (genuine
-- default db and merge semantics). The profile system's core contracts:
--   * switching swaps payload values while PRESERVING table identities (config-UI closures
--     capture nested tables at Build time and must stay valid),
--   * profile data survives Migrator soft resets (opaque-cache round-trip),
--   * every payload key is healable from dbDefaults (FillDefaults),
--   * lifecycle operations (create/delete/rename/auto-switch) keep the db consistent.

local fw = require("framework")
local wow = require("wow_api")
wow.setup()
local acm = require("aura_container_mock")
acm.setup()
acm.reset()

-- Environment

local inCombat = false
_G.InCombatLockdown = function()
	return inCombat
end
_G.UnitName = function()
	return "Tester"
end
_G.GetRealmName = function()
	return "TestRealm"
end
local currentSpecId = nil
_G.GetSpecialization = function()
	return currentSpecId and 1 or nil
end
_G.GetSpecializationInfo = function()
	return currentSpecId
end
_G.MiniCCDB = nil

local refreshCount = 0
local addon = {
	Utils = {},
	Core = {},
	Modules = {},
	Config = {},
	L = setmetatable({}, {
		__index = function(_, key)
			return key
		end,
	}),
	Refresh = function()
		refreshCount = refreshCount + 1
	end,
}

assert(loadfile("src/Core/Framework/Framework.lua"))("MiniCC", addon)
assert(loadfile("src/Core/Framework/Tables.lua"))("MiniCC", addon)
assert(loadfile("src/Core/Framework/Math.lua"))("MiniCC", addon)
assert(loadfile("src/Core/Framework/SavedVars.lua"))("MiniCC", addon)
assert(loadfile("src/Core/Framework/Settings.lua"))("MiniCC", addon)
assert(loadfile("src/Core/Framework/AddonLoad.lua"))("MiniCC", addon)

-- Queueing scheduler so the combat-deferral path is observable.
local combatQueue = {}
addon.Utils.Scheduler = {
	Init = function() end,
	RunWhenCombatEnds = function(_, fn)
		combatQueue[#combatQueue + 1] = fn
	end,
}

assert(loadfile("src/Core/ProfileManager.lua"))("MiniCC", addon)
assert(loadfile("src/Config/Migrator.lua"))("MiniCC", addon)

local profileManager = addon.Core.ProfileManager
local migrator = addon.Config.Migrator

local db = migrator:GetAndUpgradeDb()
profileManager:Init()
local specEvents = acm.lastFrameForEvent("PLAYER_SPECIALIZATION_CHANGED")
assert(specEvents, "profile manager event frame")

fw.describe("ProfileManager - payload invariants", function()
	fw.it("every payload key exists in the default schema (FillDefaults can heal it)", function()
		_G.MiniCCDB = nil
		local fresh = migrator:GetAndUpgradeDb()
		for _, key in ipairs(profileManager.PayloadKeys) do
			assert(fresh[key] ~= nil, "payload key missing from dbDefaults: " .. key)
		end
		_G.MiniCCDB = db -- restore the live db for the remaining tests
	end)

	fw.it("Init seeded a complete Default profile", function()
		assert(db.ActiveProfile == "Default")
		local slot = db.Profiles.Default
		assert(slot, "Default profile exists")
		for _, key in ipairs(profileManager.PayloadKeys) do
			assert(slot[key] ~= nil, "snapshot missing payload key: " .. key)
		end
	end)
end)

fw.describe("ProfileManager - switching", function()
	fw.it("round-trips values and preserves nested table identities", function()
		-- Snapshot current state into a second profile, then diverge the live db.
		profileManager:CreateProfile("Alt", nil)
		db.FontScale = 1.4
		db.Modules.CCModule.Default.Icons.Size = 48

		-- References captured "at Build time" by config UI closures.
		local modulesRef = db.Modules
		local iconsRef = db.Modules.CCModule.Default.Icons

		profileManager:SwitchProfile("Alt")
		assert(db.ActiveProfile == "Alt")
		assert(db.FontScale ~= 1.4, "Alt restored the pre-divergence FontScale")
		assert(iconsRef.Size ~= 48, "Alt restored the pre-divergence icon size")
		assert(db.Modules == modulesRef, "db.Modules identity preserved")
		assert(db.Modules.CCModule.Default.Icons == iconsRef, "nested table identity preserved")

		-- Switching saved the divergent state into Default; switching back restores it.
		profileManager:SwitchProfile("Default")
		assert(db.FontScale == 1.4 and iconsRef.Size == 48, "Default kept the divergent values")
		assert(db.Modules == modulesRef and db.Modules.CCModule.Default.Icons == iconsRef, "identities stable across both switches")
	end)

	fw.it("fires callbacks and a refresh on switch", function()
		local firedWith
		profileManager:RegisterOnProfileChanged("test", function(name)
			firedWith = name
		end)
		local refreshesBefore = refreshCount
		profileManager:SwitchProfile("Alt")
		assert(firedWith == "Alt", "callback got the new profile name")
		assert(refreshCount > refreshesBefore, "addon refresh triggered")

		profileManager:UnregisterOnProfileChanged("test")
		firedWith = nil
		profileManager:SwitchProfile("Default")
		assert(firedWith == nil, "unregistered callback must not fire")
	end)

	fw.it("defers a combat switch until combat ends", function()
		inCombat = true
		profileManager:SwitchProfile("Alt")
		assert(db.ActiveProfile == "Default", "no switch during combat")
		assert(#combatQueue == 1, "switch queued for combat end")

		inCombat = false
		combatQueue[1]()
		combatQueue = {}
		assert(db.ActiveProfile == "Alt", "queued switch applied after combat")
		profileManager:SwitchProfile("Default")
	end)

	fw.it("heals payload keys missing from an old snapshot", function()
		-- Simulate a profile saved by an older addon version lacking a newer key.
		db.Profiles.Alt.FadeWithParent = nil
		profileManager:SwitchProfile("Alt")
		assert(db.FadeWithParent ~= nil, "FillDefaults restored the missing key")
		profileManager:SwitchProfile("Default")
	end)
end)

fw.describe("ProfileManager - lifecycle operations", function()
	fw.it("CreateProfile copies a source deeply (no shared tables)", function()
		profileManager:CreateProfile("Copy", "Alt")
		assert(db.Profiles.Copy, "copy created")
		db.Profiles.Copy.Modules.CCModule.Default.Icons.Size = 999
		assert(db.Profiles.Alt.Modules.CCModule.Default.Icons.Size ~= 999, "source unaffected by mutating the copy")
	end)

	fw.it("CreateProfile refuses duplicates and empty names", function()
		local before = #profileManager:GetProfileNames()
		profileManager:CreateProfile("Copy", nil)
		profileManager:CreateProfile("", nil)
		assert(#profileManager:GetProfileNames() == before, "no new profiles created")
	end)

	fw.it("RenameProfile moves the slot and updates active/auto-switch references", function()
		profileManager:SetAutoSwitchRule(250, "Copy")
		profileManager:RenameProfile("Copy", "Renamed")
		assert(db.Profiles.Renamed and db.Profiles.Copy == nil, "slot moved")
		assert(profileManager:GetAutoSwitchRule(250) == "Renamed", "auto-switch rule updated")

		-- Refuses to clobber an existing profile.
		profileManager:RenameProfile("Renamed", "Alt")
		assert(db.Profiles.Renamed and db.Profiles.Alt, "collision refused")
	end)

	fw.it("DeleteProfile clears auto-switch rules and refuses the last profile", function()
		profileManager:DeleteProfile("Renamed")
		assert(db.Profiles.Renamed == nil, "profile deleted")
		assert(profileManager:GetAutoSwitchRule(250) == nil, "auto-switch rule for deleted profile cleared")

		profileManager:DeleteProfile("Alt")
		assert(#profileManager:GetProfileNames() == 1, "one profile left")
		local last = profileManager:GetProfileNames()[1]
		profileManager:DeleteProfile(last)
		assert(db.Profiles[last], "the last profile cannot be deleted")
	end)

	fw.it("deleting the ACTIVE profile switches to a remaining one", function()
		profileManager:CreateProfile("Doomed", nil)
		profileManager:SwitchProfile("Doomed")
		db.FontScale = 0.77
		profileManager:DeleteProfile("Doomed")
		assert(db.Profiles.Doomed == nil, "active profile deleted")
		assert(db.ActiveProfile ~= "Doomed", "switched away")
		assert(db.FontScale ~= 0.77, "remaining profile's payload applied")
	end)
end)

fw.describe("ProfileManager - auto switch", function()
	fw.it("spec change applies the matching per-character rule", function()
		profileManager:CreateProfile("PvPSpec", nil)
		profileManager:SetAutoSwitchRule(261, "PvPSpec")

		currentSpecId = 261
		specEvents:TriggerEvent("PLAYER_SPECIALIZATION_CHANGED")
		assert(db.ActiveProfile == "PvPSpec", "auto-switched to the rule's profile")

		-- No rule for this spec: stays put.
		currentSpecId = 262
		specEvents:TriggerEvent("PLAYER_SPECIALIZATION_CHANGED")
		assert(db.ActiveProfile == "PvPSpec", "no rule, no switch")
		currentSpecId = nil
	end)
end)

fw.describe("ProfileManager - Migrator interop", function()
	fw.it("profiles, active selection and auto-switch rules survive a soft reset", function()
		profileManager:SetAutoSwitchRule(263, "PvPSpec")
		local profileCountBefore = #profileManager:GetProfileNames()

		db.Version = db.Version + 100 -- future-version db forces the SoftReset path
		local healed = migrator:GetAndUpgradeDb()

		assert(healed.Profiles and healed.Profiles.PvPSpec, "profile slots survived")
		assert(#profileManager:GetProfileNames() == profileCountBefore, "no profiles lost")
		assert(healed.ActiveProfile == "PvPSpec", "active selection survived")
		assert(healed.AutoSwitch["Tester-TestRealm"][263] == "PvPSpec", "auto-switch rules survived")
	end)
end)
