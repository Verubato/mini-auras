---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local wowEx = addon.Utils.WoWEx
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local eventGate = addon.Core.EventGate

-- Loaded before this file in TOC order.
local sound   = addon.Modules.HealerCrowdControl.Sound
local display = addon.Modules.HealerCrowdControl.Display

---@class HealerCrowdControlModule : IModule
local M = {}
addon.Modules.HealerCrowdControl.Module = M
addon.Modules.HealerCrowdControlModule = M

-- TEMPORARY dual path: remove the watcher branch once 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---@type Db
local db
local testModeActive = false
local previousTestSoundEnabled = false
---@type EventGate?
local rosterGate

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		C_Timer.After(0, function()
			M:Refresh()
		end)
	end
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(ModuleName.HealerCrowdControl)
end

---@param active boolean
local function SetEventsActive(active)
	-- Events stay unregistered while disabled; the addon-wide Refresh re-runs this gate.
	-- Keyed on the module toggle alone rather than on the player's own spec: a respec fires
	-- no world or raid event, so the roster event has to stay registered to wake this up.
	if rosterGate then
		rosterGate:SetActive(active)
	end
end

---Live icons are driven by the watchers/containers; only the fake ones rebuild here.
---@param options HealerCCModuleOptions
local function UpdateContent(options)
	if not testModeActive then
		return
	end

	display:ShowAnchor()
	display:RefreshTestFrame()

	if previousTestSoundEnabled ~= options.Sound.Enabled and options.Sound.Enabled then
		if USE_AURA_CONTAINERS then
			-- The transition-based sound is disabled on 12.1 (engine-side AddAuraSound covers
			-- live auras), but the config preview still needs to demo the file.
			sound:PlayPreview(options)
		else
			sound:Play()
		end
	end

	previousTestSoundEnabled = options.Sound.Enabled
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active
	display:SetTestMode(active)

	if active then
		display:SetPaused(true)
	else
		display:ResetIcons()
		display:SetPaused(false)
		display:OnAuraStateUpdated()
	end

	M:Refresh()
end

local function CreateEvents()
	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	-- Registered by the Refresh gate while the module is enabled.
	rosterGate = eventGate:New(eventsFrame, { "GROUP_ROSTER_UPDATE" })
end

local function ApplyInitialState()
	M:Refresh()
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
		display:SetAnchorInteractive(false)
		return
	end

	display:EnsureFrames()
	display:ApplyOptions(options)
	UpdateContent(options)

	-- Owned here rather than by the test-mode toggle, so flipping the module switch while a
	-- test is running shows or hides the drag anchor and its caption with it.
	display:SetAnchorInteractive(testModeActive)
end

function M:Init()
	db = mini:GetSavedVars()
	previousTestSoundEnabled = db.Modules.HealerCCModule.Sound.Enabled

	sound:Init()
	display:Init()
	CreateEvents()
	ApplyInitialState()
end
