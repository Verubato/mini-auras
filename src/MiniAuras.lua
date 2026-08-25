---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local instanceOptions = addon.Core.InstanceOptions
local frames = addon.Core.Frames
local config = addon.Config
local migrator = addon.Config.Migrator
local testModeManager = addon.Core.TestModeManager
local moduleUtil = addon.Utils.ModuleUtil
local legacyAddon = addon.Core.LegacyAddon
-- Every module Inits and Refreshes unconditionally; whether it draws anything, and whether it
-- sets itself up at all, is its own decision, taken from its saved settings.
local modules = {
	addon.Modules.CrowdControlModule,
	addon.Modules.HealerCrowdControlModule,
	addon.Modules.PortraitModule,
	addon.Modules.AlertsModule,
	addon.Modules.NameplatesModule,
	addon.Modules.EnemyKickTrackerModule,
	addon.Modules.ImportantAurasModule,
	addon.Modules.FrameAurasModule,
	addon.Modules.PersonalAurasModule,
	addon.Modules.TrinketsModule,
	addon.Modules.AllyKickTrackerModule,
	addon.Core.TrinketsTracker,
}

-- Maps a settings table's db.Modules key back to the module that renders it, so a config change
-- can refresh just the module it touched. PetCrowdControl rides the CrowdControl module rather
-- than owning a renderer.
local modulesBySettingsKey = {
	CrowdControl = addon.Modules.CrowdControlModule,
	PetCrowdControl = addon.Modules.CrowdControlModule,
	HealerCrowdControl = addon.Modules.HealerCrowdControlModule,
	Portrait = addon.Modules.PortraitModule,
	Alerts = addon.Modules.AlertsModule,
	Nameplates = addon.Modules.NameplatesModule,
	EnemyKickTracker = addon.Modules.EnemyKickTrackerModule,
	AllyKickTracker = addon.Modules.AllyKickTrackerModule,
	Trinkets = addon.Modules.TrinketsModule,
	ImportantAuras = addon.Modules.ImportantAurasModule,
	FrameAuras = addon.Modules.FrameAurasModule,
	PersonalAuras = addon.Modules.PersonalAurasModule,
}
-- How long a burst of media registrations is allowed to settle before re-resolving. A media pack
-- registers one entry at a time, so this coalesces a hundred callbacks into one refresh.
local MEDIA_REFRESH_DELAY = 1

local eventsFrame
local db
local lastIsInRaid = false
local lastInstanceType
local lastInHousing = false
local housingCheckQueued = false
-- A loading screen is up while the addon is loading, and nothing announces the one already on
-- screen, so this starts true and the first LOADING_SCREEN_DISABLED ends it. Read by the nameplate
-- modules: building their aura containers is only free while nothing is being drawn.
local loadingScreenUp = true
-- Third-party unit frames do not exist until the world has loaded, so a module attaching to them
-- has to wait for the first PLAYER_ENTERING_WORLD. Central rather than per module: a module set
-- up lazily on its first enable has long missed the event by then.
local enteredWorld = false
-- Bumped on every world load. A module set up lazily has long missed the event itself, so anything
-- it has to start over on a zone-in compares this against the generation it last acted on.
local worldGeneration = 0
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

-- The client fires a plot event that changed nothing on every /reload spent outside housing, and
-- a full refresh costs several hundred milliseconds. Read a frame later, so the state has settled
-- whichever way the event beat it, and refresh only when it actually moved.
local function CheckHousing()
	housingCheckQueued = false

	moduleUtil:InvalidateWorldState()

	local inHousing = moduleUtil:IsInHousing()

	if inHousing ~= lastInHousing then
		lastInHousing = inHousing
		addon:Refresh()
	end
end

local function QueueHousingCheck()
	if housingCheckQueued then
		return
	end

	housingCheckQueued = true

	C_Timer.After(0, CheckHousing)
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

---What a refresh covers beyond the modules that have just refreshed themselves: the trinket
---tracker, which has no test mode of its own, and the two font sweeps. The font face belongs to no
---module's settings, so these reach what a module's own refresh had no reason to touch: the aura
---displays whose style has not otherwise moved, and the stand-in party and arena frames, which
---have no module at all.
local function RefreshShared()
	addon.Core.TrinketsTracker:Refresh()
	addon.Core.AuraContainerDisplay:RefreshFontFace()
	addon.Core.Frames:RefreshTestFrameFonts()
end

local function OnEvent(_, event, unit)
	if event == "LOADING_SCREEN_ENABLED" then
		loadingScreenUp = true
	elseif event == "LOADING_SCREEN_DISABLED" then
		loadingScreenUp = false
	elseif event == "PLAYER_REGEN_DISABLED" then
		if testModeManager:IsActive() then
			testModeManager:StopTesting()
			RefreshShared()
		end
	elseif event == "PLAYER_LOGIN" then
		if migrator:RunDeferredMigrations(db) then
			-- Only for pages that already exist, which means the player had the options open
			-- while this ran. One built afterwards reads the migrated settings as it is built.
			local tabController = addon.Config.TabController
			if tabController then
				for _, key in ipairs({ "CC", "PetCC" }) do
					mini.GUI.RefreshPanelTree(tabController:GetContent(key))
				end
			end
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		enteredWorld = true
		worldGeneration = worldGeneration + 1
		lastIsInRaid = IsInRaid()
		lastInstanceType = select(2, IsInInstance())
		moduleUtil:InvalidateWorldState()
		lastInHousing = moduleUtil:IsInHousing()
		NotifyChanges()
		-- After NotifyChanges, because both share one dialog frame and the conflict is the more
		-- urgent of the two.
		legacyAddon:WarnIfConflicting()
		legacyAddon:OfferMissedImport(db)
		addon:Refresh()
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		-- A zone can change the instance type without a world load, and every module's gate reads
		-- it. Only when it actually moved: this also fires on every zone boundary in the open
		-- world, and beside the world load, which has just refreshed everything itself.
		local instanceType = select(2, IsInInstance())
		if instanceType ~= lastInstanceType then
			lastInstanceType = instanceType
			addon:Refresh()
		end
	elseif event == "HOUSE_PLOT_ENTERED" or event == "HOUSE_PLOT_EXITED" then
		-- Crossing a plot boundary loads no new map, so PLAYER_ENTERING_WORLD never sees it;
		-- re-run the gates so everything hides on the way in and wakes on the way out.
		QueueHousingCheck()
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		-- The kick trackers are enabled per spec. A respec fires no world or roster event, so
		-- without this nothing would wake a module the player's new spec switches on.
		if unit == "player" then
			addon:Refresh()
		end
	elseif event == "GROUP_ROSTER_UPDATE" then
		-- Modules unregister their events entirely while disabled, and IsModuleEnabled depends
		-- on raid membership, so every module's gate is re-evaluated when it flips and a disabled
		-- module can wake back up. Instance changes are covered by PLAYER_ENTERING_WORLD.
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
	-- The language is settled for this session, since changing it asks for a reload, so the ten
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
	addon.Core.Fonts:OnChanged(QueueMediaRefresh)

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	eventsFrame:RegisterEvent("PLAYER_LOGIN")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	eventsFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
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

---Whether the world has finished loading at least once this session. Anything that reaches into
---another addon's unit frames has to wait for it: before then those frames do not exist.
---@return boolean
function addon:HasEnteredWorld()
	return enteredWorld
end

---How many times the world has loaded this session. A module compares it against the generation
---it last handled to tell a fresh world from an ordinary refresh, which is what it would otherwise
---have needed its own always-registered PLAYER_ENTERING_WORLD to hear.
---@return number
function addon:WorldGeneration()
	return worldGeneration
end

function addon:Refresh()
	for _, module in ipairs(modules) do
		module:Refresh()
	end

	RefreshShared()
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

	-- Every test module refreshes itself as it flips, and a second pass over all ten would be half
	-- the cost of the button. Only what no module owns is left to do.
	RefreshShared()
end

---@param isRaid boolean?
function addon:TestWithOptions(isRaid)
	if not testModeManager:IsActive() then
		testModeManager:StartTesting(isRaid)
		RefreshShared()

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
---@field IsLoadingScreenUp fun(self: table): boolean
---@field HasEnteredWorld fun(self: table): boolean
---@field WorldGeneration fun(self: table): number

---@class Utils
---@field UnitUtil UnitUtil
---@field FontUtil FontUtil
---@field ModuleUtil ModuleUtil
---@field ModuleName ModuleName
---@field WoWEx WoWEx

---@class Core
---@field Framework MiniFramework
---@field Frames Frames
---@field Pixels Pixels
---@field TrackedBuffs TrackedBuffs
---@field Inspector Inspector
---@field IconSlotContainer IconSlotContainer
---@field AuraContainerDisplay AuraContainerDisplay
---@field EventGate EventGate
---@field ModuleLifecycle ModuleLifecycle
---@field AuraCategoryIds AuraCategoryIds
---@field InstanceOptions InstanceOptions
---@field LegacyAddon LegacyAddon
---@field TrinketsTracker TrinketsTracker
---@field TestModeManager TestModeManager
---@field PositionEditor PositionEditor
---@field TestSpells TestSpells
---@field AnchoredIcons AnchoredIcons
---@field BarTextures BarTextures
---@field Fonts Fonts
---@field BarSlotContainer BarSlotContainer
---@field Outline Outline
---@field Sounds Sounds

---@class ImportantAuras
---@field Display ImportantAurasDisplay
---@field Module ImportantAurasModule

---@class FrameAuras
---@field Spells FrameAurasSpells
---@field PartyAuras FrameAurasPartyAuras
---@field ClassBuff FrameAurasClassBuff
---@field TargetAuras FrameAurasTargetAuras
---@field Module FrameAurasModule

---@class PersonalAuras
---@field Groups PersonalAurasGroups
---@field Sound PersonalAurasSound
---@field Recorder PersonalAurasRecorder
---@field Display PersonalAurasDisplay
---@field Module PersonalAurasModule

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
---@field ImportantAurasModule ImportantAurasModule
---@field FrameAurasModule FrameAurasModule
---@field PersonalAurasModule PersonalAurasModule
---@field EnemyKickTracker EnemyKickTracker
---@field AllyKickTracker AllyKickTracker
---@field Alerts Alerts
---@field ImportantAuras ImportantAuras
---@field FrameAuras FrameAuras
---@field PersonalAuras PersonalAuras
---@field CrowdControl CrowdControl
---@field HealerCrowdControl HealerCrowdControl
---@field Trinkets Trinkets
---@field Nameplates Nameplates
---@field Portrait Portrait

---A module wraps a ModuleLifecycle, which owns the enable and disable edges: Init only caches
---the settings and builds the lifecycle, and everything else waits for the first Refresh that
---finds the module enabled. So a module the player never switches on creates no frames, registers
---no events and installs no hooks.
---
---A module can therefore never rely on hearing an event to notice it should wake up. Everything
---that decides enablement is driven centrally from this file: the world, zone, roster, spec and
---housing events, plus the refresh a config change asks for.
---@class IModule
---@field Init fun(self: IModule) Caches settings and builds the lifecycle. Must not create frames or register events.
---@field Refresh fun(self: IModule) Brings the module in sync with its settings and the world. Called a lot, so it must do the least work it can.
---@field StartTesting fun(self: IModule)? Shows the module's preview. Every module but TrinketsTracker has one.
---@field StopTesting fun(self: IModule)?
