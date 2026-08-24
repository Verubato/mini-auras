---@type string, Addon
local _, addon = ...
local frames = addon.Core.Frames
local trinketsTracker = addon.Core.TrinketsTracker
local eventGate = addon.Core.EventGate
local moduleLifecycle = addon.Core.ModuleLifecycle
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName

-- Loaded before this file in TOC order.
local display = addon.Modules.Trinkets.Display

---@class TrinketsModule : IModule
local M = {}
addon.Modules.Trinkets.Module = M
addon.Modules.TrinketsModule = M

---@type ModuleLifecycle?
local lifecycle
---@type EventGate?
local worldGate
-- Owns the unit-frame hooks, which can never be taken back off, so it outlives the gated
-- world events.
local hookFrame
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
		-- A refresh right away does not take.
		QueueRefresh()
	end
end

local function IsInArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "arena"
end

local function OnTrinketDataChanged(unit)
	if not lifecycle:IsActive() or paused then
		return
	end

	if unit then
		display:Render(unit)
		return
	end

	-- No unit means a match-state change or the arena gate opening. Every unit frame addon has
	-- built by then, so this pass replaces the anchors taken during the loading screen.
	QueueRefresh()
end

---Frame addons build, sort, and hide their party frames long after the arena's world event, and
---several replace the Blizzard frames only once their own are up. An anchor taken before that
---settles points at a frame nobody shows any more.
local function OnFramesChanged()
	if not lifecycle:IsActive() then
		return
	end

	-- Nothing is on screen outside an arena, so a raid's worth of frame churn buys nothing.
	-- Test mode is the exception because the icons are up there to be positioned.
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

local function Setup()
	trinketsTracker:RegisterCallback(OnTrinketDataChanged)
	InstallFrameHooks()

	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	worldGate = eventGate:New(eventsFrame, { "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE" })
end

-- The roster and world events are the module's only event source, so they stay registered only
-- while it is awake. paused rides the same edges, and test mode flips it in between.
local function OnEnable()
	paused = false
	worldGate:SetActive(true)
end

local function OnDisable()
	paused = true
	worldGate:SetActive(false)
	display:Teardown()
end

local function Apply()
	display:EnsureFrames()
	display:ApplyOptions()
	display:UpdateContent()
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	lifecycle:Refresh()
end

function M:Init()
	display:Init()

	lifecycle = moduleLifecycle:New({
		GetOptions = GetOptions,
		IsEnabled = IsEnabled,
		Setup = Setup,
		OnEnable = OnEnable,
		OnDisable = OnDisable,
		Apply = Apply,
	})
end
