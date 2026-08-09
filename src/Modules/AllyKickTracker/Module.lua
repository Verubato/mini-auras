---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local eventGate = addon.Core.EventGate
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local barTextures = addon.Core.BarTextures

-- Loaded before this file in TOC order.
local observer = addon.Modules.AllyKickTracker.Observer
local display = addon.Modules.AllyKickTracker.Display

-- Repaint rate while a row is counting down. The loop only runs then: with the list empty there
-- is nothing to animate, so it stops and the next interrupt starts it again.
local TICK_INTERVAL = 0.05
local MODULE_EVENTS = {
	"PLAYER_ENTERING_WORLD",
	-- A key starts without a zone change, and the pull before it is not worth carrying in.
	"CHALLENGE_MODE_START",
	-- The player's spec decides both whether they have an interrupt and which one, and it arrives
	-- after login as well as changing on demand.
	"PLAYER_SPECIALIZATION_CHANGED",
}

-- Test-mode rows: one fresh, one halfway and one nearly gone, so the whole range is on screen at
-- once while the list is being positioned. Real rows carry secret values; these are plain, which
-- is the point - the preview has to be readable.
local TEST_RECORDS = {
	{ Unit = "player", Class = "SHAMAN", SpellId = 57994, Elapsed = 0 },
	{ Unit = "party1", Class = "MAGE", SpellId = 2139, Elapsed = 6, Marker = 1 },
	{ Unit = "party2", Class = "ROGUE", SpellId = 1766, Elapsed = 12, Marker = 8 },
}

---@type Db
local db
---@type AllyKickDisplayInstance?
local instance
---@type EventGate?
local moduleGate
local eventsFrame
local tickFrame
local ticking = false
local timeSinceTick = 0
local enabled = false
local testModeActive = false
-- The rows currently on screen, and the scratch the next set is built into. Kept apart so a tick
-- that produces the same set costs no re-layout.
---@type AllyKickRecord[]
local shownOrder = {}
---@type AllyKickRecord[]
local orderScratch = {}
-- Rewritten on every apply; the display copies the fields out and keeps nothing.
local displayOptionsScratch = {}
---@type AllyKickRecord[]
local testRecords = {}

---@class AllyKickTrackerModule : IModule
local M = {}
addon.Modules.AllyKickTracker.Module = M
addon.Modules.AllyKickTrackerModule = M

---@return AllyKickTrackerModuleOptions?
local function GetOptions()
	return db and db.Modules.AllyKickTrackerModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.AllyKickTracker)
end

---The player's own row first when they asked for it, then the interrupts seen, newest first, up to
---the configured height. The observer appends, so walking it backwards is the whole sort - rows
---never reorder once recorded.
---@param options AllyKickTrackerModuleOptions
---@return AllyKickRecord[]
local function BuildOrder(options)
	local source = testModeActive and testRecords or observer:GetRecords()
	local limit = options.MaxBars or 5

	wipe(orderScratch)

	-- Pinned above the history rather than mixed into it: it answers "can I kick right now",
	-- which is a different question from "who kicked what", and it is the only row whose answer
	-- the client will actually tell us.
	if options.ShowOwnCooldown and not testModeActive then
		local own = observer:GetOwnRecord()

		if own then
			orderScratch[1] = own
		end
	end

	for index = #source, 1, -1 do
		if #orderScratch >= limit then
			break
		end

		orderScratch[#orderScratch + 1] = source[index]
	end

	return orderScratch
end

---True while a row on screen is still counting down, which is the only reason to keep the repaint
---loop running. The player's own row sits there ready without needing one.
---@return boolean
local function AnyCountingDown()
	local now = GetTime()

	for index = 1, #shownOrder do
		if shownOrder[index].ExpireAt > now then
			return true
		end
	end

	return false
end

---@param ordered AllyKickRecord[]
---@return boolean
local function OrderChanged(ordered)
	if #ordered ~= #shownOrder then
		return true
	end

	for index = 1, #ordered do
		if ordered[index] ~= shownOrder[index] then
			return true
		end
	end

	return false
end

local function UpdateVisibility()
	if not instance then
		return
	end

	-- Test mode keeps the list up regardless: it is what the user drags to position it.
	instance.Frame:SetShown(testModeActive or #shownOrder > 0)
end

---Hands the current rows to the display, but only re-lays-out when the set actually moved.
local function ApplyRecords()
	local options = GetOptions()

	if not instance or not options then
		return
	end

	local ordered = BuildOrder(options)

	if OrderChanged(ordered) then
		wipe(shownOrder)

		for index = 1, #ordered do
			shownOrder[index] = ordered[index]
		end

		instance:SetRecords(shownOrder)
	else
		instance:Update()
	end

	UpdateVisibility()
end

local function StopTicking()
	if not ticking then
		return
	end

	ticking = false
	tickFrame:SetScript("OnUpdate", nil)
end

local function OnTick(_, elapsed)
	timeSinceTick = timeSinceTick + elapsed

	if timeSinceTick < TICK_INTERVAL then
		return
	end

	timeSinceTick = 0

	-- Test rows are the module's own and never expire, so the preview stays put while the list is
	-- being dragged into place.
	if not testModeActive and observer:Prune(GetTime()) then
		ApplyRecords()
	elseif instance.Frame:IsShown() then
		instance:Update()
	end

	-- The player's own row stays on screen once it is ready, but a static row needs no repainting.
	if not testModeActive and not AnyCountingDown() then
		StopTicking()
	end
end

---Starts the repaint loop, which then runs until the last row has expired.
local function StartTicking()
	if ticking or not enabled then
		return
	end

	ticking = true
	timeSinceTick = 0
	tickFrame:SetScript("OnUpdate", OnTick)
end

local function OnInterruptRecorded()
	ApplyRecords()
	StartTicking()
end

local function OnEvent(_, event, unit)
	local options = GetOptions()

	if not options then
		return
	end

	if event == "PLAYER_SPECIALIZATION_CHANGED" then
		if unit ~= "player" then
			return
		end

		observer:RefreshOwn()
		ApplyRecords()
		return
	end

	-- An arena, a fresh dungeon or a key pull all start over; the kicks from before it are not
	-- worth carrying across.
	observer:Clear()
	observer:RefreshOwn()
	ApplyRecords()
end

local function BuildTestRecords()
	local now = GetTime()

	wipe(testRecords)

	for index, spec in ipairs(TEST_RECORDS) do
		testRecords[index] = {
			Name = UnitName(spec.Unit) or spec.Unit,
			Class = spec.Class,
			Icon = C_Spell.GetSpellTexture(spec.SpellId),
			Marker = spec.Marker,
			-- Far enough out that the preview never expires while it is being positioned; the
			-- countdown still reads as a row partway through its life.
			ExpireAt = now + (60 - spec.Elapsed),
			Duration = 60,
		}
	end
end

local function EnsureFrames()
	if instance then
		return
	end

	instance = display:New(UIParent, L["Ready"])

	-- Function-form position: a profile switch replaces the options table, so it has to be
	-- re-read on every drop.
	moduleUtil:MakeMovable(instance.Frame, GetOptions)
end

---@param options AllyKickTrackerModuleOptions
local function ApplyLayout(options)
	if not instance then
		return
	end

	local relativeTo = _G[options.RelativeTo] or UIParent

	instance.Frame:ClearAllPoints()
	instance.Frame:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
end

---@param options AllyKickTrackerModuleOptions
local function ApplyStyle(options)
	if not instance then
		return
	end

	local bars = options.Bars
	local scratch = displayOptionsScratch
	scratch.Width = bars.Width
	scratch.Height = bars.Height
	scratch.Spacing = options.BarSpacing
	scratch.Grow = options.Grow
	scratch.FillTexture = barTextures:Resolve(bars.Texture)

	instance:SetOptions(scratch)
end

---Draggable whenever it is on screen and unlocked, rather than only while test mode is up: the
---rows are their own preview, so there is nothing to switch on before moving them. Locking hands
---the mouse back to whatever sits underneath.
---@param options AllyKickTrackerModuleOptions
local function ApplyInteractivity(options)
	if not instance then
		return
	end

	local movable = not options.Locked

	instance.Frame:SetMovable(movable)
	instance.Frame:EnableMouse(movable)
end

---@param options AllyKickTrackerModuleOptions
local function ApplyOptions(options)
	ApplyLayout(options)
	ApplyStyle(options)
	ApplyInteractivity(options)
end

---@param active boolean
local function SetEventsActive(active)
	if moduleGate then
		moduleGate:SetActive(active)
	end

	if active then
		observer:Start()
	else
		observer:Stop()
	end
end

local function Teardown()
	StopTicking()
	wipe(shownOrder)

	if instance then
		instance:SetRecords(shownOrder)
		instance.Frame:Hide()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active

	if active then
		BuildTestRecords()
	else
		wipe(testRecords)
	end

	M:Refresh()

	if active then
		StartTicking()
	end
end

local function CreateEvents()
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	moduleGate = eventGate:New(eventsFrame, MODULE_EVENTS)

	tickFrame = CreateFrame("Frame", nil, UIParent)

	observer:SetRecordCallback(OnInterruptRecorded)
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
	local options = GetOptions()

	if not options then
		return
	end

	local isEnabled = IsEnabled()

	enabled = isEnabled
	SetEventsActive(isEnabled)

	if not isEnabled then
		Teardown()
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	observer:RefreshOwn()
	ApplyRecords()

	-- The rows are draggable outside test mode too (whenever unlocked), so the caption is the
	-- only part of the drag affordance tied to testing. Set here rather than in the test-mode
	-- toggle, so a module enabled mid-test gets it too.
	moduleUtil:SetTestLabel(instance.Frame, testModeActive and (L["Ally Kicks_Short"] or L["Ally Kicks"]) or nil)

	if AnyCountingDown() or testModeActive then
		StartTicking()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	CreateEvents()
	ApplyInitialState()
end
