---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local instanceOptions = addon.Core.InstanceOptions
local scheduler = addon.Utils.Scheduler
local frames = addon.Core.Frames
local config = addon.Config
local testModeManager = addon.Modules.TestModeManager
local modules = {
	addon.Modules.CrowdControlModule,
	addon.Modules.HealerCrowdControlModule,
	addon.Modules.PortraitModule,
	addon.Modules.AlertsModule,
	addon.Modules.NameplatesModule,
	addon.Modules.KickTimerModule,
	addon.Modules.TrinketsModule,
	addon.Modules.FriendlyIndicatorModule,
}
local eventsFrame
local db

local function NotifyChanges()
	if db.NotifiedChanges then
		return
	end

	local title = "MiniCC - What's New?"
	db.NotifiedChanges = true

	if db.Version == 6 then
		mini:ShowDialog({
			Title = title,
			Text = table.concat(db.WhatsNew, "\n"),
		})
	elseif db.Version == 7 then
		mini:ShowDialog({
			Title = title,
			Text = table.concat({
				"- CC icons in player/target/focus portraits (beta only).",
				"- New option to colour the glow based on the dispel type.",
			}, "\n"),
		})
	elseif db.Version == 8 then
		mini:ShowDialog({
			Title = title,
			Text = table.concat({
				"- Portrait icons now supported in prepatch (was beta only).",
				"- Included important spells (defensives/offensives) in portrait icons, not just CC.",
			}, "\n"),
		})
	elseif db.Version == 9 then
		mini:ShowDialog({
			Title = title,
			Text = "- New spell alerts bar that shows enemy cooldowns.",
		})
	elseif db.Version >= 10 then
		local whatsNew = db.WhatsNew

		if not whatsNew then
			return
		end

		if next(whatsNew) then
			mini:ShowDialog({
				Title = title,
				Text = table.concat(whatsNew, "\n"),
			})
		end
	end

	db.WhatsNew = {}
end

local function OnEvent(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		if testModeManager:IsActive() then
			testModeManager:StopTesting()
			addon:Refresh()
		end
	end

	if event == "PLAYER_ENTERING_WORLD" then
		NotifyChanges()
		addon:Refresh()
	end
end

local function OnAddonLoaded()
	config:Init()
	scheduler:Init()
	frames:Init()
	instanceOptions:Init()
	addon.Utils.ModuleUtil:Init()

	for _, module in ipairs(modules) do
		module:Init()
	end

	testModeManager:Init()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")

	db = mini:GetSavedVars()
end

function addon:Refresh()
	if InCombatLockdown() then
		scheduler:RunWhenCombatEnds(function()
			addon:Refresh()
		end, "Refresh")
		return
	end

	for _, module in ipairs(modules) do
		module:Refresh()
	end
end

---@param options CrowdControlInstanceOptions?
function addon:ToggleTest(options)
	if testModeManager:IsActive() then
		testModeManager:StopTesting()
	else
		testModeManager:StartTesting(options)
	end

	addon:Refresh()

	if InCombatLockdown() then
		mini:Notify("Can't test during combat, we'll test once combat drops.")
	end
end

---@param options CrowdControlInstanceOptions
function addon:TestWithOptions(options)
	if not testModeManager:IsActive() then
		testModeManager:StartTesting(options)
		return
	end

	instanceOptions:SetTestInstanceOptions(options)
	addon:Refresh()
end

mini:WaitForAddonLoad(OnAddonLoaded)

---@class Addon
---@field Utils Utils
---@field Core Core
---@field Config Config
---@field Modules Modules
---@field Refresh fun(self: table)
---@field ToggleTest fun(self: table, options: CrowdControlInstanceOptions)
---@field TestWithOptions fun(self: table, options: CrowdControlInstanceOptions)

---@class Utils
---@field Scheduler SchedulerUtil
---@field Units UnitUtil
---@field Array ArrayUtil
---@field SpellCache SpellCache
---@field FontUtil FontUtil
---@field ModuleUtil ModuleUtil
---@field ModuleName ModuleName
---@field WoWEx WoWEx

---@class Core
---@field Framework MiniFramework
---@field Frames Frames
---@field UnitAuraWatcher UnitAuraWatcher
---@field IconSlotContainer IconSlotContainer
---@field InstanceOptions CrowdControlInstanceOptions

---@class Modules
---@field TestModeManager TestModeManager
---@field PortraitModule PortraitModule
---@field HealerCrowdControlModule HealerCrowdControlModule
---@field NameplatesModule NameplatesModule
---@field KickTimerModule KickTimerModule
---@field AlertsModule AlertsModule
---@field CrowdControlModule CrowdControlModule
---@field TrinketsModule TrinketsModule
---@field FriendlyIndicatorModule FriendlyIndicatorModule

---@class IModule
---@field Init fun(self: IModule) Initialises the module to be ready for use.
---@field Refresh fun(self: IModule) Refreshes the module to be in sync with config settings and world state. Must perform the least amount of work possible as this gets called a lot.
