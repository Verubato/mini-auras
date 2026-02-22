---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local unitWatcher = addon.Core.UnitAuraWatcher
local iconSlotContainer = addon.Core.IconSlotContainer
local spellCache = addon.Utils.SpellCache
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local testModeActive = false
local paused = false
local containers = {}
---@type { string: Watcher }
local watchers = {}
---@type Db
local db
---@type TestSpell[]
local testSpells = {}

---@class PortraitModule : IModule
local M = {}
addon.Modules.PortraitModule = M

local function AddMask(tex, mask)
	tex:AddMaskTexture(mask)
end

local function GetPortraitMask(unitFrame)
	-- player
	if unitFrame.PlayerFrameContainer and unitFrame.PlayerFrameContainer.PlayerPortraitMask then
		return unitFrame.PlayerFrameContainer.PlayerPortraitMask
	end

	-- target/focus
	if unitFrame.TargetFrameContainer and unitFrame.TargetFrameContainer.PortraitMask then
		return unitFrame.TargetFrameContainer.PortraitMask
	end

	-- target of target and pet frame
	if unitFrame.PortraitMask then
		return unitFrame.PortraitMask
	end

	return nil
end

local function CreatePortraitMask(portrait)
	local parent = portrait:GetParent()
	if not parent then
		return nil
	end

	local mask = parent:CreateMaskTexture()
	mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(portrait)
	return mask
end

local function ApplyMaskToLayer(layer, mask)
	if not layer then
		return
	end

	if layer.Icon then
		if mask then
			AddMask(layer.Icon, mask)
		end
		-- Crop the icon like Blizzard does
		layer.Icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
	end

	if layer.Cooldown then
		-- Keep cooldown within the portrait icon
		layer.Cooldown:SetSwipeTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
	end
end

local function CreateContainer(unitFrame, portrait)
	-- Only 1 slot, multiple layers
	local container = iconSlotContainer:New(unitFrame, 1, 0, 0)

	-- Position the container over the portrait with inset
	container.Frame:SetPoint("TOPLEFT", portrait, "TOPLEFT", 2, -2)
	container.Frame:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -2, 2)
	container.Frame:SetFrameLevel(math.max(0, (unitFrame:GetFrameLevel() or 0)))

	-- Set initial size to match portrait
	local width = portrait:GetWidth() - 4
	local height = portrait:GetHeight() - 4
	local size = math.min(width, height)
	container:SetIconSize(size)

	local mask = GetPortraitMask(unitFrame) or CreatePortraitMask(portrait)

	-- Hook SetSlot to apply mask when the layer is created
	local originalSetSlot = container.SetSlot
	container.SetSlot = function(self, slotIndex, options)
		originalSetSlot(self, slotIndex, options)

		local slot = self.Slots[slotIndex]
		if slot and slot.Container then
			ApplyMaskToLayer(slot.Container, mask)
		end
	end

	return container
end

---@param watcher Watcher
---@param container IconSlotContainer
local function OnAuraInfo(watcher, container)
	if paused then
		return
	end

	local ccAuras = watcher:GetCcState()
	local importantAuras = watcher:GetImportantState()
	local defensiveAuras = watcher:GetDefensiveState()
	local slotIndex = 1

	-- Show the latest CC aura
	for i = #ccAuras, 1, -1 do
		local aura = ccAuras[i]
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			container:SetSlot(slotIndex, {
				Texture = aura.SpellIcon,
				StartTime = aura.StartTime,
				Duration = aura.TotalDuration,
				AlphaBoolean = aura.IsCC,
				ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
				FontScale = db.FontScale,
			})
			return
		end
	end

	-- Show the latest defensive aura
	for i = #defensiveAuras, 1, -1 do
		local aura = defensiveAuras[i]
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			container:SetSlot(slotIndex, {
				Texture = aura.SpellIcon,
				StartTime = aura.StartTime,
				Duration = aura.TotalDuration,
				AlphaBoolean = aura.IsDefensive,
				ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
				FontScale = db.FontScale,
			})
			return
		end
	end

	-- Show the latest important aura
	for i = #importantAuras, 1, -1 do
		local aura = importantAuras[i]
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			container:SetSlot(slotIndex, {
				Texture = aura.SpellIcon,
				StartTime = aura.StartTime,
				Duration = aura.TotalDuration,
				AlphaBoolean = aura.IsImportant,
				ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
				FontScale = db.FontScale,
			})
			return
		end
	end

	-- No auras to display, clear the slot if it was used
	container:SetSlotUnused(slotIndex)
end

---@return table? unitFrame
---@return table? portrait
local function GetBlizzardFrame(unit)
	if unit == "player" then
		if PlayerFrame and PlayerFrame.portrait then
			return PlayerFrame, PlayerFrame.portrait
		end
	elseif unit == "target" then
		if TargetFrame and TargetFrame.portrait then
			return TargetFrame, TargetFrame.portrait
		end
	elseif unit == "focus" then
		if FocusFrame and FocusFrame.portrait then
			return FocusFrame, FocusFrame.portrait
		end
	elseif unit == "pet" then
		if PetFrame and PetFrame.portrait then
			return PetFrame, PetFrame.portrait
		end
	end

	return nil
end

---@return IconSlotContainer[]
function M:GetContainers()
	local result = {}
	for _, container in pairs(containers) do
		result[#result + 1] = container
	end
	return result
end

---@param unit string
---@param events string[]?
local function Attach(unit, events)
	local unitFrame, portrait = GetBlizzardFrame(unit)

	if not unitFrame or not portrait then
		return nil
	end

	local container = CreateContainer(unitFrame, portrait)
	local watcher = unitWatcher:New(unit, events)

	watcher:RegisterCallback(function()
		OnAuraInfo(watcher, container)
	end)

	containers[unit] = container
	---@diagnostic disable-next-line: unused-local
	watchers[unit] = watcher

	-- lower the draw layer by 1 so our icons show ahead
	portrait:SetDrawLayer("BACKGROUND", 0)

	return container
end

local function RefreshTestIcons()
	local tex = spellCache:GetSpellTexture(testSpells[1].SpellId)
	local now = GetTime()

	for _, container in pairs(containers) do
		container:SetSlot(1, {
			Texture = tex,
			StartTime = now,
			Duration = 15, -- 15 second duration for test
			AlphaBoolean = true,
			Glow = false,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
	end
end

local function DisableWatchers()
	for _, watcher in pairs(watchers) do
		watcher:Disable()
		watcher:ClearState(true)
	end

	for _, container in pairs(containers) do
		container:ResetAllSlots()
	end

	paused = true
end

local function EnableWatchers()
	paused = false
	for _, watcher in pairs(watchers) do
		watcher:Enable()
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
	Resume()

	for _, container in pairs(containers) do
		container:ResetAllSlots()
	end
end

function M:Refresh()
	local moduleEnabled = moduleUtil:IsModuleEnabled(ModuleName.Portrait)

	-- If disabled, disable watchers and clear
	if not moduleEnabled then
		DisableWatchers()
		return
	end

	-- Module is enabled, ensure watchers are enabled
	EnableWatchers()

	if testModeActive then
		RefreshTestIcons()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	-- Initialize test spells
	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	testSpells = { kidneyShot }

	Attach("player")
	Attach("target", { "PLAYER_TARGET_CHANGED" })
	Attach("focus", { "PLAYER_FOCUS_CHANGED" })
	Attach("pet")

	M:Refresh()
end
