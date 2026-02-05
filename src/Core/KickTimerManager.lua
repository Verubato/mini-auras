---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local enabled = false
---@type Db
local db

-- rogue kick icon
local kickIcon = C_Spell.GetSpellTexture(1766)

---@type { string: boolean }
local kickedByUnit = {}

---@type KickBar
local kickBar = {
	Icons = {},
	Size = 50,
	Spacing = 1,
}

local unitsToWatch = {
	"player",
	"party1",
	"party2",
}

---@type { string: table }
local unitEventsFrames = {}
local arenaEventsFrame
local playerSpecEventsFrame
local minKickCooldown = 15

---@class SpecKickInfo
---@field KickCd number?
---@field IsCaster boolean
---@field IsHealer boolean

---@type table<number, SpecKickInfo>
local specInfoBySpecId = {
	-- Rogue
	[259] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Assassination
	[260] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Outlaw
	[261] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Subtlety

	-- Warrior
	[71] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Arms
	[72] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Fury
	[73] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Protection

	-- Death Knight
	[250] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Blood
	[251] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Frost
	[252] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Unholy

	-- Demon Hunter
	[577] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Havoc
	[581] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Vengeance
	[1480] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Devourer

	-- Monk
	[268] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Brewmaster
	[269] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Windwalker
	[270] = { KickCd = 15, IsCaster = false, IsHealer = true }, -- Mistweaver

	-- Paladin
	[65] = { KickCd = 15, IsCaster = false, IsHealer = true }, -- Holy
	[66] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Protection
	[70] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Retribution

	-- Druid
	[102] = { KickCd = 60, IsCaster = true, IsHealer = false }, -- Balance
	[103] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Feral
	[104] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Guardian
	[105] = { KickCd = nil, IsCaster = false, IsHealer = true }, -- Restoration

	-- Hunter
	[253] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Beast Mastery
	[254] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Marksmanship
	[255] = { KickCd = 15, IsCaster = false, IsHealer = false }, -- Survival

	-- Mage
	[62] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Arcane
	[63] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Fire
	[64] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Frost

	-- Warlock
	[265] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Affliction
	[266] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Demonology
	[267] = { KickCd = 24, IsCaster = true, IsHealer = false }, -- Destruction

	-- Shaman
	[262] = { KickCd = 12, IsCaster = true, IsHealer = false }, -- Elemental
	[263] = { KickCd = 12, IsCaster = false, IsHealer = false }, -- Enhancement
	[264] = { KickCd = 30, IsCaster = false, IsHealer = true }, -- Restoration

	-- Evoker
	[1467] = { KickCd = 40, IsCaster = true, IsHealer = false }, -- Devastation
	[1468] = { KickCd = 40, IsCaster = false, IsHealer = true }, -- Preservation
	[1473] = { KickCd = 40, IsCaster = true, IsHealer = false }, -- Augmentation

	-- Priest
	[256] = { KickCd = nil, IsCaster = false, IsHealer = true }, -- Discipline
	[257] = { KickCd = nil, IsCaster = false, IsHealer = true }, -- Holy
	[258] = { KickCd = 45, IsCaster = true, IsHealer = false }, -- Shadow
}

---@class KickTimerManager
local M = {}
addon.KickTimerManager = M

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

local function EnsureKickBar()
	local options = db.KickTimer
	local relativeTo = _G[options.RelativeTo] or UIParent
	local frame = CreateFrame("Frame", addonName .. "KickBar", UIParent, "BackdropTemplate")

	frame:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
	frame:SetSize(200, kickBar.Size)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:SetMovable(false)
	frame:EnableMouse(false)
	frame:SetDontSavePosition(true)
	frame:SetIgnoreParentScale(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(frameSelf)
		frameSelf:StopMovingOrSizing()

		local point, movedRelativeTo, relativePoint, x, y = frameSelf:GetPoint()
		options.Point = point
		options.RelativePoint = relativePoint
		options.RelativeTo = (movedRelativeTo and movedRelativeTo:GetName()) or "UIParent"
		options.Offset.X = x
		options.Offset.Y = y
	end)

	kickBar.Anchor = frame
end

local function ApplyKickBarIconOptions()
	local options = db.KickTimer
	local iconOptions = options.Icons

	kickBar.Size = iconOptions.Size or 50

	if kickBar.Anchor then
		kickBar.Anchor:SetHeight(kickBar.Size)
	end

	for _, frame in ipairs(kickBar.Icons) do
		frame:SetSize(kickBar.Size, kickBar.Size)
		if frame.Icon then
			frame.Icon:SetAllPoints()
		end
		if frame.Cooldown then
			frame.Cooldown:SetReverse(iconOptions.ReverseCooldown)
		end
	end
end

local function LayoutKickBar()
	local x = 4
	local anyActive = false

	for _, iconFrame in ipairs(kickBar.Icons) do
		if iconFrame.Active then
			iconFrame:ClearAllPoints()
			iconFrame:SetPoint("LEFT", kickBar.Anchor, "LEFT", x, 0)
			x = x + kickBar.Size + kickBar.Spacing
			anyActive = true
		end
	end

	kickBar.Anchor:SetWidth(math.max(200, x))

	if anyActive then
		kickBar.Anchor:Show()
	else
		kickBar.Anchor:Hide()
	end
end

local function CreateKickIcon(texture, reverseCooldown)
	local frame = CreateFrame("Frame", nil, kickBar.Anchor)
	frame:SetSize(kickBar.Size, kickBar.Size)

	local icon = frame:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture(texture)

	local cd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
	cd:SetAllPoints()
	cd:SetReverse(reverseCooldown)
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)

	frame.Icon = icon
	frame.Cooldown = cd
	frame.Active = false
	frame:Hide()

	return frame
end

local function GetOrCreateIcon()
	for _, frame in ipairs(kickBar.Icons) do
		if not frame.Active then
			local iconOptions = db.KickTimer.Icons
			frame:SetSize(kickBar.Size, kickBar.Size)
			frame.Cooldown:SetReverse(iconOptions.ReverseCooldown)
			return frame
		end
	end

	local iconOptions = db.KickTimer.Icons
	local frame = CreateKickIcon(kickIcon, iconOptions.ReverseCooldown)
	table.insert(kickBar.Icons, frame)
	return frame
end

local function OnUnitEvent(unit, _, event, ...)
	if event == "UNIT_SPELLCAST_START" then
		kickedByUnit[unit] = false
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
		if kickedByUnit[unit] then
			return
		end

		local kickedBy = select(4, ...)
		if not kickedBy then
			return
		end

		kickedByUnit[unit] = true
		M:Kicked()
	end
end

local function UpdateMinKickCooldownFromArenaSpecs()
	local minCd = 15
	local found = false

	for i = 1, 5 do
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

local function OnArenaPrep()
	UpdateMinKickCooldownFromArenaSpecs()
	M:ClearIcons()
end

local function Disable()
	for _, unit in ipairs(unitsToWatch) do
		local frame = unitEventsFrames[unit]
		if frame then
			frame:UnregisterEvent("UNIT_SPELLCAST_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_INTERRUPTED")
			frame:SetScript("OnEvent", nil)
		end
		kickedByUnit[unit] = nil
	end

	if arenaEventsFrame then
		arenaEventsFrame:UnregisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
		arenaEventsFrame:SetScript("OnEvent", nil)
	end

	if kickBar.Anchor then
		kickBar.Anchor:Hide()
	end

	M:ClearIcons()

	enabled = false
end

local function Enable(options)
	if enabled then
		return
	end

	for _, unit in ipairs(unitsToWatch) do
		local frame = unitEventsFrames[unit]
		if frame then
			frame:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unit)
			frame:SetScript("OnEvent", function(...)
				OnUnitEvent(unit, ...)
			end)
		end
	end

	arenaEventsFrame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
	arenaEventsFrame:SetScript("OnEvent", OnArenaPrep)

	ApplyKickBarIconOptions()

	local relativeTo = _G[options.RelativeTo] or UIParent
	kickBar.Anchor:ClearAllPoints()
	kickBar.Anchor:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
	kickBar.Anchor:Show()

	enabled = true
end

---@param options KickTimerOptions
function M:IsEnabledForPlayer(options)
	if not options then
		return false
	end

	-- nothing toggled on
	if not (options.AllEnabled or options.CasterEnabled or options.HealerEnabled) then
		return false
	end

	-- AllEnabled ignores player role/spec
	if options.AllEnabled then
		return true
	end

	-- spec-based match
	local specId = GetPlayerSpecId()
	if not specId then
		return false
	end

	local info = specInfoBySpecId[specId]
	if not info then
		return false
	end

	if options.HealerEnabled and info.IsHealer then
		return true
	end

	if options.CasterEnabled and info.IsCaster then
		return true
	end

	return false
end

function M:Kicked()
	local duration = minKickCooldown
	local frame = GetOrCreateIcon()
	local key = math.random()

	frame.Active = true
	frame.Key = key
	frame:Show()
	frame.Cooldown:SetCooldown(GetTime(), duration)

	LayoutKickBar()

	C_Timer.After(duration, function()
		if frame and frame.Active and frame.Key == key then
			frame.Active = false
			frame:Hide()
			LayoutKickBar()
		end
	end)
end

function M:ClearIcons()
	for _, frame in ipairs(kickBar.Icons) do
		frame.Active = false
		frame:Hide()
	end

	if kickBar.Anchor then
		LayoutKickBar()
	end
end

function M:GetContainer()
	return kickBar.Anchor
end

function M:Init()
	db = mini:GetSavedVars()

	kickBar.Size = db.KickTimer.Icons.Size

	EnsureKickBar()

	for _, unit in ipairs(unitsToWatch) do
		unitEventsFrames[unit] = CreateFrame("Frame")
	end

	arenaEventsFrame = CreateFrame("Frame")

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

function M:Refresh()
	local options = db.KickTimer

	if not M:IsEnabledForPlayer(options) then
		Disable()
		return
	end

	Enable(options)
end

---@class KickBar
---@field Anchor table?
---@field Icons table
---@field Size number
---@field Spacing number
