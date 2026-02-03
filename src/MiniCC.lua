---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local scheduler = addon.Utils.Scheduler
local headerManager = addon.HeaderManager
local testModeManager = addon.TestModeManager
local healerManager = addon.HealerCcManager
local portraitManager = addon.PortraitManager
local importantSpellsManager = addon.ImportantSpellsManager
local nameplatesManager = addon.NameplatesManager
local frames = addon.FramesManager
local eventsFrame
local db

local function OnCufUpdateVisible(frame)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	local headers = headerManager:GetHeaders()
	local header = headers[frame]

	if not header then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		local instanceOptions = headerManager:GetCurrentInstanceOptions()

		if not instanceOptions then
			return
		end

		frames:ShowHideFrame(header, frame, false, instanceOptions)
	end)
end

local function OnCufSetUnit(frame, unit)
	if not frame or not frames:IsFriendlyCuf(frame) then
		return
	end

	if not unit then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		headerManager:EnsureHeader(frame, unit)
	end)
end

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
	elseif db.Version == 10 then
		local whatsNew = db.WhatsNew

		if not whatsNew then
			return
		end

		mini:ShowDialog({
			Title = title,
			Text = table.concat(whatsNew, "\n"),
		})
	end

	db.WhatsNew = {}
end

local function OnFrameSortSorted()
	addon:Refresh()
end

local function OnEvent(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		if testModeManager:IsEnabled() then
			testModeManager:Disable()
			addon:Refresh()
		end
	end

	if event == "PLAYER_ENTERING_WORLD" then
		NotifyChanges()
		addon:Refresh()
	end

	if event == "GROUP_ROSTER_UPDATE" then
		addon:Refresh()
	end
end

local function OnAddonLoaded()
	addon.Config:Init()
	addon.Utils.Scheduler:Init()
	addon.FramesManager:Init()
	addon.ImportantSpellsManager:Init()

	headerManager:Init()
	healerManager:Init()
	testModeManager:Init()
	portraitManager:Init()
	nameplatesManager:Init()

	db = mini:GetSavedVars()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

	if CompactUnitFrame_SetUnit then
		hooksecurefunc("CompactUnitFrame_SetUnit", OnCufSetUnit)
	end

	if CompactUnitFrame_UpdateVisible then
		hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
	end

	local fs = FrameSortApi and FrameSortApi.v3
	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(OnFrameSortSorted)
	end
end

function addon:Refresh()
	if InCombatLockdown() then
		scheduler:RunWhenCombatEnds(function()
			addon:Refresh()
		end, "Refresh")
		return
	end

	headerManager:Refresh()
	healerManager:Refresh()
	importantSpellsManager:Refresh()
	portraitManager:Refresh()
	nameplatesManager:Refresh()

	if testModeManager:IsEnabled() then
		testModeManager:Show()
	else
		testModeManager:Hide()
	end
end

---@param options InstanceOptions?
function addon:ToggleTest(options)
	if testModeManager:IsEnabled() then
		testModeManager:Disable()
	else
		testModeManager:Enable(options)
	end

	addon:Refresh()

	if InCombatLockdown() then
		mini:Notify("Can't test during combat, we'll test once combat drops.")
	end
end

---@param options InstanceOptions?
function addon:TestOptions(options)
	testModeManager:SetOptions(options)

	if testModeManager:IsEnabled() then
		addon:Refresh()
	end
end

mini:WaitForAddonLoad(OnAddonLoaded)

---@class Addon
---@field Framework MiniFramework
---@field Capabilities Capabilities
---@field Config Config
---@field Utils Utils
---@field CcHeader CcHeader
---@field FramesManager FramesManager
---@field UnitAuraWatcher UnitAuraWatcher
---@field TestModeManager TestModeManager
---@field HeaderManager HeaderManager
---@field PortraitManager PortraitManager
---@field HealerCcManager HealerCcManager
---@field NameplatesManager NameplatesManager
---@field IconSlotContainer IconSlotContainer
---@field ImportantSpellsManager ImportantSpellsManager
---@field Refresh fun(self: table)
---@field ToggleTest fun(self: table, options: InstanceOptions)
---@field TestOptions fun(self: table, options: InstanceOptions)
---@field TestHealer fun(self: table)

---@class Utils
---@field CcUtil CcUtil
---@field Scheduler SchedulerUtil
---@field Units UnitUtil
---@field Array ArrayUtil
