---@type string, Addon
local addonName, addon = ...
local capabilities = addon.Capabilities
local array = addon.Utils.Array
local mini = addon.Core.Framework
local iconSlotContainer = addon.Core.IconSlotContainer
local unitWatcher = addon.Core.UnitAuraWatcher
local units = addon.Utils.Units
local ccUtil = addon.Utils.CcUtil
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local paused = false
local testModeActive = false
local previousTestSoundEnabled = false
local soundFile = "Interface\\AddOns\\" .. addonName .. "\\Media\\Sonar.ogg"

---@type Db
local db

---@type table
local healerAnchor

---@type IconSlotContainer
local iconsContainer

---@type table<string, HealerWatchEntry>
local activePool = {}
---@type table<string, HealerWatchEntry>
local discardPool = {}

local lastCcdAlpha
local eventsFrame

---@type TestSpell[]
local testSpells = {}

---@class HealerWatchEntry
---@field Unit string
---@field Watcher Watcher

---@class HealerCcModule : IModule
local M = {}
addon.Modules.HealerCcModule = M

local function PlaySound()
	PlaySoundFile(soundFile, db.Modules.HealerCcModule.Sound.Channel or "Master")
end

local function UpdateAnchorSize()
	if not healerAnchor then
		return
	end

	local options = db.Modules.HealerCcModule
	local iconSize = tonumber(options.Icons.Size) or 32
	local text = healerAnchor.HealerWarning
	local stringWidth = text and text:GetStringWidth() or 0
	local stringHeight = text and text:GetStringHeight() or 0
	local containerWidth = (iconsContainer and iconsContainer.Frame and iconsContainer.Frame:GetWidth()) or iconSize
	local width = math.max(iconSize, stringWidth, containerWidth)
	local height = iconSize + stringHeight

	healerAnchor:SetSize(width, height)
end

local function OnAuraStateUpdated()
	if paused then
		return
	end

	if not healerAnchor or not iconsContainer or not moduleUtil:IsModuleEnabled(ModuleName.HealerCC) then
		return
	end

	local options = db.Modules.HealerCcModule

	-- Cache config options for performance
	local hasNewFilters = capabilities:HasNewFilters()
	local iconsReverse = options.Icons.ReverseCooldown
	local iconsGlow = options.Icons.Glow
	local colorByDispelType = options.Icons.ColorByDispelType

	iconsContainer:ResetAllSlots()

	---@type AuraInfo[]
	local allCcAuraData = {}
	local slot = 0

	for _, watcher in pairs(activePool) do
		local ccState = watcher.Watcher:GetCcState()
		array:Append(ccState, allCcAuraData)

		if hasNewFilters then
			for _, aura in ipairs(ccState) do
				slot = slot + 1
				iconsContainer:SetSlotUsed(slot)
				iconsContainer:SetLayer(slot, 1, {
					Texture = aura.SpellIcon,
					StartTime = aura.StartTime,
					Duration = aura.TotalDuration,
					AlphaBoolean = aura.IsCC,
					ReverseCooldown = iconsReverse,
					Glow = iconsGlow,
					Color = colorByDispelType and aura.DispelColor,
				})
				iconsContainer:FinalizeSlot(slot, 1)
			end
		elseif #ccState > 0 then
			slot = slot + 1
			iconsContainer:SetSlotUsed(slot)

			local used = 0
			for _, aura in ipairs(ccState) do
				used = used + 1
				iconsContainer:SetLayer(slot, used, {
					Texture = aura.SpellIcon,
					StartTime = aura.StartTime,
					Duration = aura.TotalDuration,
					AlphaBoolean = aura.IsCC,
					ReverseCooldown = iconsReverse,
					Glow = iconsGlow,
					Color = colorByDispelType and aura.DispelColor,
				})
			end
			iconsContainer:FinalizeSlot(slot, used)
		end
	end

	local isCcdAlpha = ccUtil:IsCcAppliedAlpha(allCcAuraData)
	healerAnchor:SetAlpha(isCcdAlpha)

	if db.Modules.HealerCcModule.Sound.Enabled and not mini:IsSecret(isCcdAlpha) then
		if isCcdAlpha == 1 and lastCcdAlpha ~= isCcdAlpha then
			PlaySound()
		end
	end

	lastCcdAlpha = isCcdAlpha

	UpdateAnchorSize()
end

local function DisableAll()
	local toDiscard = {}
	for unit in pairs(activePool) do
		toDiscard[#toDiscard + 1] = unit
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		if item then
			item.Watcher:Disable()
			discardPool[unit] = item
			activePool[unit] = nil
		end
	end

	if iconsContainer then
		iconsContainer:ResetAllSlots()
	end

	if healerAnchor then
		healerAnchor:SetAlpha(0)
	end

	lastCcdAlpha = nil
end

local function RefreshHealers()
	-- Remove anyone who is no longer a healer.
	local toDiscard = {}
	for unit in pairs(activePool) do
		if not units:IsHealer(unit) then
			toDiscard[#toDiscard + 1] = unit
		end
	end

	for _, unit in ipairs(toDiscard) do
		local item = activePool[unit]
		if item then
			item.Watcher:Disable()
			discardPool[unit] = item
			activePool[unit] = nil
		end
	end

	local healers = units:FindHealers()

	for _, healer in ipairs(healers) do
		local item = activePool[healer]

		if not item then
			item = discardPool[healer]

			if item then
				item.Watcher:Enable()
				activePool[healer] = item
				discardPool[healer] = nil
			end
		end

		if not item then
			item = {
				Unit = healer,
				Watcher = unitWatcher:New(healer, nil, {
					CC = true,
				}),
			}

			item.Watcher:RegisterCallback(OnAuraStateUpdated)
			activePool[healer] = item
		end
	end

	OnAuraStateUpdated()
end

local function RefreshTestFrame()
	local options = db.Modules.HealerCcModule

	if not iconsContainer or not options then
		return
	end

	local size = tonumber(options.Icons.Size) or 32
	local now = GetTime()

	iconsContainer:ResetAllSlots()
	iconsContainer:SetIconSize(size)

	for i, spell in ipairs(testSpells) do
		local texture = spellCache:GetSpellTexture(spell.SpellId)

		if texture then
			local duration = 15 + (i - 1) * 3
			local startTime = now - (i - 1) * 0.5

			iconsContainer:SetSlotUsed(i)
			iconsContainer:SetLayer(i, 1, {
				Texture = texture,
				StartTime = startTime,
				Duration = duration,
				AlphaBoolean = true,
				ReverseCooldown = options.Icons.ReverseCooldown,
				Glow = options.Icons.Glow,
				Color = options.Icons.ColorByDispelType and spell.DispelColor,
			})
			iconsContainer:FinalizeSlot(i, 1)
		end
	end

	UpdateAnchorSize()
end

local function OnEvent(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		M:Refresh()
	end
end

local function Pause()
	paused = true
end

local function Resume()
	paused = false
	OnAuraStateUpdated()
end

function M:StartTesting()
	testModeActive = true
	Pause()
	M:Refresh()

	if not healerAnchor then
		return
	end

	healerAnchor:EnableMouse(true)
	healerAnchor:SetMovable(true)
	healerAnchor:SetAlpha(1)
end

function M:StopTesting()
	testModeActive = false
	Resume()

	if not healerAnchor then
		return
	end

	healerAnchor:EnableMouse(false)
	healerAnchor:SetMovable(false)
	healerAnchor:SetAlpha(0)
end

function M:Refresh()
	if not healerAnchor then
		return
	end

	local options = db.Modules.HealerCcModule
	local moduleEnabled = moduleUtil:IsModuleEnabled(ModuleName.HealerCC)

	healerAnchor:ClearAllPoints()
	healerAnchor:SetPoint(
		options.Point,
		_G[options.RelativeTo] or UIParent,
		options.RelativePoint,
		options.Offset.X,
		options.Offset.Y
	)

	healerAnchor.HealerWarning:SetFont(options.Font.File, options.Font.Size, options.Font.Flags)

	iconsContainer:SetIconSize(tonumber(options.Icons.Size) or 32)

	if testModeActive then
		if not moduleEnabled then
			healerAnchor:SetAlpha(0)
			return
		end

		healerAnchor:SetAlpha(1)
		RefreshTestFrame()

		if previousTestSoundEnabled ~= options.Sound.Enabled and options.Sound.Enabled then
			PlaySound()
		end

		previousTestSoundEnabled = options.Sound.Enabled
		return
	end

	if units:IsHealer("player") then
		DisableAll()
		return
	end

	if not moduleEnabled then
		DisableAll()
		return
	end

	RefreshHealers()
end

function M:Init()
	db = mini:GetSavedVars()

	previousTestSoundEnabled = db.Modules.HealerCcModule.Sound.Enabled

	-- Initialize test spells
	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	local multipleTestSpells = { kidneyShot, fear, hex }
	testSpells = capabilities:HasNewFilters() and multipleTestSpells or { kidneyShot }

	local options = db.Modules.HealerCcModule

	healerAnchor = CreateFrame("Frame", addonName .. "HealerContainer")
	healerAnchor:EnableMouse(false)
	healerAnchor:SetMovable(false)
	healerAnchor:SetAlpha(0)
	healerAnchor:RegisterForDrag("LeftButton")
	healerAnchor:SetIgnoreParentScale(true)
	healerAnchor:SetScript("OnDragStart", function(anchorSelf)
		anchorSelf:StartMoving()
	end)
	healerAnchor:SetScript("OnDragStop", function(anchorSelf)
		anchorSelf:StopMovingOrSizing()

		local point, relativeTo, relativePoint, x, y = anchorSelf:GetPoint()
		db.Modules.HealerCcModule.Point = point
		db.Modules.HealerCcModule.RelativePoint = relativePoint
		db.Modules.HealerCcModule.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
		db.Modules.HealerCcModule.Offset.X = x
		db.Modules.HealerCcModule.Offset.Y = y
	end)

	local text = healerAnchor:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	text:SetPoint("TOP", healerAnchor, "TOP", 0, 6)
	text:SetFont(options.Font.File, options.Font.Size, options.Font.Flags)
	text:SetText("Healer in CC!")
	text:SetTextColor(1, 0.1, 0.1)
	text:SetShadowColor(0, 0, 0, 1)
	text:SetShadowOffset(1, -1)
	text:Show()

	healerAnchor.HealerWarning = text

	-- Icons sit at the bottom of the anchor, text sits at the top.
	iconsContainer = iconSlotContainer:New(healerAnchor, 5, tonumber(options.Icons.Size) or 32, 2)
	iconsContainer.Frame:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
	iconsContainer.Frame:Show()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

	M:Refresh()
end
