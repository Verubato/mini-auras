---@type string, Addon
local addonName, addon = ...
local mini = addon.Core.Framework
local spellCache = addon.Utils.SpellCache
local iconSlotContainer = addon.Core.IconSlotContainer
local paused = false
local testModeActive = false
local enabled = false
---@type Db
local db

-- fallback icon (rogue Kick)
local kickIcon = spellCache:GetSpellTexture(1766)

---@type { string: boolean }
local kickedByUnits = {}

---@type KickBar
local kickBar = {
	Container = nil, ---@type IconSlotContainer?
	Anchor = nil, ---@type table?
	ActiveSlots = {}, ---@type table<number, {Key: number, Timer: table}>
	MaxSlots = 10,
}

local friendlyUnitsToWatch = {
	"player",
	"party1",
	"party2",
}

local enemyUnitsToWatch = {
	"arena1",
	"arena2",
	"arena3",
}

---@type { string: table }
local partyUnitsEventsFrames = {}
---@type { string: table }
local enemyUnitsEventsFrames = {}
local matchEventsFrame
local worldEventsFrame
local playerSpecEventsFrame

local minKickCooldown = 15

---@type EnemyLastCastState
local lastEnemyCastState = {
	Time = nil,
	Unit = nil,
}

-- mininum delta between enemy cast success and us getting interrupted
-- unsure if it's affected by lag or not, needs testing
local lastEnemyKickTimeDuration = 0.5

-- per arena unit computed at arena prep
local kickDurationsByUnit = {} ---@type table<string, number?>
local kickIconsByUnit = {} ---@type table<string, any?>

local function KI(spellId)
	return spellId and spellCache:GetSpellTexture(spellId) or nil
end

---@class SpecKickInfo
---@field KickCd number?
---@field IsCaster boolean
---@field IsHealer boolean
---@field KickIcon any? -- texture path/id for the kick/interrupt ability

---@type table<number, SpecKickInfo>
local specInfoBySpecId = {
	-- Rogue — Kick
	[259] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(1766) }, -- Assassination
	[260] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(1766) }, -- Outlaw
	[261] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(1766) }, -- Subtlety

	-- Warrior — Pummel
	[71] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(6552) }, -- Arms
	[72] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(6552) }, -- Fury
	[73] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(6552) }, -- Protection

	-- Death Knight — Mind Freeze
	[250] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(47528) }, -- Blood
	[251] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(47528) }, -- Frost
	[252] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(47528) }, -- Unholy

	-- Demon Hunter — Disrupt
	[577] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(183752) }, -- Havoc
	[581] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(183752) }, -- Vengeance
	[1480] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(183752) }, -- Devourer

	-- Monk — Spear Hand Strike
	[268] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(116705) }, -- Brewmaster
	[269] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(116705) }, -- Windwalker
	[270] = { KickCd = nil, IsCaster = false, IsHealer = true, KickIcon = nil }, -- Mistweaver

	-- Paladin — Rebuke
	[65] = { KickCd = nil, IsCaster = false, IsHealer = true, KickIcon = nil }, -- Holy
	[66] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(96231) }, -- Protection
	[70] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(96231) }, -- Retribution

	-- Druid
	[102] = { KickCd = 60, IsCaster = true, IsHealer = false, KickIcon = KI(78675) }, -- Balance (Solar Beam)
	[103] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(106839) }, -- Feral (Skull Bash)
	[104] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(106839) }, -- Guardian (Skull Bash)
	[105] = { KickCd = nil, IsCaster = false, IsHealer = true, KickIcon = nil }, -- Restoration

	-- Hunter — Counter Shot
	[253] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(147362) }, -- Beast Mastery
	[254] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(147362) }, -- Marksmanship
	[255] = { KickCd = 15, IsCaster = false, IsHealer = false, KickIcon = KI(147362) }, -- Survival

	-- Mage — Counterspell
	[62] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(2139) }, -- Arcane
	[63] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(2139) }, -- Fire
	[64] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(2139) }, -- Frost

	-- Warlock — Spell Lock (Felhunter)
	[265] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(19647) }, -- Affliction
	[266] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(19647) }, -- Demonology
	[267] = { KickCd = 24, IsCaster = true, IsHealer = false, KickIcon = KI(19647) }, -- Destruction

	-- Shaman — Wind Shear
	[262] = { KickCd = 12, IsCaster = true, IsHealer = false, KickIcon = KI(57994) }, -- Elemental
	[263] = { KickCd = 12, IsCaster = false, IsHealer = false, KickIcon = KI(57994) }, -- Enhancement
	[264] = { KickCd = 30, IsCaster = false, IsHealer = true, KickIcon = KI(57994) }, -- Restoration

	-- Evoker — Quell
	[1467] = { KickCd = 20, IsCaster = true, IsHealer = false, KickIcon = KI(351338) }, -- Devastation
	[1468] = { KickCd = nil, IsCaster = false, IsHealer = true, KickIcon = KI(351338) }, -- Preservation
	[1473] = { KickCd = nil, IsCaster = true, IsHealer = false, KickIcon = nil }, -- Augmentation

	-- Priest
	[256] = { KickCd = nil, IsCaster = false, IsHealer = true, KickIcon = nil }, -- Discipline
	[257] = { KickCd = nil, IsCaster = false, IsHealer = true, KickIcon = nil }, -- Holy
	[258] = { KickCd = 45, IsCaster = true, IsHealer = false, KickIcon = KI(15487) }, -- Shadow (Silence)
}

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

local function CreateKickBar()
	local options = db.Modules.KickTimerModule
	local iconOptions = options.Icons
	local size = tonumber(iconOptions.Size) or 50
	local spacing = 2

	local container = iconSlotContainer:New(UIParent, kickBar.MaxSlots, size, spacing)
	container.Frame:SetFrameStrata("HIGH")
	container.Frame:SetClampedToScreen(true)
	container.Frame:SetIgnoreParentScale(true)
	container.Frame:SetClampedToScreen(true)

	-- Create wrapper frame for positioning and dragging
	local anchor = CreateFrame("Frame", addonName .. "KickBar", UIParent)
	anchor:SetSize(200, size)
	anchor:SetMovable(false)
	anchor:EnableMouse(false)
	anchor:SetDontSavePosition(true)
	anchor:RegisterForDrag("LeftButton")
	anchor:SetScript("OnDragStart", anchor.StartMoving)
	anchor:SetScript("OnDragStop", function(frameSelf)
		frameSelf:StopMovingOrSizing()

		local point, movedRelativeTo, relativePoint, x, y = frameSelf:GetPoint()
		options.Point = point
		options.RelativePoint = relativePoint
		options.RelativeTo = (movedRelativeTo and movedRelativeTo:GetName()) or "UIParent"
		options.Offset.X = x
		options.Offset.Y = y
	end)

	local relativeTo = _G[options.RelativeTo] or UIParent
	anchor:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)

	-- Attach container to anchor
	container.Frame:SetParent(anchor)
	container.Frame:SetPoint("CENTER", anchor, "CENTER", 0, 0)

	kickBar.Container = container
	kickBar.Anchor = anchor
end

local function ApplyKickBarIconOptions()
	local options = db.Modules.KickTimerModule
	local iconOptions = options.Icons
	local size = tonumber(iconOptions.Size) or 50

	if kickBar.Container then
		kickBar.Container:SetIconSize(size)
	end

	if kickBar.Anchor then
		kickBar.Anchor:SetHeight(size)
	end
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

local function PositionKickBar()
	local frame = kickBar.Anchor

	if not frame then
		return
	end

	local options = db.Modules.KickTimerModule
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

	kickBar.Container:SetLayer(slotIndex, 1, {
		Texture = icon,
		StartTime = GetTime(),
		Duration = duration,
		AlphaBoolean = true,
		ReverseCooldown = iconOptions.ReverseCooldown or false,
		Glow = iconOptions.Glow or false,
		FontScale = db.FontScale,
	})
	kickBar.Container:FinalizeSlot(slotIndex, 1)
	kickBar.Container:SetSlotUsed(slotIndex)

	local timer = C_Timer.NewTimer(duration, function()
		local slotData = kickBar.ActiveSlots[slotIndex]
		if slotData and slotData.Key == key then
			kickBar.Container:SetSlotUnused(slotIndex)
			kickBar.ActiveSlots[slotIndex] = nil
			UpdateKickBarVisibility()
		end
	end)

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

	local specInfo = specInfoBySpecId[specId]

	if not specInfo or not specInfo.KickCd or not specInfo.KickIcon then
		return
	end

	local duration = specInfo.KickCd
	local tex = specInfo.KickIcon

	CreateKickEntry(duration, tex)
end

---@param kickedBy string?
local function Kicked(kickedBy)
	local duration = minKickCooldown
	local tex = kickIcon

	if kickedBy then
		if kickDurationsByUnit[kickedBy] then
			duration = kickDurationsByUnit[kickedBy]
		end

		if kickIconsByUnit[kickedBy] then
			tex = kickIconsByUnit[kickedBy]
		end
	end

	CreateKickEntry(duration, tex)
end

local function OnFriendlyUnitEvent(unit, _, event, ...)
	if paused then
		return
	end

	if event == "UNIT_SPELLCAST_START" then
		kickedByUnits[unit] = false
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
		if kickedByUnits[unit] then
			return
		end

		local kickedBy = select(4, ...)
		if not kickedBy then
			return
		end

		local now = GetTime()
		local u = nil

		if lastEnemyCastState.Unit and lastEnemyCastState.Time then
			local timeSinceLastAction = now - lastEnemyCastState.Time
			if lastEnemyCastState.Time and timeSinceLastAction < lastEnemyKickTimeDuration then
				u = lastEnemyCastState.Unit
			end
		end

		kickedByUnits[unit] = true
		Kicked(u)
	end
end

local function OnEnemyUnitEvent(unit, _, event)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		lastEnemyCastState.Unit = unit
		lastEnemyCastState.Time = GetTime()
	end
end

local function UpdateMinKickCooldown()
	local minCd = 15
	local found = false

	local specs = GetNumArenaOpponentSpecs()

	for i = 1, specs do
		local specId = GetArenaOpponentSpec(i)
		if specId and specId > 0 then
			local info = specInfoBySpecId[specId]
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

local function UpdateKickDurations()
	wipe(kickDurationsByUnit)
	wipe(kickIconsByUnit)

	local numSpecs = GetNumArenaOpponentSpecs()

	for i = 1, numSpecs do
		local unit = "arena" .. i
		local specId = GetArenaOpponentSpec(i)
		local info = specInfoBySpecId[specId]

		kickDurationsByUnit[unit] = info and info.KickCd or nil
		kickIconsByUnit[unit] = (info and info.KickIcon) or nil
	end
end

local function OnArenaPrep()
	UpdateMinKickCooldown()
	UpdateKickDurations()
	ClearIcons()
end

local function Disable()
	if not enabled then
		return
	end

	for _, unit in ipairs(friendlyUnitsToWatch) do
		local frame = partyUnitsEventsFrames[unit]
		if frame then
			frame:UnregisterEvent("UNIT_SPELLCAST_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_INTERRUPTED")
			frame:SetScript("OnEvent", nil)
		end
		kickedByUnits[unit] = nil
	end

	for _, unit in ipairs(enemyUnitsToWatch) do
		local frame = enemyUnitsEventsFrames[unit]
		if frame then
			frame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
			frame:SetScript("OnEvent", nil)
		end
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

	for _, unit in ipairs(friendlyUnitsToWatch) do
		local frame = partyUnitsEventsFrames[unit]
		if frame then
			frame:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unit)
			frame:SetScript("OnEvent", function(...)
				OnFriendlyUnitEvent(unit, ...)
			end)
		end
	end

	for _, unit in ipairs(enemyUnitsToWatch) do
		local frame = enemyUnitsEventsFrames[unit]
		if frame then
			frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", unit)
			frame:SetScript("OnEvent", function(...)
				OnEnemyUnitEvent(unit, ...)
			end)
		end
	end

	local options = db.Modules.KickTimerModule
	local relativeTo = _G[options.RelativeTo] or UIParent
	kickBar.Anchor:ClearAllPoints()
	kickBar.Anchor:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
	kickBar.Anchor:Show()

	enabled = true
end

local function EnableDisable()
	-- don't do a moduleUtil check here, as we cover that inside IsEnabledForPlayer
	-- and we'd end up with a falsey response as the kick timer has different enabled values
	if not M:IsEnabledForPlayer(db.Modules.KickTimerModule) then
		Disable()
		return
	end

	if not IsArena() then
		Disable()
		return
	end

	Enable()
end

local function OnEnteringWorld()
	EnableDisable()

	-- always prep event if disabled, as they might re-enable before gates open
	if IsArena() then
		OnArenaPrep()
	end
end

local function ShowTestIcons()
	ClearIcons()
	-- Show test kicks: mage, hunter, rogue
	KickedBySpec(62) -- mage
	KickedBySpec(254) -- hunter
	KickedBySpec(259) -- rogue
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

	local info = specInfoBySpecId[specId]
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

function M:StartTesting()
	testModeActive = true
	Pause()
	M:Refresh()

	local container = kickBar.Anchor

	if not container then
		return
	end

	container:SetMovable(true)
	container:EnableMouse(true)
	container:Show()
end

function M:StopTesting()
	testModeActive = false
	Resume()
	ClearIcons()
	M:Refresh()

	local container = kickBar.Anchor

	if not container then
		return
	end

	container:SetMovable(false)
	container:EnableMouse(false)
	container:Hide()
end

function M:Refresh()
	EnableDisable()

	-- Apply icon options even if already enabled (for config changes)
	ApplyKickBarIconOptions()

	PositionKickBar()

	local container = kickBar.Anchor

	if not container then
		return
	end

	if not M:IsEnabledForPlayer(db.Modules.KickTimerModule) then
		ClearIcons()
		container:Hide()
		return
	end

	if testModeActive then
		ShowTestIcons()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	CreateKickBar()

	for _, unit in ipairs(friendlyUnitsToWatch) do
		partyUnitsEventsFrames[unit] = CreateFrame("Frame")
	end

	for _, unit in ipairs(enemyUnitsToWatch) do
		enemyUnitsEventsFrames[unit] = CreateFrame("Frame")
	end

	-- always populate even if disabled, as they might re-enable during arena
	matchEventsFrame = CreateFrame("Frame")
	matchEventsFrame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
	matchEventsFrame:SetScript("OnEvent", OnArenaPrep)

	worldEventsFrame = CreateFrame("Frame")
	worldEventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	worldEventsFrame:SetScript("OnEvent", OnEnteringWorld)

	playerSpecEventsFrame = CreateFrame("Frame")
	playerSpecEventsFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	playerSpecEventsFrame:SetScript("OnEvent", function(_, event, ...)
		if event == "PLAYER_SPECIALIZATION_CHANGED" then
			local unit = ...
			if unit == "player" then
				M:Refresh()
			end
		end
	end)

	M:Refresh()
end

---@class KickBar
---@field Container IconSlotContainer?
---@field Anchor table?
---@field ActiveSlots table<number, {Key: number, Timer: table}>
---@field MaxSlots number

---@class EnemyLastCastState
---@field Time number?
---@field Unit string?
