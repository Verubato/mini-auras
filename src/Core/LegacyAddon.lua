-- Installing the release zip replaces MiniCC's toc with our settings bridge, so the pre-rename
-- addon cannot load. Copying src/ straight out of the repo, or an addon manager that treats
-- MiniAuras as a brand new addon and leaves the old folder enabled, both dodge that and end up
-- with two copies anchoring icons onto the same frames.
-- TEMPORARY: goes away with the bridge folder once MiniCCDB is dropped.
---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L

-- Only the bridge toc carries this. A loaded MiniCC without it is the real old addon.
local BRIDGE_FIELD = "X-MiniAuras-Bridge"

local warned = false

---@class LegacyAddon
local M = {}
addon.Core.LegacyAddon = M

---Whether the pre-rename addon is loaded rather than the settings bridge that replaced it.
---@return boolean
function M:IsConflicting()
	if not C_AddOns.IsAddOnLoaded("MiniCC") then
		return false
	end

	return C_AddOns.GetAddOnMetadata("MiniCC", BRIDGE_FIELD) == nil
end

---Warns once per session. The old settings have already been copied by the time this runs, so
---deleting the folder loses nothing.
function M:WarnIfConflicting()
	if warned or not M:IsConflicting() then
		return
	end

	warned = true

	mini:ShowDialog({
		Title = L["MiniAuras - Addon Conflict"],
		Text = L["The old MiniCC addon is still installed and running alongside MiniAuras, so every icon is being drawn twice.\n\nYour MiniCC settings have already been copied across. Delete the MiniCC folder from your AddOns folder, then reload."],
		Width = 460,
	})

	mini:Notify(L["The old MiniCC addon is still running alongside MiniAuras. Delete the MiniCC folder from your AddOns folder, then reload."])
end
