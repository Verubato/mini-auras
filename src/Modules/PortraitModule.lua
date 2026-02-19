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
local enabled = false
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
	-- the icon slot container starts at +2
	container.Frame:SetFrameLevel(math.max(0, (unitFrame:GetFrameLevel() or 0) - 1))

	-- Set initial size to match portrait
	local width = portrait:GetWidth() - 4
	local height = portrait:GetHeight() - 4
	local size = math.min(width, height)
	container:SetIconSize(size)

	local mask = GetPortraitMask(unitFrame) or CreatePortraitMask(portrait)

	-- Hook SetLayer to apply mask when layers are created
	local originalSetLayer = container.SetLayer
	container.SetLayer = function(self, slotIndex, layerIndex, options)
		-- Call original SetLayer first
		originalSetLayer(self, slotIndex, layerIndex, options)

		-- Apply mask to the layer that was just created/updated
		local slot = self.Slots[slotIndex]
		if slot and slot.Layers[layerIndex] then
			ApplyMaskToLayer(slot.Layers[layerIndex], mask)
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

	container:ResetAllSlots()

	local ccAuras = watcher:GetCcState()
	local importantAuras = watcher:GetImportantState()
	local defensiveAuras = watcher:GetDefensiveState()

	local slotIndex = 1
	local layerIndex = 1

	-- Process CC auras, iterate in reverse to show latest spells
	for i = #ccAuras, 1, -1 do
		local aura = ccAuras[i]
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			container:SetSlotUsed(slotIndex)
			container:SetLayer(slotIndex, layerIndex, {
				Texture = aura.SpellIcon,
				StartTime = aura.StartTime,
				Duration = aura.TotalDuration,
				AlphaBoolean = aura.IsCC,
				Glow = false,
				ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
				FontScale = db.FontScale,
			})

			if not issecretvalue(aura.IsCC) then
				-- we're in 12.0.1
				if aura.IsCC then
					container:FinalizeSlot(slotIndex, layerIndex)
					return
				end
			end

			layerIndex = layerIndex + 1
		end
	end

	-- Process defensive auras, iterate in reverse to show latest spells
	for i = #defensiveAuras, 1, -1 do
		local aura = defensiveAuras[i]
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			container:SetSlotUsed(slotIndex)
			container:SetLayer(slotIndex, layerIndex, {
				Texture = aura.SpellIcon,
				StartTime = aura.StartTime,
				Duration = aura.TotalDuration,
				AlphaBoolean = true, -- we only get defensives in 12.0.1
				Glow = false,
				ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
				FontScale = db.FontScale,
			})

			container:FinalizeSlot(slotIndex, layerIndex)
			return
		end
	end

	-- Process important auras, iterate in reverse to show latest spells
	for i = #importantAuras, 1, -1 do
		local aura = importantAuras[i]
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			container:SetSlotUsed(slotIndex)
			container:SetLayer(slotIndex, layerIndex, {
				Texture = aura.SpellIcon,
				StartTime = aura.StartTime,
				Duration = aura.TotalDuration,
				AlphaBoolean = aura.IsImportant,
				Glow = false,
				ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
				FontScale = db.FontScale,
			})

			layerIndex = layerIndex + 1
		end
	end

	container:FinalizeSlot(slotIndex, layerIndex - 1)
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

	return container
end

local function RefreshTestIcons()
	local tex = spellCache:GetSpellTexture(testSpells[1].SpellId)
	local now = GetTime()

	for _, container in pairs(containers) do
		container:SetSlotUsed(1)
		container:SetLayer(1, 1, {
			Texture = tex,
			StartTime = now,
			Duration = 15, -- 15 second duration for test
			AlphaBoolean = true,
			Glow = false,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		container:FinalizeSlot(1, 1)
	end
end

local function ClearAll()
	for _, container in pairs(containers) do
		container:ResetAllSlots()
	end
end

local function EnableDisable()
	if moduleUtil:IsModuleEnabled(ModuleName.Portrait) then
		for _, watcher in pairs(watchers) do
			watcher:Enable()
		end

		enabled = true
	else
		for _, watcher in pairs(watchers) do
			watcher:Disable()
			watcher:ClearState(true)
		end

		enabled = false
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
	ClearAll()
end

function M:Refresh()
	EnableDisable()

	if not enabled then
		ClearAll()
		return
	end

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
