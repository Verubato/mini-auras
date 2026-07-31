---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local iconSlotContainer = addon.Core.IconSlotContainer
local eventGate = addon.Core.EventGate
local inspectorFacade = addon.Core.InspectorFacade
local kickData = addon.Core.KickData
local paused = false
local testModeActive = false
local enabled = false
---@type Db
local db

-- fallback icon (rogue Kick)
local KICK_ICON = C_Spell.GetSpellTexture(1766)

---@type { string: boolean }
local kickedByUnits = {}

---@type KickBar
local kickBar = {
	Container = nil, ---@type IconSlotContainer?
	Anchor = nil, ---@type table?
	ActiveSlots = {}, ---@type table<number, {Key: number, Timer: table}>
	MaxSlots = 10,
}

local FRIENDLY_UNITS_TO_WATCH = {
	"player",
	"party1",
	"party2",
}

---@type { string: table }
local partyUnitsEventsFrames = {}
---@type EventGate?
local matchPrepGate
local worldEventsFrame
local playerSpecEventsFrame
local minKickCooldown = 15

-- per arena unit computed at arena prep


---@class KickTimerModule : IModule
local M = {}
addon.Modules.KickTimerModule = M

local function IsArena()
	local inInstance, instanceType = IsInInstance()

	return inInstance and instanceType == "arena"
end

local function GetPlayerSpecId()
	local specIndex = GetSpecialization()
	if not specIndex then
		return nil
	end
	local specId = GetSpecializationInfo(specIndex)
	if specId and specId > 0 then
		return specId
	end
	return nil
end

local function CreateFrames()
	local options = db.Modules.KickTimerModule
	local iconOptions = options.Icons
	local size = tonumber(iconOptions.Size) or 50
	local spacing = options.IconSpacing or 2

	local container = iconSlotContainer:New(UIParent, kickBar.MaxSlots, size, spacing, "Kick Timer", nil, "Kick Timer")
	container.Frame:SetClampedToScreen(true)
	container.Frame:SetMovable(false)
	container.Frame:EnableMouse(false)
	container.Frame:SetDontSavePosition(true)
	container.Frame:RegisterForDrag("LeftButton")
	container.Frame:SetScript("OnDragStart", container.Frame.StartMoving)
	container.Frame:SetScript("OnDragStop", function(frameSelf)
		frameSelf:StopMovingOrSizing()

		local point, movedRelativeTo, relativePoint, x, y = frameSelf:GetPoint()
		options.Point = point
		options.RelativePoint = relativePoint
		options.RelativeTo = (movedRelativeTo and movedRelativeTo:GetName()) or "UIParent"
		options.Offset.X = x
		options.Offset.Y = y
	end)

	local relativeTo = _G[options.RelativeTo] or UIParent
	container.Frame:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)

	kickBar.Container = container
	kickBar.Anchor = container.Frame
end

---@param options KickTimerModuleOptions
local function ApplyStyle(options)
	if not kickBar.Container then
		return
	end

	kickBar.Container:SetIconSize(tonumber(options.Icons.Size) or 50)
	kickBar.Container:SetSpacing(options.IconSpacing or 2)
end

local function UpdateKickBarVisibility()
	if not kickBar.Container or not kickBar.Anchor then
		return
	end

	local usedCount = kickBar.Container:GetUsedSlotCount()
	if usedCount == 0 then
		kickBar.Anchor:Hide()
	else
		kickBar.Anchor:Show()
	end
end

local function ClearIcons()
	-- Cancel all active timers
	for _, slotData in pairs(kickBar.ActiveSlots) do
		if slotData.Timer then
			slotData.Timer:Cancel()
		end
	end

	wipe(kickBar.ActiveSlots)

	if kickBar.Container then
		kickBar.Container:ResetAllSlots()
	end

	UpdateKickBarVisibility()
end

---@param options KickTimerModuleOptions
local function ApplyLayout(options)
	local frame = kickBar.Anchor

	if not frame then
		return
	end

	local relativeTo = _G[options.RelativeTo] or UIParent

	frame:ClearAllPoints()
	frame:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
end

local function GetNextAvailableSlot()
	for i = 1, kickBar.MaxSlots do
		if not kickBar.ActiveSlots[i] then
			return i
		end
	end
	return nil
end

local function CreateKickEntry(duration, icon)
	if not kickBar.Container then
		return
	end

	local slotIndex = GetNextAvailableSlot()
	if not slotIndex then
		return
	end

	local key = math.random()
	local iconOptions = db.Modules.KickTimerModule.Icons

	kickBar.Container:SetSlot(slotIndex, {
		Texture = icon,
		DurationObject = wowEx:CreateDuration(GetTime(), duration),
		Alpha = true,
		ReverseCooldown = iconOptions.ReverseCooldown or false,
		Glow = iconOptions.Glow or false,
		FontScale = db.FontScale,
	})

	local timer = not testModeActive and C_Timer.NewTimer(duration, function()
		local slotData = kickBar.ActiveSlots[slotIndex]
		if slotData and slotData.Key == key then
			kickBar.Container:SetSlotUnused(slotIndex)
			kickBar.ActiveSlots[slotIndex] = nil
			UpdateKickBarVisibility()
		end
	end) or nil

	kickBar.ActiveSlots[slotIndex] = {
		Key = key,
		Timer = timer,
	}

	UpdateKickBarVisibility()
end

---@param specId number?
local function KickedBySpec(specId)
	if not specId then
		return
	end

	local specInfo = kickData.SpecData[specId]

	if not specInfo or not specInfo.KickCd then
		return
	end

	CreateKickEntry(specInfo.KickCd, KICK_ICON)
end

local function Kicked()
	CreateKickEntry(minKickCooldown, KICK_ICON)
end

local function OnFriendlyUnitEvent(unit, _, event, ...)
	if paused then
		return
	end

	if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" or event == "UNIT_SPELLCAST_EMPOWER_START" then
		kickedByUnits[unit] = false
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		if kickedByUnits[unit] then
			return
		end

		local kickedBy = select(4, ...)
		if not kickedBy then
			return
		end

		kickedByUnits[unit] = true
		Kicked()
	elseif event == "UNIT_SPELLCAST_EMPOWER_STOP" then
		if kickedByUnits[unit] then
			return
		end

		-- interruptedBy is arg 5 (arg 4 is "complete")
		local kickedBy = select(5, ...)
		if not kickedBy then
			return
		end

		kickedByUnits[unit] = true
		Kicked()
	end
end

local function UpdateMinKickCooldown()
	local minCd = 15
	local found = false

	local specs = GetNumArenaOpponentSpecs()

	for i = 1, specs do
		local specId = inspectorFacade:GetUnitSpecId("arena" .. i)
		if specId and specId > 0 then
			local info = kickData.SpecData[specId]
			local cd = info and info.KickCd
			if cd then
				if not found or cd < minCd then
					minCd = cd
				end
				found = true
			end
		end
	end

	minKickCooldown = found and minCd or 15
end

local function OnArenaPrep()
	UpdateMinKickCooldown()
	ClearIcons()
end

local function Disable()
	if not enabled then
		return
	end

	for _, unit in ipairs(FRIENDLY_UNITS_TO_WATCH) do
		local frame = partyUnitsEventsFrames[unit]
		if frame then
			frame:UnregisterEvent("UNIT_SPELLCAST_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_INTERRUPTED")
			frame:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
			frame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_EMPOWER_STOP")
			frame:SetScript("OnEvent", nil)
		end
		kickedByUnits[unit] = nil
	end

	ClearIcons()

	if kickBar.Anchor then
		kickBar.Anchor:Hide()
	end

	enabled = false
end

local function Enable()
	if enabled then
		return
	end

	for _, unit in ipairs(FRIENDLY_UNITS_TO_WATCH) do
		local frame = partyUnitsEventsFrames[unit]
		if frame then
			frame:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_EMPOWER_STOP", unit)
			frame:SetScript("OnEvent", function(...)
				OnFriendlyUnitEvent(unit, ...)
			end)
		end
	end

	-- Positioning is left to ApplyLayout, which Refresh runs immediately after this.
	if kickBar.Anchor then
		kickBar.Anchor:Show()
	end

	enabled = true
end

-- The cast events only produce icons inside an arena, so they stay unregistered elsewhere
-- even while the module is enabled for this spec.
---@param active boolean
local function SetEventsActive(active)
	if active and IsArena() then
		Enable()
	else
		Disable()
	end
end

local function OnEnteringWorld()
	-- Prep data only exists inside arenas; keep the event off elsewhere. Registered even
	-- while the module itself is disabled, as they might re-enable before gates open.
	matchPrepGate:SetActive(IsArena())

	M:Refresh()

	if IsArena() then
		OnArenaPrep()
	end
end

local function ShowTestIcons()
	-- Cancel all active timers but don't reset slots yet
	for _, slotData in pairs(kickBar.ActiveSlots) do
		if slotData.Timer then
			slotData.Timer:Cancel()
		end
	end
	wipe(kickBar.ActiveSlots)

	-- Show test kicks: mage, hunter, rogue
	KickedBySpec(62) -- mage
	KickedBySpec(254) -- hunter
	KickedBySpec(259) -- rogue

	-- Clear any unused slots beyond the test icons
	local testIconCount = 3
	if kickBar.Container then
		for i = testIconCount + 1, kickBar.Container.Count do
			kickBar.Container:SetSlotUnused(i)
		end
	end
end

---@param options KickTimerModuleOptions
function M:IsEnabledForPlayer(options)
	if not options or not options.Enabled then
		return false
	end

	-- nothing toggled on
	if not (options.Enabled.Always or options.Enabled.Caster or options.Enabled.Healer) then
		return false
	end

	if options.Enabled.Always then
		return true
	end

	local specId = GetPlayerSpecId()
	if not specId then
		-- no data, just assume enabled in this case
		return true
	end

	local info = kickData.SpecData[specId]
	if not info then
		return false
	end

	if options.Enabled.Healer and info.IsHealer then
		return true
	end

	if options.Enabled.Caster and info.IsCaster then
		return true
	end

	return false
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
end

-- Lifecycle

---@return KickTimerModuleOptions?
local function GetOptions()
	return db and db.Modules.KickTimerModule
end

---@return boolean
local function IsEnabled()
	-- No moduleUtil check here: the kick timer carries its own per-spec enabled values, and
	-- the generic check would report false for them.
	return M:IsEnabledForPlayer(GetOptions())
end

local function Teardown()
	ClearIcons()

	if kickBar.Anchor then
		kickBar.Anchor:Hide()
	end
end

local function EnsureFrames()
	if kickBar.Container then
		return
	end

	CreateFrames()
end

---@param options KickTimerModuleOptions
local function ApplyOptions(options)
	ApplyLayout(options)
	ApplyStyle(options)
end

-- Live icons are pushed in by the cast events, so only the fake ones need rebuilding here.
local function UpdateContent()
	if testModeActive then
		ShowTestIcons()
	end
end

---@param active boolean
local function SetAnchorInteractive(active)
	local anchor = kickBar.Anchor

	if not anchor then
		return
	end

	anchor:SetMovable(active)
	anchor:EnableMouse(active)
	anchor:SetShown(active)
end

---@param active boolean
local function SetTestMode(active)
	testModeActive = active

	if active then
		Pause()
	else
		ClearIcons()
		Resume()
	end

	M:Refresh()
	SetAnchorInteractive(active)
end

local function CreateEvents()
	for _, unit in ipairs(FRIENDLY_UNITS_TO_WATCH) do
		partyUnitsEventsFrames[unit] = CreateFrame("Frame")
	end

	-- Registered by OnEnteringWorld's gate, and only inside arenas.
	local matchEventsFrame = CreateFrame("Frame")
	matchEventsFrame:SetScript("OnEvent", OnArenaPrep)
	matchPrepGate = eventGate:New(matchEventsFrame, { "ARENA_PREP_OPPONENT_SPECIALIZATIONS" })

	worldEventsFrame = CreateFrame("Frame")
	worldEventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	worldEventsFrame:SetScript("OnEvent", OnEnteringWorld)

	playerSpecEventsFrame = CreateFrame("Frame")
	playerSpecEventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	playerSpecEventsFrame:SetScript("OnEvent", function(_, event, unit)
		if event == "PLAYER_SPECIALIZATION_CHANGED" and unit == "player" then
			M:Refresh()
		end
	end)
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

	SetEventsActive(isEnabled)

	if not isEnabled then
		Teardown()
		return
	end

	EnsureFrames()
	ApplyOptions(options)
	UpdateContent(options)
end

function M:Init()
	db = mini:GetSavedVars()

	CreateFrames()
	CreateEvents()
	ApplyInitialState()
end

---@class KickBar
---@field Container IconSlotContainer?
---@field Anchor table?
---@field ActiveSlots table<number, {Key: number, Timer: table}>
---@field MaxSlots number