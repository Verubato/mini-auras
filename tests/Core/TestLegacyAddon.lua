-- The pre-rename addon and MiniAuras can only run together when the release zip was bypassed,
-- because installing it replaces MiniCC's toc with the settings bridge. Detection hangs entirely
-- on the bridge's X-MiniAuras-Bridge field, so these cover the three states a client can be in.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local addon = env.addon

assert(loadfile("src/Core/Compat/LegacyAddon.lua"))("MiniAuras", addon)

local legacyAddon = addon.Core.LegacyAddon

-- ModuleEnv loads the non-GUI half of the framework, so the dialog widget isn't there. Capturing
-- the call is what these tests care about anyway.
local dialogs = {}
addon.Framework.ShowDialog = function(_, options)
	dialogs[#dialogs + 1] = options
end

---Stands the client up as if MiniCC were absent, the bridge, or the real old addon.
---@param state "absent" | "bridge" | "old"
local function SetMiniCC(state)
	_G.C_AddOns.IsAddOnLoaded = function(name)
		if name == "MiniCC" then
			return state ~= "absent", state ~= "absent"
		end

		return false, false
	end

	_G.C_AddOns.GetAddOnMetadata = function(name, field)
		if name == "MiniCC" and field == "X-MiniAuras-Bridge" then
			return state == "bridge" and "1" or nil
		end

		return field == "Version" and "1.0.0" or nil
	end
end

fw.describe("LegacyAddon - spotting the pre-rename addon", function()
	fw.it("stays quiet when MiniCC is not installed at all", function()
		SetMiniCC("absent")

		assert(legacyAddon:IsConflicting() == false)
	end)

	fw.it("stays quiet when the loaded MiniCC is our settings bridge", function()
		SetMiniCC("bridge")

		assert(legacyAddon:IsConflicting() == false)
	end)

	fw.it("flags a loaded MiniCC with no bridge field as the old addon", function()
		SetMiniCC("old")

		assert(legacyAddon:IsConflicting() == true)
	end)
end)

-- Order matters below: the warned-once latch is module state, so the quiet case has to run
-- before anything trips it.
fw.describe("LegacyAddon - warning the user", function()
	fw.it("says nothing when there is no conflict", function()
		SetMiniCC("bridge")

		legacyAddon:WarnIfConflicting()

		assert(#dialogs == 0)
		assert(#env.notifications == 0)
	end)

	fw.it("warns once and not again for the rest of the session", function()
		SetMiniCC("old")

		legacyAddon:WarnIfConflicting()
		legacyAddon:WarnIfConflicting()

		assert(#dialogs == 1, "showed the dialog " .. #dialogs .. " times")
		assert(dialogs[1].Text:find("MiniCC", 1, true), "the dialog names the folder to remove")
		assert(#env.notifications == 1, "and printed to chat once")
	end)
end)

-- The offered-once latch is module state too, so each case below reloads the file for a
-- fresh instance.
local function FreshLegacyAddon()
	assert(loadfile("src/Core/Compat/LegacyAddon.lua"))("MiniAuras", addon)

	return addon.Core.LegacyAddon
end

---Stands the client up with or without an enabled (but never loaded) MiniCC folder, which is
---how an out-of-date bridge looks.
---@param installed boolean
local function SetInstalledNotLoaded(installed)
	_G.C_AddOns.IsAddOnLoaded = function()
		return false, false
	end
	_G.C_AddOns.GetAddOnEnableState = function(name)
		return (installed and name == "MiniCC") and 2 or 0
	end
end

fw.describe("LegacyAddon - offering the import that first-time setup missed", function()
	local reloads = 0
	_G.C_UI = _G.C_UI or {}
	_G.C_UI.Reload = function()
		reloads = reloads + 1
	end
	_G.StaticPopupDialogs = _G.StaticPopupDialogs or {}
	_G.StaticPopup_Show = _G.StaticPopup_Show or function() end

	fw.before_each(function()
		_G.MiniCCDB = nil
		_G.StaticPopupDialogs["MINIAURAS_IMPORT_LEGACY"] = nil

		for index = #env.notifications, 1, -1 do
			env.notifications[index] = nil
		end
	end)

	fw.it("stays quiet when nothing was missed", function()
		SetInstalledNotLoaded(true)
		_G.MiniCCDB = { MillisecondsThreshold = 4.2 }

		FreshLegacyAddon():OfferMissedImport({ MissedLegacyImport = false })

		assert(_G.StaticPopupDialogs["MINIAURAS_IMPORT_LEGACY"] == nil, "no popup")
		assert(#env.notifications == 0, "no chat warning")
	end)

	fw.it("stays quiet for a fresh install with no trace of MiniCC", function()
		SetInstalledNotLoaded(false)

		FreshLegacyAddon():OfferMissedImport({ MissedLegacyImport = true })

		assert(_G.StaticPopupDialogs["MINIAURAS_IMPORT_LEGACY"] == nil, "no popup")
		assert(#env.notifications == 0, "no chat warning")
	end)

	fw.it("offers the import when the legacy table finally shows up", function()
		SetInstalledNotLoaded(true)
		_G.MiniCCDB = { MillisecondsThreshold = 4.2 }

		local db = { MissedLegacyImport = true }

		FreshLegacyAddon():OfferMissedImport(db)

		local popup = _G.StaticPopupDialogs["MINIAURAS_IMPORT_LEGACY"]

		assert(popup, "the popup was registered")
		assert(#env.notifications == 0, "the popup replaces the chat warning")

		-- Accepting replaces the live table with a copy and reloads, so the migrator runs on
		-- it as if it had been adopted on day one.
		local before = _G.MiniAurasDB
		popup.OnAccept()

		assert(_G.MiniAurasDB.MillisecondsThreshold == 4.2, "the old settings came across")
		assert(_G.MiniAurasDB ~= _G.MiniCCDB, "as a copy, so a rollback still finds the original")
		assert(reloads == 1, "and the UI reloaded")

		_G.MiniAurasDB = before

		-- Declining is remembered, so the question is never asked again.
		popup.OnCancel()

		assert(db.MissedLegacyImport == false, "no is permanent")
	end)

	fw.it("explains an installed MiniCC that never loaded", function()
		SetInstalledNotLoaded(true)

		local fresh = FreshLegacyAddon()

		fresh:OfferMissedImport({ MissedLegacyImport = true })
		fresh:OfferMissedImport({ MissedLegacyImport = true })

		assert(#env.notifications == 1, "said why once, not " .. #env.notifications .. " times")
		assert(env.notifications[1]:find("did not load", 1, true), "and says what to do about it")
	end)
end)
