---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local trinketsTracker = addon.Core.TrinketsTracker
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local display = addon.Modules.Trinkets.Display

---@class TrinketsModule : IModule
local M = {}
addon.Modules.Trinkets.Module = M
addon.Modules.TrinketsModule = M

local eventFrame
-- Owns the unit-frame hooks, which can never be taken back off, so it outlives the gated
-- eventFrame above.
local hookFrame
local enabled = false
local paused = false
local QueueRefresh = moduleUtil:Coalesced(function()
	M:Refresh()
end)
local QueueAnchorRefresh = moduleUtil:Coalesced(function()
	if paused then
		display:RefreshAnchorsOnly()
	else
		M:Refresh()
	end
end)

local function OnEvent(_, event)
	if paused then
		-- While paused, we still allow anchor rebuild + visibility so people can position frames
		display:RefreshAnchorsOnly()
		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		M:Refresh()
	elseif event == "GROUP_ROSTER_UPDATE" then
		-- for some reason it doesn't work right away
		QueueRefresh()
	end
end

local function IsInArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "arena"
end

-- Trinket cooldown data changes arrive via TrinketsTracker (arena cooldown updates and
-- match-state transitions); this module only re-renders the affected slot.
local function OnTrinketDataChanged(unit)
	if not enabled or paused then
		return
	end

	if unit then
		display:Render(unit)
		return
	end

	-- No unit means a match-state change or the arena gate opening. Every unit frame addon has
	-- had its chance to build by then, so this is the pass that replaces anchors taken during
	-- the loading screen, when the frames on screen were not the ones that end up there.
	QueueRefresh()
end

---Frame addons build, sort, and hide their party frames long after the arena's world event, and
---several of them replace the Blizzard frames only once their own are up. An anchor taken before
---that settles points at a frame nobody shows any more, which is where the icons were left
---stranded until a reload.
local function OnFramesChanged()
	if not enabled then
		return
	end

	-- Nothing is on screen outside an arena, so a raid's worth of frame churn buys nothing.
	-- Test mode is the exception: the icons are up there to be positioned.
	if not IsInArena() and not paused then
		return
	end

	QueueAnchorRefresh()
end

local function InstallFrameHooks()
	hookFrame = CreateFrame("Frame")

	frames:InstallUnitFrameHooks(hookFrame, {
		OnSetUnit = OnFramesChanged,
		OnUpdateVisible = OnFramesChanged,
		OnSorted = OnFramesChanged,
		OnVisibilityChanged = OnFramesChanged,
	})
end

---@return TrinketsModuleOptions?
local function GetOptions()
	return display:GetOptions()
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.Trinkets)
end

---Edge-triggered: the roster/world events are the module's only event source, so they are
---created on wake and torn down on sleep.
---@param active boolean
local function SetEventsActive(active)
	if active == enabled then
		return
	end

	enabled = active
	paused = not active

	if active then
		eventFrame = CreateFrame("Frame")
		eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
		eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
		eventFrame:SetScript("OnEvent", OnEvent)
	elseif eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame:SetScript("OnEvent", nil)
		eventFrame = nil
	end
end

---@param active boolean
local function SetTestMode(active)
	display:SetTestMode(active)

	if active then
		paused = true
	else
		display:ClearAll()
		paused = false
	end

	M:Refresh()
end

local function InstallHooks()
	trinketsTracker:RegisterCallback(OnTrinketDataChanged)
	InstallFrameHooks()
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
	local moduleOptions = GetOptions()

	if not moduleOptions then
		return
	end

	local isEnabled = IsEnabled()

	SetEventsActive(isEnabled)

	if not isEnabled then
		display:Teardown()
		return
	end

	display:EnsureFrames()
	display:ApplyOptions()
	display:UpdateContent()
end

function M:Init()
	display:Init()
	InstallHooks()
	ApplyInitialState()
end
