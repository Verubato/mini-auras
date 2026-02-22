---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local frames = addon.Core.Frames
local spellCache = addon.Utils.SpellCache
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local unitsUtil = addon.Utils.Units
local eventFrame
local enabled = false
local paused = false
local testModeActive = false
local defaultSpellId = 336126
local defaultTrinketIcon
---@type { [table]: TrinketWatcher }
local watchers = {}
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

local function NormalizeCooldownValues(start, duration)
	if not start or not duration then
		return start, duration
	end

	return start / 1000, duration / 1000
end

local function SetIconState(container, spellId, start, duration)
	if not container then
		return
	end

	local tex = GetSpellTexture(spellId) or defaultTrinketIcon or "Interface\\Icons\\INV_Misc_QuestionMark"

	-- Always show the icon, even when not on cooldown
	if not spellId or not start or not duration then
		-- Show icon without cooldown
		container:SetSlot(1, {
			Texture = tex,
			StartTime = 0,
			Duration = 0,
			AlphaBoolean = true,
			ReverseCooldown = false,
			Glow = false,
			FontScale = db.FontScale,
		})
		return
	end

	-- Show icon with cooldown
	container:SetSlot(1, {
		Texture = tex,
		StartTime = start,
		Duration = duration,
		AlphaBoolean = true,
		ReverseCooldown = false,
		Glow = false,
		FontScale = db.FontScale,
	})
end

local function UpdateUnit(unit, spellId, start, duration)
	for _, w in pairs(watchers) do
		if w.Unit == unit then
			SetIconState(w.Container, spellId, start, duration)
		end
	end
end

local function ClearAll()
	for _, w in pairs(watchers) do
		SetIconState(w.Container, nil, nil, nil)
	end
end

local function AnchorContainerToFrame(container, anchorFrame)
	container.Frame:ClearAllPoints()
	container.Frame:SetPoint(options.Point, anchorFrame, options.RelativePoint, options.Offset.X, options.Offset.Y)
end

local function EnsureWatcher(anchorFrame, unit)
	local watcher = watchers[anchorFrame]
	if watcher then
		watcher.Unit = unit
		return watcher
	end

	local size = tonumber(options.Icons.Size) or 32
	local container = iconSlotContainer:New(UIParent, 1, size, db.IconSpacing or 2, "Trinkets")
	container.Frame:SetIgnoreParentScale(true)
	container.Frame:SetIgnoreParentAlpha(true)

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

local function RequestAll()
	if not IsInArena() then
		return
	end

	for _, unit in ipairs(units) do
		if UnitExists(unit) then
			C_PvP.RequestCrowdControlSpell(unit)
		end
	end
end

local function GetTrinketData(unit)
	local spellId, start, duration = C_PvP.GetArenaCrowdControlInfo(unit)

	if not start or not duration then
		return spellId, start, duration
	end

	if issecretvalue(start) or issecretvalue(duration) then
		start = GetTime()
		-- ffs, they give us duration in milliseconds as a secret value which we can't convert to seconds
		-- so we'll just have to hard code these values
		duration = unitsUtil:IsHealer(unit) and 90 or 120
	else
		-- TODO: does this even happen anymore or are they always secret?
		start, duration = NormalizeCooldownValues(start, duration)
	end

	return spellId, start, duration
end

-- Refresh only one unit (using unitTarget from ARENA_COOLDOWNS_UPDATE)
local function RefreshUnit(unit)
	if not unit or unit == "" or not UnitExists(unit) then
		return
	end

	local spellId, start, duration = GetTrinketData(unit)

	if not spellId or not start or not duration then
		-- don't overwrite existing data if they've already trinketed
		return
	end

	for _, watcher in pairs(watchers) do
		if watcher.Container and watcher.Unit == unit then
			SetIconState(watcher.Container, spellId, start, duration)
			break
		end
	end
end

local function RefreshAll()
	for _, watcher in pairs(watchers) do
		local unit = watcher.Unit
		local container = watcher.Container

		if container and unit and UnitExists(unit) then
			local spellId, start, duration = GetTrinketData(unit)
			-- Always update icon state, even if no cooldown
			SetIconState(container, spellId, start, duration)
		elseif container then
			-- Show default icon when unit doesn't exist
			SetIconState(container, nil, nil, nil)
		end
	end
end

local function UpdateVisibility()
	local moduleEnabled = moduleUtil:IsModuleEnabled(moduleName.Trinkets)
	local show = moduleEnabled and (IsInArena() or testModeActive)

	for _, watcher in pairs(watchers) do
		if watcher.Container and watcher.Anchor then
			if show then
				frames:ShowHideFrame(watcher.Container.Frame, watcher.Anchor, testModeActive, options.ExcludePlayer)
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
			RequestAll()
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
		C_Timer.After(1, function()
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
			spellId = defaultSpellId,
			start = now,
			duration = 90,
		},
		party1 = {
			spellId = defaultSpellId,
			start = now,
			duration = 120,
		},
		party2 = {
			spellId = defaultSpellId,
			start = now,
			duration = 60,
		},
		party3 = {
			spellId = defaultSpellId,
			start = now,
			duration = 45,
		},
	}

	for unit, state in pairs(stateByUnit or {}) do
		if state then
			UpdateUnit(unit, state.spellId, state.start, state.duration)
		else
			UpdateUnit(unit, nil, nil, nil)
		end
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
	M:Refresh()
end

function M:StartTesting()
	testModeActive = true
	Pause()
	M:Refresh()
	RefreshTestTrinkets()
end

function M:StopTesting()
	testModeActive = false
	ClearAll()
	Resume()
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
		RequestAll()
		RefreshAll()
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
