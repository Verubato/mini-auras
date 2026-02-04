---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
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
local minKickCooldown = 12
local interruptCdBySpec = {
	-- Rogue
	[259] = 15, -- Assassination
	[260] = 15, -- Outlaw
	[261] = 15, -- Subtlety

	-- Warrior
	[71] = 15, -- Arms
	[72] = 15, -- Fury
	[73] = 15, -- Protection

	-- Death Knight
	[250] = 15, -- Blood
	[251] = 15, -- Frost
	[252] = 15, -- Unholy

	-- Demon Hunter
	[577] = 15, -- Havoc
	[581] = 15, -- Vengeance
	[1480] = 15, -- Devourer

	-- Monk
	[268] = 15, -- Brewmaster
	[269] = 15, -- Windwalker

	-- Paladin:
	[65] = 15, -- Holy
	[66] = 15, -- Protection
	[70] = 15, -- Retribution

	-- Druid
	[103] = 15, -- Feral
	[104] = 15, -- Guardian

	-- Hunter
	[253] = 24, -- Beast Mastery
	[254] = 24, -- Marksmanship
	[255] = 15, -- Survival

	-- Mage
	[62] = 24, -- Arcane
	[63] = 24, -- Fire
	[64] = 24, -- Frost

	-- Warlock
	[265] = 24, -- Affliction
	[266] = 24, -- Demonology
	[267] = 24, -- Destruction

	-- Shaman
	[262] = 12, -- Elemental
	[263] = 12, -- Enhancement
	[264] = 30, -- Restoration

	-- Evoker
	[1467] = 40, -- Devastation
	[1468] = 40, -- Preservation
	[1473] = 40, -- Augmentation
}

---@class KickTimerManager
local M = {}
addon.KickTimerManager = M

local function EnsureKickBar()
	local options = db.KickTimer
	local relativeTo = _G[options.RelativeTo] or UIParent
	local frame = CreateFrame("Frame", addonName .. "KickBar", UIParent, "BackdropTemplate")

	frame:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
	frame:SetSize(200, kickBar.Size)
	frame:SetFrameStrata("HIGH")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
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

	-- Drive layout sizing from config
	kickBar.Size = iconOptions.Size or 50

	-- Keep the anchor height in sync
	if kickBar.Anchor then
		kickBar.Anchor:SetHeight(kickBar.Size)
	end

	-- Update any existing icons (so changing size in settings updates live)
	for _, frame in ipairs(kickBar.Icons) do
		frame:SetSize(kickBar.Size, kickBar.Size)

		if frame.Icon then
			frame.Icon:SetAllPoints() -- ensure it fills after resize
		end

		if frame.Cooldown then
			frame.Cooldown:SetReverse(iconOptions.ReverseCooldown)
		end
	end
end

local function LayoutKickBar()
	local x = 4

	for _, iconFrame in ipairs(kickBar.Icons) do
		if iconFrame.Active then
			iconFrame:ClearAllPoints()
			iconFrame:SetPoint("LEFT", kickBar.Anchor, "LEFT", x, 0)
			x = x + kickBar.Size + kickBar.Spacing
		end
	end

	kickBar.Anchor:SetWidth(math.max(200, x))
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
	-- try reuse first
	for _, frame in ipairs(kickBar.Icons) do
		if not frame.Active then
			-- make sure reused frames reflect latest settings
			local iconOptions = db.KickTimer.Icons
			frame:SetSize(kickBar.Size, kickBar.Size)
			frame.Cooldown:SetReverse(iconOptions.ReverseCooldown)
			return frame
		end
	end

	-- none free, create new
	local iconOptions = db.KickTimer.Icons
	local frame = CreateKickIcon(kickIcon, iconOptions.ReverseCooldown)
	table.insert(kickBar.Icons, frame)
	return frame
end

local function OnEvent(unit, _, event, ...)
	if event == "UNIT_SPELLCAST_START" then
		kickedByUnit[unit] = false
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
		if kickedByUnit[unit] then
			return
		end

		local kickedBy = select(4, ...)

		if not kickedBy then
			-- if this happens, blizzard have completely stopped this from working
			return
		end

		kickedByUnit[unit] = true
		M:Kicked()
	end
end

local function UpdateMinKickCooldownFromArenaSpecs()
	local minCd = 12
	local found = false

	for i = 1, 5 do
		local specId = GetArenaOpponentSpec(i)
		if specId and specId > 0 then
			local cd = interruptCdBySpec[specId]
			if cd then
				if not found or cd < minCd then
					minCd = cd
				end
				found = true
			end
		end
	end

	minKickCooldown = found and minCd or 12
end

local function OnArenaPrep()
	UpdateMinKickCooldownFromArenaSpecs()

	M:ClearIcons()
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
		-- frame might have been cleared manually
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

	LayoutKickBar()
end

function M:GetContainer()
	return kickBar.Anchor
end

function M:Init()
	db = mini:GetSavedVars()

	kickBar.Size = db.KickTimer.Icons.Size

	EnsureKickBar()

	for _, unit in ipairs(unitsToWatch) do
		local frame = CreateFrame("Frame")
		unitEventsFrames[unit] = frame
	end

	arenaEventsFrame = CreateFrame("Frame")

	M:Refresh()
end

function M:Refresh()
	local options = db.KickTimer

	for unit, frame in pairs(unitEventsFrames) do
		if options.Enabled then
			frame:RegisterUnitEvent("UNIT_SPELLCAST_START", unit)
			frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", unit)
			frame:SetScript("OnEvent", function(...)
				OnEvent(unit, ...)
			end)
		else
			frame:UnregisterEvent("UNIT_SPELLCAST_START")
			frame:UnregisterEvent("UNIT_SPELLCAST_INTERRUPTED")
			frame:SetScript("OnEvent", nil)
		end
	end

	if options.Enabled then
		arenaEventsFrame:RegisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
		arenaEventsFrame:SetScript("OnEvent", OnArenaPrep)

		ApplyKickBarIconOptions()

		local relativeTo = _G[options.RelativeTo] or UIParent

		kickBar.Anchor:ClearAllPoints()
		kickBar.Anchor:SetPoint(options.Point, relativeTo, options.RelativePoint, options.Offset.X, options.Offset.Y)
		kickBar.Anchor:Show()
	else
		arenaEventsFrame:UnregisterEvent("ARENA_PREP_OPPONENT_SPECIALIZATIONS")
		arenaEventsFrame:SetScript("OnEvent", nil)

		kickBar.Anchor:Hide()
	end
end

---@class KickBar
---@field Anchor table?
---@field Icons table
---@field Size number
---@field Spacing number
