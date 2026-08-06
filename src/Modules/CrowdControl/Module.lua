---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.Core.Frames
local eventGate = addon.Core.EventGate
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local wowEx = addon.Utils.WoWEx

-- Loaded before this file in TOC order.
local display = addon.Modules.CrowdControl.Display

---@class CrowdControlModule : IModule
local M = {}
addon.Modules.CrowdControl.Module = M
addon.Modules.CrowdControlModule = M

-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type EventGate?
local rosterGate
---@type table?
local eventsFrame
---@type Db
local db
local testModeActive = false

local function OnFrameSortSorted()
	M:Refresh()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		-- wait for frame addons (danders/grid) to update
		C_Timer.After(0, function()
			M:Refresh()
		end)
	elseif event == "UNIT_PET" then
		-- A pet was summoned/dismissed; refresh so the opt-in pet unit frame containers show/hide
		-- with it. Only relevant when IncludePetFrame is enabled, so skip the work otherwise.
		local petOptions = db.Modules.PetCCModule
		if petOptions and petOptions.IncludePetFrame and moduleUtil:IsModuleEnabled(moduleName.PetCC) then
			C_Timer.After(0, function()
				M:Refresh()
			end)
		end
	end
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.CrowdControl) or moduleUtil:IsModuleEnabled(moduleName.PetCC)
end

---@param active boolean
local function SetEventsActive(active)
	-- Events stay unregistered while both features are off; the addon-wide Refresh
	-- (config, world change, raid flip) re-runs this gate.
	rosterGate:SetActive(active)
end

-- Live auras are pushed in by the watchers/containers, so only the fake ones rebuild here.
local function UpdateContent()
	if testModeActive then
		display:RefreshTestIcons()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)

	if active then
		display:SetPaused(true)
	else
		display:ResetAllContainers()
		display:SetPaused(false)
	end

	M:Refresh()

	-- 12.1: repopulate the kick icons the test-mode reset wiped.
	if not active and USE_AURA_CONTAINERS then
		display:RefreshKickIcons()
	end
end

local function CreateEvents()
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	-- Registered by the Refresh gate while either feature is on. UNIT_PET tracks the player's
	-- pet being summoned/dismissed so the opt-in pet unit frame containers follow it,
	-- regardless of which unit-frame addon owns the pet frame.
	rosterGate = eventGate:New(eventsFrame, { "GROUP_ROSTER_UPDATE", "UNIT_PET" })
end

local function InstallHooks()
	frames:InstallUnitFrameHooks(eventsFrame, {
		OnSetUnit = function(frame, unit)
			display:OnCufSetUnit(frame, unit)
		end,
		OnUpdateVisible = function(frame)
			display:OnCufUpdateVisible(frame)
		end,
		OnSorted = OnFrameSortSorted,
		OnVisibilityChanged = function()
			if IsEnabled() then
				display:EnsureWatchers()
			end
		end,
	})
end

local function ApplyInitialState()
	if moduleUtil:IsModuleEnabled(moduleName.CrowdControl) then
		display:EnsureWatchers()
	end
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	local options = display:GetOptions()

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		display:Teardown()
		return
	end

	display:EnsureFrames()
	display:ApplyOptions(options)
	UpdateContent()
end

function M:Init()
	db = mini:GetSavedVars()

	display:Init()
	CreateEvents()
	InstallHooks()
	ApplyInitialState()
end
