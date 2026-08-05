---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local L = addon.L
local eventGate = addon.Core.EventGate
local inspector = addon.Core.Inspector
local moduleUtil = addon.Utils.ModuleUtil
local moduleName = addon.Utils.ModuleName
local barTextures = addon.Core.BarTextures

-- Loaded before this file in TOC order.
local tracker = addon.Modules.AllyKicks.Tracker
local display = addon.Modules.AllyKicks.Display

-- Repaint rate while something is counting down. The loop only runs then: with every interrupt
-- ready there is nothing to animate, so it stops and a cast starts it again.
local TICK_INTERVAL = 0.05
local MODULE_EVENTS = {
	"GROUP_ROSTER_UPDATE",
	"PLAYER_ENTERING_WORLD",
	"PLAYER_SPECIALIZATION_CHANGED",
	-- A key starts without a zone change, and every interrupt is up when it does.
	"CHALLENGE_MODE_START",
	-- Only used by the out-of-combat option, but registered either way: the option can be
	-- switched on mid-fight, and the gate is where registrations belong.
	"PLAYER_REGEN_DISABLED",
	"PLAYER_REGEN_ENABLED",
}

-- Test-mode roster: one ready, one mid-cooldown and one just pressed, so every visual state is
-- on screen at once while the bar is being positioned.
local TEST_ENTRIES = {
	{ Unit = "player", Class = "SHAMAN", SpellId = 57994, Cooldown = 12, Elapsed = 0 },
	{ Unit = "party1", Class = "MAGE", SpellId = 2139, Cooldown = 20, Elapsed = 12 },
	{ Unit = "party2", Class = "ROGUE", SpellId = 1766, Cooldown = 15, Elapsed = 15 },
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
local inCombat = false
local enabled = false
local testModeActive = false
-- The order currently on screen, and the scratch the next order is built into. Kept apart so a
-- tick that produces the same order costs no re-layout.
---@type AllyKickEntry[]
local shownOrder = {}
---@type AllyKickEntry[]
local orderScratch = {}
-- Rewritten on every apply; the display copies the fields out and keeps nothing.
local displayOptionsScratch = {}
---@type AllyKickEntry[]
local testEntries = {}

---@class AllyKickTrackerModule : IModule
local M = {}
addon.Modules.AllyKicks.Module = M
addon.Modules.AllyKickTrackerModule = M

---@return AllyKickTrackerModuleOptions?
local function GetOptions()
	return db and db.Modules.AllyKickTrackerModule
end

---@return boolean
local function IsEnabled()
	return moduleUtil:IsModuleEnabled(moduleName.AllyKickTracker)
end

---The moment a member's interrupt comes back, or 0 while it is ready.
---@param entry AllyKickEntry
---@return number
local function ReadyAt(entry)
	if entry.StartTime <= 0 then
		return 0
	end

	return entry.StartTime + (entry.Duration or entry.Cooldown)
end

---Readiness first, then whoever comes back soonest. The unit token breaks ties so members who
---are all ready hold a stable order instead of swapping places on every sort.
---@param a AllyKickEntry
---@param b AllyKickEntry
---@return boolean
local function ByReadiness(a, b)
	local readyA, readyB = ReadyAt(a), ReadyAt(b)

	if readyA ~= readyB then
		return readyA < readyB
	end

	return a.Unit < b.Unit
end

---@param options AllyKickTrackerModuleOptions
---@return AllyKickEntry[]
local function BuildOrder(options)
	local source = testModeActive and testEntries or tracker:GetEntries()
	-- Test mode shows every state at once, so its preview ignores the filter.
	local hideReady = options.HideWhenReady and not testModeActive
	local now = GetTime()

	wipe(orderScratch)

	for _, entry in ipairs(source) do
		if not (hideReady and ReadyAt(entry) <= now) then
			orderScratch[#orderScratch + 1] = entry
		end
	end

	if options.SortByReadiness then
		table.sort(orderScratch, ByReadiness)
	end

	for index = #orderScratch, (options.MaxBars or 5) + 1, -1 do
		orderScratch[index] = nil
	end

	return orderScratch
end

---@param ordered AllyKickEntry[]
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

---True when a bar on screen has come off cooldown, which only matters while ready bars are
---being filtered out - it means the list itself is stale rather than just its numbers.
---@return boolean
local function AnyShownReady()
	local now = GetTime()

	for index = 1, #shownOrder do
		if ReadyAt(shownOrder[index]) <= now then
			return true
		end
	end

	return false
end

---@return boolean
local function AnyOnCooldown()
	local now = GetTime()

	for index = 1, #shownOrder do
		if ReadyAt(shownOrder[index]) > now then
			return true
		end
	end

	return false
end

---@param options AllyKickTrackerModuleOptions
local function UpdateVisibility(options)
	if not instance then
		return
	end

	-- Test mode keeps the bar up regardless: it is what the user drags to position it.
	local show = testModeActive or #shownOrder > 0

	if show and not testModeActive and options.HideOutOfCombat and not inCombat then
		show = false
	end

	instance.Frame:SetShown(show)
end

---Re-sorts the entries and hands them to the display, but only re-lays-out the bars when the
---order actually moved.
local function ApplyEntries()
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

		instance:SetEntries(shownOrder)
	else
		instance:Update()
	end

	UpdateVisibility(options)
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

	local options = GetOptions()

	if options and options.HideWhenReady and AnyShownReady() then
		-- A bar whose cooldown just ended has to leave the list, not merely stop counting down.
		ApplyEntries()
	end

	if not instance.Frame:IsShown() then
		-- Nothing on screen to repaint, but the loop still has to notice the last expiry.
		if AnyOnCooldown() then
			return
		end

		StopTicking()
		return
	end

	-- Only the fills and countdowns move here. The order cannot: it is sorted on an absolute
	-- ready-at time, so nothing but a cast or a roster change can reshuffle it, and both of
	-- those re-sort on their own. Re-sorting per tick would be pure waste.
	instance:Update()

	if AnyOnCooldown() then
		return
	end

	-- Everything is back up, so there is nothing left to animate until the next cast.
	if options then
		UpdateVisibility(options)
	end

	StopTicking()
end

---Starts the repaint loop, which then runs until nothing is counting down.
local function StartTicking()
	if ticking or not enabled then
		return
	end

	ticking = true
	timeSinceTick = 0
	tickFrame:SetScript("OnUpdate", OnTick)
end

local function OnCooldownStarted()
	ApplyEntries()
	StartTicking()
end

local function OnRosterDataChanged()
	ApplyEntries()

	if AnyOnCooldown() then
		StartTicking()
	end
end

---@param options AllyKickTrackerModuleOptions
local function UpdateRoster(options)
	if testModeActive then
		return
	end

	tracker:Rebuild(not options.ExcludePlayer)
end

local function OnEvent(_, event, unit)
	local options = GetOptions()

	if not options then
		return
	end

	if event == "PLAYER_SPECIALIZATION_CHANGED" and unit ~= "player" then
		return
	end

	if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
		inCombat = event == "PLAYER_REGEN_DISABLED"
		UpdateVisibility(options)
		return
	end

	if event == "PLAYER_ENTERING_WORLD" or event == "CHALLENGE_MODE_START" then
		-- Cooldowns do not survive either in any way worth showing: an arena, a fresh dungeon
		-- or a key pull all start with everything up.
		tracker:ClearCooldowns()
	end

	UpdateRoster(options)
end

---Fires when a member's spec is resolved after the fact, which can change both whether they
---have an interrupt at all and which one it is.
local function OnSpecResolved()
	if not enabled or testModeActive then
		return
	end

	local options = GetOptions()

	if options then
		UpdateRoster(options)
	end
end

-- Test mode

local function BuildTestEntries()
	local now = GetTime()

	wipe(testEntries)

	for index, spec in ipairs(TEST_ENTRIES) do
		testEntries[index] = {
			Unit = spec.Unit,
			PetUnit = spec.Unit .. "pet",
			Name = UnitName(spec.Unit) or spec.Unit,
			Class = spec.Class,
			SpellId = spec.SpellId,
			Texture = C_Spell.GetSpellTexture(spec.SpellId),
			Cooldown = spec.Cooldown,
			-- Elapsed == Cooldown means it just came off cooldown, i.e. the ready state.
			StartTime = spec.Elapsed < spec.Cooldown and (now - spec.Elapsed) or 0,
		}
	end
end

-- Lifecycle

local function EnsureFrames()
	if instance then
		return
	end

	instance = display:New(UIParent, L["Ready"])

	local frame = instance.Frame
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(frameSelf)
		frameSelf:StopMovingOrSizing()

		local options = GetOptions()

		if not options then
			return
		end

		local point, movedRelativeTo, relativePoint, x, y = frameSelf:GetPoint()
		options.Point = point
		options.RelativePoint = relativePoint
		options.RelativeTo = (movedRelativeTo and movedRelativeTo:GetName()) or "UIParent"
		options.Offset.X = x
		options.Offset.Y = y
	end)
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
	scratch.ShowIcon = bars.ShowIcon
	scratch.ShowRaidTarget = bars.ShowRaidTarget

	instance:SetOptions(scratch)
end

---Draggable whenever it is on screen and unlocked, rather than only while test mode is up: the
---bars are their own preview, so there is nothing to switch on before moving them. Locking hands
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
		tracker:Start()
	else
		tracker:Stop()
	end
end

local function Teardown()
	StopTicking()
	wipe(shownOrder)

	if instance then
		instance:SetEntries(shownOrder)
		instance.Frame:Hide()
	end
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active

	if active then
		BuildTestEntries()
	else
		wipe(testEntries)
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

	tracker:SetRosterCallback(OnRosterDataChanged)
	tracker:SetCooldownCallback(OnCooldownStarted)

	-- Party specs arrive asynchronously, and a member's spec decides both whether they have an
	-- interrupt and which one, so the roster is rebuilt whenever one lands. FrameSort's
	-- inspector is preferred when it is present, exactly as the cooldown tracker does it.
	local frameSort = FrameSortApi and FrameSortApi.v3

	if frameSort and frameSort.Inspector then
		frameSort.Inspector:RegisterCallback(OnSpecResolved)
	else
		inspector:Init()
		inspector:RegisterCallback(OnSpecResolved)
	end
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
	UpdateRoster(options)
	ApplyEntries()

	if AnyOnCooldown() or testModeActive then
		StartTicking()
	end
end

---Toggles the tracker's cast log, which reports every spell a tracked member casts.
---@return boolean on
function M:ToggleDebug()
	return tracker:SetDebugging(not tracker:IsDebugging())
end

---Prints why the bars are (or are not) doing what they should: the gate, the roster, and what
---each tracked member's interrupt is currently doing.
function M:Diagnose()
	local options = GetOptions()

	if not options then
		mini:Notify("[Kicks] no options - the module never initialised")
		return
	end

	local inInstance, instanceType = IsInInstance()

	mini:Notify("[Kicks] enabled=%s (zone=%s, raid=%s), watching=%s, test=%s, ticking=%s",
		tostring(IsEnabled()), inInstance and instanceType or "world", tostring(IsInRaid()),
		tostring(tracker:IsWatching()), tostring(testModeActive), tostring(ticking))

	local enables = {}

	for _, key in ipairs({ "Always", "World", "Arena", "BattleGrounds", "Dungeons", "Raid" }) do
		enables[#enables + 1] = key .. "=" .. tostring(options.Enabled[key])
	end

	mini:Notify("[Kicks] " .. table.concat(enables, " "))

	local entries = tracker:GetEntries()
	local watched = tracker:GetWatchedUnits()

	mini:Notify("[Kicks] %d tracked, %d bars shown, frame %s", #entries, #shownOrder,
		instance and (instance.Frame:IsShown() and "shown" or "hidden") or "not built")
	mini:Notify("[Kicks] watching %d: %s", #watched,
		#watched > 0 and table.concat(watched, ", ") or "nobody")

	local now = GetTime()

	for _, entry in ipairs(entries) do
		local remaining = ReadyAt(entry) - now

		mini:Notify("[Kicks]   %s spell=%s cd=%ss %s", entry.Name, tostring(entry.SpellId),
			tostring(entry.Duration or entry.Cooldown),
			remaining > 0 and string.format("%.1fs left", remaining) or "ready")
	end

	if #entries == 0 then
		mini:Notify("[Kicks] nobody tracked - no group member's spec resolves to an interrupt")
	end
end

function M:Init()
	db = mini:GetSavedVars()
	inCombat = UnitAffectingCombat("player") == true

	CreateEvents()
	ApplyInitialState()
end
