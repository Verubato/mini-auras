-- Installing the release zip replaces MiniCC's toc with our settings bridge, so the pre-rename
-- addon cannot load. Copying src/ out of the repo, or an addon manager that leaves the old folder
-- enabled, dodges that and ends up with two copies anchoring icons onto the same frames.
-- Temporary: goes away with the bridge folder once MiniCCDB is dropped.
---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local L = addon.L

-- Only the bridge toc carries this. A loaded MiniCC without it is the real old addon.
local BRIDGE_FIELD = "X-MiniAuras-Bridge"

local warned = false
local offered = false

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

	mini:NotifyWithPrefix(L["The old MiniCC addon is still running alongside MiniAuras. Delete the MiniCC folder from your AddOns folder, then reload."])
end

---The recovery path for a MiniCC table that was absent on MiniAuras' very first login, where
---first-time setup ran on defaults and the migrator's one-shot adoption is spent. If the old
---table surfaces on a later login, offer to import it; if a MiniCC folder is installed but
---never loaded, say why the settings are stuck. Asks at most once per session.
---@param db Db
function M:OfferMissedImport(db)
	if offered or not db.MissedLegacyImport then
		return
	end

	offered = true

	if type(MiniCCDB) == "table" then
		StaticPopupDialogs["MINIAURAS_IMPORT_LEGACY"] = {
			text = L["Your old MiniCC settings were found, but MiniAuras was first set up without them. Import them now? This replaces your current MiniAuras settings and reloads the UI."],
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				MiniAurasDB = mini:CopyTable(MiniCCDB)
				C_UI.Reload()
			end,
			OnCancel = function()
				db.MissedLegacyImport = false
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
		}
		StaticPopup_Show("MINIAURAS_IMPORT_LEGACY")
		return
	end

	-- A MiniCC folder is enabled but did not load, which in practice means it sits greyed out
	-- as out of date, so the saved variable it carries never reached us. A user who disabled
	-- it on purpose stays unbothered.
	if wowEx:IsAddOnEnabled("MiniCC") and not C_AddOns.IsAddOnLoaded("MiniCC") then
		mini:NotifyWithPrefix(L["The MiniCC addon holding your old settings is installed but did not load. Enable it and 'Load out of date AddOns' on the AddOns list, then reload to import your settings."])
	end
end
