---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.Core.Frames
local eventGate = addon.Core.EventGate
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local duelPoller = addon.Core.DuelPoller

-- Loaded before this file in TOC order.
local display = addon.Modules.CrowdControl.Display

---@class CrowdControlModule : IModule
local M = {}
addon.Modules.CrowdControl.Module = M
addon.Modules.CrowdControlModule = M

---@type EventGate?
local rosterGate
---@type table?
local eventsFrame
---@type Db
local db
local testModeActive = false
---@type DuelPollerSubscriber?
local duelSub
-- Scratch for the watched units handed to the duel poller each refresh.
local duelUnitsScratch = {}
-- Deferred as well as coalesced: the frame addons (danders/grid) rebuild on the same event, so
-- the anchors are only worth reading once they have settled.
local QueueRefresh = moduleUtil:Coalesced(function()
	M:Refresh()
end)

---Hands the poller the units on screen right now. Re-seeded per refresh rather than tracked
---per frame: the frames retarget constantly (sorting, roster changes), and a baseline for a unit
---nobody is watching would fire a refresh for nothing.
local function SeedDuelBaselines()
	if not duelSub then
		return
	end

	duelSub:ClearAll()

	for _, unit in ipairs(display:CollectWatchedUnits(duelUnitsScratch)) do
		duelSub:Seed(unit)
	end
end

local function OnFrameSortSorted()
	M:Refresh()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		QueueRefresh()
	elseif event == "UNIT_PET" then
		-- A pet was summoned/dismissed; refresh so the opt-in pet unit frame containers show/hide
		-- with it. Only relevant when IncludePetFrame is enabled, so skip the work otherwise.
		local petOptions = db.Modules.PetCCModule
		if petOptions and petOptions.IncludePetFrame and moduleUtil:IsModuleEnabled(moduleName.PetCC) then
			QueueRefresh()
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

-- Live auras are pushed in by the aura containers, so only the fake ones rebuild here.
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

	-- Repopulate the kick icons the test-mode reset wiped.
	if not active then
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

	-- A unit leaving or re-entering the player's visible world has no event, and it decides
	-- whether the engine evaluates the CC filter at all, so the budgets are recomputed when the
	-- poller sees it flip. Registered for the module's lifetime; the predicate below gates it.
	-- Coalesced: the poller fires once per flipped token, and a raid riding out of range flips
	-- many in one tick - each would otherwise pay a full refresh.
	duelSub = duelPoller:Register(function()
		return IsEnabled()
	end, function()
		QueueRefresh()
	end)
end

local function InstallHooks()
	frames:InstallUnitFrameHooks(eventsFrame, {
		OnSetUnit = function(frame, unit)
			display:OnCufSetUnit(frame, unit)
			-- A watcher born or re-pointed here is unknown to the duel poller until a refresh
			-- reseeds the baselines; without one, a later visible-world flip goes unnoticed.
			QueueRefresh()
		end,
		OnUpdateVisible = function(frame)
			display:OnCufUpdateVisible(frame)
		end,
		OnSorted = OnFrameSortSorted,
		OnVisibilityChanged = function()
			if IsEnabled() then
				display:EnsureWatchers()
				-- Same as OnSetUnit: the watchers just ensured need their baselines seeded.
				QueueRefresh()
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
	SeedDuelBaselines()
end

function M:Init()
	db = mini:GetSavedVars()

	display:Init()
	CreateEvents()
	InstallHooks()
	ApplyInitialState()
end
