---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local frames = addon.Core.Frames
local spellCache = addon.Utils.SpellCache
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local eventFrame
local enabled = false
local paused = false
local testModeActive = false
local defaultSpellId = 336126
local defaultTrinketIcon
---@type { [table]: TrinketWatcher }
local watchers = {}
-- Cache of known-active trinket cooldowns, keyed by unit string.
-- Only populated from non-secret data so math on Start/Duration is safe.
---@type table<string, { SpellId: number, Start: number, Duration: number }>
---@type Db
local db
---@type TrinketsModuleOptions
local options

---@class TrinketsModule : IModule
local M = {}
addon.Modules.TrinketsModule = M

local units = {
	-- track self
	"player",
	-- track party123 for test mode purposes
	"party1",
	"party2",
	"party3",
	-- arena is a raid, so we want to track raid units
	"raid1",
	"raid2",
	"raid3",
}

local function IsInArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and (instanceType == "arena")
end

local function GetSpellTexture(spellId)
	if not spellId then
		return nil
	end

	return spellCache:GetSpellTexture(spellId)
end

local function IsTrackedUnit(unit)
	for _, u in ipairs(units) do
		if u == unit then
			return true
		end
	end

	return false
end

local function SetIconState(container, durationData)
	if not container then
		return
	end

	local tex = defaultTrinketIcon or "Interface\\Icons\\INV_Misc_QuestionMark"

	container:SetSlot(1, {
		Texture = tex,
		DurationObject = durationData or wowEx:CreateDuration(0, 0),
		Alpha = true,
		ReverseCooldown = false,
		Glow = false,
		FontScale = db.FontScale,
	})
end

local function UpdateUnit(unit, durationData)
	for _, w in pairs(watchers) do
		if w.Unit == unit then
			SetIconState(w.Container, durationData)
		end
	end
end

local function ClearAll()
	for _, w in pairs(watchers) do
		SetIconState(w.Container, nil)
	end
end

local function AnchorContainerToFrame(container, anchorFrame)
	container.Frame:ClearAllPoints()
	container.Frame:SetPoint(options.Point, anchorFrame, options.RelativePoint, options.Offset.X, options.Offset.Y)
	container.Frame:SetAlpha(1)
end

local function EnsureWatcher(anchorFrame, unit)
	local watcher = watchers[anchorFrame]
	if watcher then
		watcher.Unit = unit
		return watcher
	end

	local size = tonumber(options.Icons.Size) or 32
	local container = iconSlotContainer:New(UIParent, 1, size, db.IconSpacing or 2, "Trinkets")

	watcher = {
		Anchor = anchorFrame,
		Unit = unit,
		Container = container,
	}
	watchers[anchorFrame] = watcher

	return watcher
end

local function DestroyWatcher(anchorFrame)
	local watcher = watchers[anchorFrame]
	if not watcher then
		return
	end

	if watcher.Container then
		watcher.Container:ResetAllSlots()
		watcher.Container.Frame:Hide()
		watcher.Container.Frame:SetParent(nil)
	end

	watchers[anchorFrame] = nil
end

local function RebuildAnchors()
	local anchors = frames:GetAll(true, testModeActive)
	local seen = {}

	for _, anchor in ipairs(anchors) do
		if anchor and not (anchor.IsForbidden and anchor:IsForbidden()) then
			local unit = anchor.unit or (anchor.GetAttribute and anchor:GetAttribute("unit"))
			if unit and unit ~= "" and IsTrackedUnit(unit) then
				local w = EnsureWatcher(anchor, unit)
				seen[anchor] = true
				AnchorContainerToFrame(w.Container, anchor)
			end
		end
	end

	for anchorFrame in pairs(watchers) do
		if not seen[anchorFrame] then
			DestroyWatcher(anchorFrame)
		end
	end
end

local function RefreshUnit(unit)
	if not unit or unit == "" or not UnitExists(unit) then
		return
	end

	local durationData = C_PvP.GetArenaCrowdControlDuration(unit)

	if not durationData then
		return
	end

	for _, watcher in pairs(watchers) do
		if watcher.Container and watcher.Unit == unit then
			SetIconState(watcher.Container, durationData)
			break
		end
	end
end

local function RefreshAll()
	for _, watcher in pairs(watchers) do
		local unit = watcher.Unit
		local container = watcher.Container

		if container and unit and UnitExists(unit) then
			local durationData = C_PvP.GetArenaCrowdControlDuration(unit)
			SetIconState(container, durationData)
		elseif container then
			-- Show default icon when unit doesn't exist
			SetIconState(container, nil)
		end
	end
end

local function UpdateVisibility()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Trinkets)
	local show = moduleEnabled and (IsInArena() or testModeActive)

	for _, watcher in pairs(watchers) do
		if watcher.Container and watcher.Anchor then
			if show then
				local anchor = watcher.Anchor
				local unit = anchor.unit or (anchor.GetAttribute and anchor:GetAttribute("unit"))
				local shouldExclude = options.ExcludePlayer and unit and UnitIsUnit(unit, "player")
				if shouldExclude then
					watcher.Container.Frame:Hide()
				elseif anchor:IsVisible() then
					watcher.Container.Frame:SetAlpha(1)
					watcher.Container.Frame:Show()
				else
					watcher.Container.Frame:Hide()
				end
			else
				watcher.Container.Frame:Hide()
			end
		end
	end
end

local function OnEvent(_, event, ...)
	if paused then
		-- While paused, we still allow anchor rebuild + visibility so people can position frames,
		if event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_TARGET_CHANGED" then
			RebuildAnchors()
			UpdateVisibility()
		end
		return
	end

	if event == "PVP_MATCH_STATE_CHANGED" then
		local matchState = C_PvP.GetActiveMatchState()
		if matchState == Enum.PvPMatchState.StartUp then
			ClearAll()
			return
		end

		if matchState == Enum.PvPMatchState.Engaged then
			-- in case they trinketed before the gates opened
			RefreshAll()
			return
		end

		return
	end

	if event == "PLAYER_ENTERING_WORLD" then
		M:Refresh()
		return
	end

	if event == "GROUP_ROSTER_UPDATE" then
		-- for some  reason it doesn't work right away
		C_Timer.After(0, function()
			M:Refresh()
		end)
		return
	end

	if event == "ARENA_COOLDOWNS_UPDATE" then
		local unitTarget = ...

		if unitTarget and unitTarget ~= "" then
			RefreshUnit(unitTarget)
		else
			RefreshAll()
		end
		return
	end
end

local function RefreshTestTrinkets()
	local now = GetTime()

	-- Stagger durations so you can see different states
	local stateByUnit = {
		player = {
			start = now,
			duration = 90,
		},
		party1 = {
			start = now,
			duration = 120,
		},
		party2 = {
			start = now,
			duration = 60,
		},
		party3 = {
			start = now,
			duration = 45,
		},
	}

	for unit, state in pairs(stateByUnit or {}) do
		if state then
			UpdateUnit(unit, wowEx:CreateDuration(state.start, state.duration))
		else
			UpdateUnit(unit, nil)
		end
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

function M:StartTesting()
	testModeActive = true
	Pause()
	M:Refresh()
end

function M:StopTesting()
	testModeActive = false
	ClearAll()
	Resume()
	M:Refresh()
end

function M:Enable()
	if eventFrame then
		return
	end

	enabled = true
	paused = false

	eventFrame = CreateFrame("Frame")
	eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventFrame:RegisterEvent("ARENA_COOLDOWNS_UPDATE")
	eventFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
	eventFrame:SetScript("OnEvent", OnEvent)
end

function M:Disable()
	enabled = false
	paused = true

	if eventFrame then
		eventFrame:UnregisterAllEvents()
		eventFrame:SetScript("OnEvent", nil)
		eventFrame = nil
	end

	for anchorFrame in pairs(watchers) do
		DestroyWatcher(anchorFrame)
	end

	ClearAll()

	for _, watcher in pairs(watchers) do
		if watcher.Container then
			watcher.Container.Frame:Hide()
		end
	end
end

function M:Refresh()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Trinkets)

	if moduleEnabled and not enabled then
		M:Enable()
	elseif not moduleEnabled and enabled then
		M:Disable()
	end

	if not moduleEnabled then
		return
	end

	RebuildAnchors()
	UpdateVisibility()

	for _, watcher in pairs(watchers) do
		if watcher.Container then
			local size = tonumber(options.Icons.Size) or 32
			watcher.Container:SetIconSize(size)
			watcher.Container:SetSpacing(db.IconSpacing or 2)
		end
	end

	if moduleEnabled and IsInArena() then
		RefreshAll()
	elseif moduleEnabled and testModeActive then
		RefreshTestTrinkets()
	end
end

function M:Init()
	db = mini:GetSavedVars()
	options = db.Modules.TrinketsModule

	defaultTrinketIcon = GetSpellTexture(defaultSpellId)

	M:Refresh()
end

---@class TrinketWatcher
---@field Anchor table
---@field Unit string
---@field Container IconSlotContainer
