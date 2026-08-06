-- The pre-rename addon and MiniAuras can only run together when the release zip was bypassed,
-- because installing it replaces MiniCC's toc with the settings bridge. Detection hangs entirely
-- on the bridge's X-MiniAuras-Bridge field, so these cover the three states a client can be in.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local addon = env.addon

assert(loadfile("src/Core/LegacyAddon.lua"))("MiniAuras", addon)

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
