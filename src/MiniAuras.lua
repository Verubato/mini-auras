---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local config = addon.Config
local migrator = addon.Config.Migrator
local testModeManager = addon.Core.TestModeManager
local legacyAddon = addon.Core.LegacyAddon
-- Every module Inits and Refreshes on every client; none of them are conditionally listed here.
-- Client support is each module's own decision, made once at file load from
-- WoWEx:UseAuraContainers() and enforced by early-returning from Init/Refresh/StartTesting. So a
-- module in this list may legitimately do nothing at all: TrinketsModule is 12.1-only, and the
-- two cooldown trackers (which infer cooldowns from aura data) are legacy-only.
-- TEMPORARY: the cooldown trackers leave this list when the legacy path is removed.
local modules = {
	addon.Modules.CrowdControlModule,
	addon.Modules.HealerCrowdControlModule,
	addon.Modules.PortraitModule,
	addon.Modules.AlertsModule,
	addon.Modules.NameplatesModule,
	addon.Modules.EnemyKickTrackerModule,
	addon.Modules.RaidFrameAurasModule,
	addon.Modules.CustomAurasModule,
	addon.Modules.PrecogModule,
	addon.Modules.TrinketsModule,
	addon.Modules.AllyKickTrackerModule,
	addon.Core.Cooldowns.Talents,
	addon.Core.TrinketsTracker,
	addon.Modules.FriendlyCooldownTrackerModule,
	addon.Modules.EnemyCooldownTrackerModule,
}
local eventsFrame
local db
local lastIsInRaid = false

-- Which instance flavour the next test session previews; the raid/default sub-tabs flip it.
addon.CurrentTestIsRaid = false

-- Chat prefix in the config UI's crimson accent (GUI.Accent) rather than the framework gold.
mini.NotifyColor = "c7333d"

-- Migrations queue their release notes into db.WhatsNew; this shows and clears them once.
local function NotifyChanges()
	if db.NotifiedChanges then
		return
	end

	db.NotifiedChanges = true

	local whatsNew = db.WhatsNew

	if not whatsNew then
		return
	end

	local text = table.concat(whatsNew, "\n")

	if text ~= "" then
		mini:ShowDialog({
			Title = L["MiniAuras - What's New?"],
			Text = text,
		})
	end

	db.WhatsNew = {}
end

local function OnEvent(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		if testModeManager:IsActive() then
			testModeManager:StopTesting()
			addon:Refresh()
		end
	elseif event == "PLAYER_LOGIN" then
		if migrator:RunDeferredMigrations(db) then
			local tabController = addon.Config.TabController
			if tabController then
				for _, key in ipairs({ "CC", "PetCC" }) do
					local ccPanel = tabController:GetContent(key)
					if ccPanel and ccPanel.MiniRefresh then
						ccPanel:MiniRefresh()
					end
				end
			end
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		lastIsInRaid = IsInRaid()
		NotifyChanges()
		-- After NotifyChanges, because both share one dialog frame and the conflict is the more
		-- urgent of the two.
		legacyAddon:WarnIfConflicting()
		legacyAddon:OfferMissedImport(db)
		addon:Refresh()
	elseif event == "GROUP_ROSTER_UPDATE" then
		-- Modules unregister their events entirely while disabled, and IsModuleEnabled depends
		-- on raid membership; re-evaluate every module's gate when it flips so a disabled
		-- module can wake back up (instance changes are covered by PLAYER_ENTERING_WORLD).
		local inRaid = IsInRaid()
		if inRaid ~= lastIsInRaid then
			lastIsInRaid = inRaid
			addon:Refresh()
		end
	end
end

local function OnAddonLoaded()
	-- MiniCCDB is the pre-rename table, still on disk until the migration in Config:Init copies
	-- it across. Read here too so the very first login after the rename keeps the user's language.
	local savedVars = MiniAurasDB or MiniCCDB
	L:ApplyLocale(savedVars and savedVars.LocaleOverride or GetLocale())

	config:Init()
	frames:Init()
	addon.Utils.ModuleUtil:Init()
	addon.Core.ProfileManager:Init()
	addon.Core.AnchoredIcons:Init()

	for _, module in ipairs(modules) do
		module:Init()
	end

	testModeManager:Init()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	eventsFrame:RegisterEvent("PLAYER_LOGIN")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	db = mini:GetSavedVars()
end

function addon:Refresh()
	for _, module in ipairs(modules) do
		module:Refresh()
	end
end

---@param isRaid boolean?
function addon:ToggleTest(isRaid)
	if testModeManager:IsActive() then
		testModeManager:StopTesting()
	else
		testModeManager:StartTesting(isRaid ~= nil and isRaid or self.CurrentTestIsRaid)
	end

	addon:Refresh()
end

---@param isRaid boolean?
function addon:TestWithOptions(isRaid)
	if not testModeManager:IsActive() then
		testModeManager:StartTesting(isRaid)
		return
	end

	instanceOptions:SetTestIsRaid(isRaid)
	addon:Refresh()
end

function addon:IsTestActive()
	return testModeManager:IsActive()
end

mini:WaitForAddonLoad(OnAddonLoaded)

---@class Addon
---@field L Localization
---@field Utils Utils
---@field Core Core
---@field Config Config
---@field Modules Modules
---@field Refresh fun(self: table)
---@field ToggleTest fun(self: table, isRaid: boolean?)
---@field TestWithOptions fun(self: table, isRaid: boolean?)
---@field IsTestActive fun(self: table): boolean

---@class Utils
---@field Units UnitUtil
---@field FontUtil FontUtil
---@field ModuleUtil ModuleUtil
---@field ModuleName ModuleName
---@field WoWEx WoWEx
---@field PvPTalentSync PvPTalentSync

---@class Core
---@field Framework MiniFramework
---@field Frames Frames
---@field UnitAuraWatcher UnitAuraWatcher
---@field Inspector Inspector
---@field IconSlotContainer IconSlotContainer
---@field AuraContainerDisplay AuraContainerDisplay
---@field EventGate EventGate
---@field AuraCategoryIds AuraCategoryIds
---@field InstanceOptions InstanceOptions
---@field LegacyAddon LegacyAddon
---@field TrinketsTracker TrinketsTracker
---@field TestModeManager TestModeManager
---@field TestSpells TestSpells
---@field AnchoredIcons AnchoredIcons
---@field BarTextures BarTextures
---@field Sounds Sounds
---@field Cooldowns Cooldowns

---@class Cooldowns
---@field PvPTalentSync PvPTalentSync
---@field Talents CooldownTalents
---@field Rules CooldownRules
---@field SignatureDetector SignatureDetector
---@field Brain CooldownBrain

---@class FriendlyCooldowns
---@field Observer FriendlyCooldownObserver
---@field Display FriendlyCooldownDisplay
---@field Module FriendlyCooldownTrackerModule

---@class EnemyCooldowns
---@field Observer EnemyCooldownObserver
---@field Display EnemyCooldownDisplay
---@field Module EnemyCooldownTrackerModule

---@class RaidFrameAuras
---@field Display RaidFrameAurasDisplay
---@field Module RaidFrameAurasModule

---@class CustomAuras
---@field Groups CustomAurasGroups
---@field Sound CustomAurasSound
---@field Recorder CustomAurasRecorder
---@field Display CustomAurasDisplay
---@field Module CustomAurasModule

---@class CrowdControl
---@field Display CrowdControlDisplay
---@field Module CrowdControlModule

---@class Alerts
---@field Sound AlertsSound
---@field Observer AlertsObserver
---@field Display AlertsDisplay
---@field Module AlertsModule

---@class EnemyKickTracker
---@field Observer EnemyKickTrackerObserver
---@field Display EnemyKickTrackerDisplay
---@field Module EnemyKickTrackerModule

---@class HealerCrowdControl
---@field Sound HealerCrowdControlSound
---@field Display HealerCrowdControlDisplay
---@field Module HealerCrowdControlModule

---@class Precog
---@field Sound PrecogSound
---@field Module PrecogModule

---@class Trinkets
---@field Display TrinketsDisplay
---@field Module TrinketsModule

---@class Nameplates
---@field Observer NameplatesObserver
---@field Display NameplatesDisplay
---@field Module NameplatesModule

---@class Portrait
---@field Observer PortraitObserver
---@field Display PortraitDisplay
---@field Anchors PortraitAnchors
---@field Module PortraitModule

---@class AllyKickTracker
---@field Observer AllyKickObserver
---@field Display AllyKickDisplay
---@field Module AllyKickTrackerModule

---@class Modules
---@field PortraitModule PortraitModule
---@field HealerCrowdControlModule HealerCrowdControlModule
---@field NameplatesModule NameplatesModule
---@field EnemyKickTrackerModule EnemyKickTrackerModule
---@field AllyKickTrackerModule AllyKickTrackerModule
---@field AlertsModule AlertsModule
---@field CrowdControlModule CrowdControlModule
---@field RaidFrameAurasModule RaidFrameAurasModule
---@field CustomAurasModule CustomAurasModule
---@field PrecogModule PrecogModule
---@field FriendlyCooldownTrackerModule FriendlyCooldownTrackerModule
---@field EnemyCooldownTrackerModule EnemyCooldownTrackerModule
---@field FriendlyCooldowns FriendlyCooldowns
---@field EnemyCooldowns EnemyCooldowns
---@field EnemyKickTracker EnemyKickTracker
---@field AllyKickTracker AllyKickTracker
---@field Alerts Alerts
---@field RaidFrameAuras RaidFrameAuras
---@field CustomAuras CustomAuras
---@field CrowdControl CrowdControl
---@field HealerCrowdControl HealerCrowdControl
---@field Precog Precog
---@field Trinkets Trinkets
---@field Nameplates Nameplates
---@field Portrait Portrait

---@class IModule
---@field Init fun(self: IModule) Initialises the module to be ready for use.
---@field Refresh fun(self: IModule) Refreshes the module to be in sync with config settings and world state. Must perform the least amount of work possible as this gets called a lot.
