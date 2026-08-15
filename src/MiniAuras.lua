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
-- Every module Inits and Refreshes unconditionally; whether it draws anything is its own
-- decision, taken from its saved settings.
local modules = {
	addon.Modules.CrowdControlModule,
	addon.Modules.HealerCrowdControlModule,
	addon.Modules.PortraitModule,
	addon.Modules.AlertsModule,
	addon.Modules.NameplatesModule,
	addon.Modules.EnemyKickTrackerModule,
	addon.Modules.RaidFrameAurasModule,
	addon.Modules.CustomAurasModule,
	addon.Modules.TrinketsModule,
	addon.Modules.AllyKickTrackerModule,
	addon.Core.TrinketsTracker,
}
-- Maps a settings table's db.Modules key back to the module that renders it, so a config change
-- can refresh just the module it touched. PetCC rides the CC module rather than owning a renderer.
local modulesBySettingsKey = {
	CCModule = addon.Modules.CrowdControlModule,
	PetCCModule = addon.Modules.CrowdControlModule,
	HealerCCModule = addon.Modules.HealerCrowdControlModule,
	PortraitModule = addon.Modules.PortraitModule,
	AlertsModule = addon.Modules.AlertsModule,
	NameplatesModule = addon.Modules.NameplatesModule,
	EnemyKickTrackerModule = addon.Modules.EnemyKickTrackerModule,
	AllyKickTrackerModule = addon.Modules.AllyKickTrackerModule,
	TrinketsModule = addon.Modules.TrinketsModule,
	RaidFrameAurasModule = addon.Modules.RaidFrameAurasModule,
	CustomAurasModule = addon.Modules.CustomAurasModule,
}
-- How long a burst of media registrations is allowed to settle before re-resolving. A media pack
-- registers one entry at a time, so this coalesces a hundred callbacks into one refresh.
local MEDIA_REFRESH_DELAY = 1

local eventsFrame
local db
local lastIsInRaid = false
-- A loading screen is up while the addon is loading, and nothing announces the one already on
-- screen, so this starts true and the first LOADING_SCREEN_DISABLED ends it. Read by the nameplate
-- modules: building their aura containers is only free while nothing is being drawn.
local loadingScreenUp = true
local mediaRefreshQueued = false

-- Which instance flavour the next test session previews; the raid/default sub-tabs flip it.
addon.CurrentTestIsRaid = false

-- Chat prefix in the config UI's crimson accent (GUI.Accent) rather than the framework gold.
mini.NotifyColor = "c7333d"

-- A name from a media addon resolves to nothing until that addon has loaded, which is routinely
-- after our first pass: engine-side aura sounds bake in the file they were registered with, and a
-- bar keeps whichever fill it was last given. Both compare resolved paths, so one refresh once the
-- list has grown picks up everything that was missing.
local function QueueMediaRefresh()
	if mediaRefreshQueued then
		return
	end

	mediaRefreshQueued = true

	C_Timer.After(MEDIA_REFRESH_DELAY, function()
		mediaRefreshQueued = false
		addon:Refresh()
	end)
end

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
	if event == "LOADING_SCREEN_ENABLED" then
		loadingScreenUp = true
	elseif event == "LOADING_SCREEN_DISABLED" then
		loadingScreenUp = false
	elseif event == "PLAYER_REGEN_DISABLED" then
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
	elseif event == "HOUSE_PLOT_ENTERED" or event == "HOUSE_PLOT_EXITED" then
		-- Crossing a plot boundary loads no new map, so PLAYER_ENTERING_WORLD never sees it;
		-- re-run the gates so everything hides on the way in and wakes on the way out.
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
	-- The language is settled for this session - changing it asks for a reload - so the ten
	-- translations nobody is reading can go. They are most of what the locale files weigh.
	L:ReleaseUnused()

	config:Init()
	frames:Init()
	-- Only consumer left is the kick trackers' ally-spec guess, via InspectorFacade. It has no
	-- Refresh, so it sits here rather than in the module list.
	addon.Core.Inspector:Init()
	addon.Utils.ModuleUtil:Init()
	addon.Core.ProfileManager:Init()
	addon.Core.AnchoredIcons:Init()

	for _, module in ipairs(modules) do
		module:Init()
	end

	testModeManager:Init()
	addon.Core.Sounds:OnChanged(QueueMediaRefresh)
	addon.Core.BarTextures:OnChanged(QueueMediaRefresh)

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	eventsFrame:RegisterEvent("PLAYER_LOGIN")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("LOADING_SCREEN_ENABLED")
	eventsFrame:RegisterEvent("LOADING_SCREEN_DISABLED")

	-- The housing API may not exist on all game versions.
	if type(C_Housing) == "table" then
		eventsFrame:RegisterEvent("HOUSE_PLOT_ENTERED")
		eventsFrame:RegisterEvent("HOUSE_PLOT_EXITED")
	end

	db = mini:GetSavedVars()
end

---Whether a loading screen is covering the game right now. The nameplate modules build their aura
---containers up front, and this is the window where that costs nothing: no frame is being drawn,
---and PLAYER_ENTERING_WORLD (which drives the refresh that builds them) fires while it is still up.
---@return boolean
function addon:IsLoadingScreenUp()
	return loadingScreenUp
end

function addon:Refresh()
	for _, module in ipairs(modules) do
		module:Refresh()
	end
end

---Refreshes only the module that renders the given settings table. An unknown key falls back to
---the full refresh, so a caller can never end up narrower than correct.
---@param settingsKey string A ModuleName value naming the db.Modules table that changed.
function addon:RefreshModule(settingsKey)
	local module = modulesBySettingsKey[settingsKey]

	if module then
		module:Refresh()
	else
		addon:Refresh()
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
---@field RefreshModule fun(self: table, settingsKey: string)
---@field ToggleTest fun(self: table, isRaid: boolean?)
---@field TestWithOptions fun(self: table, isRaid: boolean?)
---@field IsTestActive fun(self: table): boolean

---@class Utils
---@field Units UnitUtil
---@field FontUtil FontUtil
---@field ModuleUtil ModuleUtil
---@field ModuleName ModuleName
---@field WoWEx WoWEx

---@class Core
---@field Framework MiniFramework
---@field Frames Frames
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
---@field BarSlotContainer BarSlotContainer
---@field Outline Outline
---@field Sounds Sounds

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

---@class Trinkets
---@field Display TrinketsDisplay
---@field Module TrinketsModule

---@class Nameplates
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
---@field EnemyKickTracker EnemyKickTracker
---@field AllyKickTracker AllyKickTracker
---@field Alerts Alerts
---@field RaidFrameAuras RaidFrameAuras
---@field CustomAuras CustomAuras
---@field CrowdControl CrowdControl
---@field HealerCrowdControl HealerCrowdControl
---@field Trinkets Trinkets
---@field Nameplates Nameplates
---@field Portrait Portrait

---@class IModule
---@field Init fun(self: IModule) Initialises the module to be ready for use.
---@field Refresh fun(self: IModule) Refreshes the module to be in sync with config settings and world state. Must perform the least amount of work possible as this gets called a lot.
