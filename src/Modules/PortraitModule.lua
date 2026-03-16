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
	-- Only 1 slot, multiple layers; no border for portrait icons
	local container = iconSlotContainer:New(unitFrame, 1, 0, 0, nil, true)

	-- Position the container over the portrait with inset
	container.Frame:SetPoint("TOPLEFT", portrait, "TOPLEFT", 2, -2)
	container.Frame:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -2, 2)
	container.Frame:SetFrameLevel(math.max(0, (unitFrame:GetFrameLevel() or 0) - 1))

	-- inherit scale from portrait so icons scale with it
	container.Frame:SetIgnoreParentScale(false)

	-- in case something hides the portrait by setting alpha to 0
	container.Frame:SetIgnoreParentAlpha(false)

	-- Set initial size to match portrait
	local width = portrait:GetWidth() - 4
	local height = portrait:GetHeight() - 4
	local size = math.min(width, height)

	if size <= 0 then
		size = 32
	end

	container:SetIconSize(size)

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
	for _, aura in ipairs(ccAuras) do
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			StartTime = aura.StartTime,
			Duration = aura.TotalDuration,
			Alpha = aura.IsCC,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- Show the latest defensive aura
	for _, aura in ipairs(defensiveAuras) do
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			StartTime = aura.StartTime,
			Duration = aura.TotalDuration,
			Alpha = aura.IsDefensive,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- Show the latest important aura
	for _, aura in ipairs(importantAuras) do
		container:SetSlot(slotIndex, {
			Texture = aura.SpellIcon,
			StartTime = aura.StartTime,
			Duration = aura.TotalDuration,
			Alpha = aura.IsImportant,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
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

---@return table? unitFrame
---@return table? portrait
local function GetTPerlFrame(unit)
	if unit == "player" then
		if TPerl_PlayerportraitFrame then
			return TPerl_PlayerportraitFrame, TPerl_PlayerportraitFrame
		end
	elseif unit == "target" then
		if TPerl_TargetportraitFrame then
			return TPerl_TargetportraitFrame, TPerl_TargetportraitFrame
		end
	elseif unit == "focus" then
		if TPerl_FocusportraitFrame then
			return TPerl_FocusportraitFrame, TPerl_FocusportraitFrame
		end
	end

	return nil
end

---@return table? unitFrame
---@return table? portrait
local function GetElvUIFrame(unit)
	if unit == "player" then
		if ElvUF_Player and ElvUF_Player.Portrait then
			return ElvUF_Player, ElvUF_Player.Portrait
		end
	elseif unit == "target" then
		if ElvUF_Target and ElvUF_Target.Portrait then
			return ElvUF_Target, ElvUF_Target.Portrait
		end
	elseif unit == "focus" then
		if ElvUF_Focus and ElvUF_Focus.Portrait then
			return ElvUF_Focus, ElvUF_Focus.Portrait
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
		return
	end

	local watcher = unitWatcher:New(unit, events, nil, nil, Enum.UnitAuraSortDirection.Reverse)
	watchers[unit] = watcher

	local container = CreateContainer(unitFrame, portrait)

	if unit == "pet" then
		container.Frame:SetFrameLevel(math.max(0, (PetFrame:GetFrameLevel() or 0) - 2))
	end

	local mask = GetPortraitMask(unitFrame) or CreatePortraitMask(portrait)

	if mask then
		local originalSetSlot = container.SetSlot
		container.SetSlot = function(self, slotIndex, options)
			originalSetSlot(self, slotIndex, options)
			local slot = self.Slots[slotIndex]
			if slot and slot.Container then
				ApplyMaskToLayer(slot.Container, mask)
			end
		end
	end

	watcher:RegisterCallback(function()
		OnAuraInfo(watcher, container)
	end)
	portrait:SetDrawLayer("BACKGROUND", 0)
	containers[#containers + 1] = container
end

---@param unit string
local function AttachElvUIFrame(unit)
	local elvuiFrame, elvuiPortrait = GetElvUIFrame(unit)

	if not elvuiFrame or not elvuiPortrait then
		return
	end

	local watcher = watchers[unit]

	if not watcher then
		return
	end

	local container = CreateContainer(elvuiFrame, elvuiPortrait)
	-- 3d models are a frame, where as 2d portraits are textures which don't have a frame level
	-- so for 2d textures we get the frame level from the parent frame, for 3d portraits we get it directly from the portrait frame
	local portraitLevel = elvuiPortrait.GetFrameLevel and elvuiPortrait:GetFrameLevel()
		or elvuiFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel)

	local originalSetSlot = container.SetSlot
	container.SetSlot = function(self, slotIndex, options)
		originalSetSlot(self, slotIndex, options)
		local slot = self.Slots[slotIndex]
		if slot and slot.Container and slot.Container.Icon and slot.Container.Cooldown then
			slot.Container.Icon:SetAllPoints(elvuiPortrait)
			-- get rid of the border
			slot.Container.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			slot.Container.Cooldown:SetAllPoints(elvuiPortrait)
		end
	end

	watcher:RegisterCallback(function()
		OnAuraInfo(watcher, container)
	end)
	containers[#containers + 1] = container
end

---@param unit string
local function AttachTPerlFrame(unit)
	local tperlFrame, tperlPortrait = GetTPerlFrame(unit)

	if not tperlFrame or not tperlPortrait then
		return
	end

	local watcher = watchers[unit]

	if not watcher then
		return
	end

	local container = CreateContainer(tperlFrame, tperlPortrait)
	local portraitLevel = tperlPortrait.GetFrameLevel and tperlPortrait:GetFrameLevel()
		or tperlFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel)

	watcher:RegisterCallback(function()
		OnAuraInfo(watcher, container)
	end)
	containers[#containers + 1] = container
end

local function RefreshTestIcons()
	local tex = spellCache:GetSpellTexture(testSpells[1].SpellId)
	local now = GetTime()

	for _, container in pairs(containers) do
		container:SetSlot(1, {
			Texture = tex,
			StartTime = now,
			Duration = 15, -- 15 second duration for test
			Alpha = true,
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
end

local function EnableWatchers()
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

	M:Refresh()
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

	-- defer attaching to ElvUI frames until they are created
	local eventsFrame = CreateFrame("Frame")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:SetScript("OnEvent", function()
		eventsFrame:UnregisterEvent("PLAYER_ENTERING_WORLD")
		AttachElvUIFrame("player")
		AttachElvUIFrame("target")
		AttachElvUIFrame("focus")
		AttachTPerlFrame("player")
		AttachTPerlFrame("target")
		AttachTPerlFrame("focus")
	end)

	M:Refresh()
end
