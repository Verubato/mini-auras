---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local unitWatcher = addon.Core.UnitAuraWatcher
local kickTracker = addon.Core.KickTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local units = addon.Utils.Units
local testModeActive = false
local paused = false
local enabled = false
local containers = {}
---@type { string: Watcher }
local watchers = {}
-- Callbacks to re-render each container attached to "target"; populated by Attach/Attach* calls.
local unitUpdateFns = {} -- unit → array of update fns; populated per framework Attach call
---@type Db
local db
---@type TestSpell[]
local testSpells = {}

-- Important buffs are read from Blizzard's nameplate buff lists (like the nameplates/alerts
-- modules), so a portrait can surface its unit's important spell (e.g. offensive cooldown, precog).
local hookedAuraFrames = {}
local pendingImportantUnits = {}
local importantUpdateScheduled = false

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
	local container = iconSlotContainer:New(unitFrame, 1, 0, 0, nil, true, "Portraits")

	-- Position the container over the portrait with inset
	container.Frame:SetPoint("TOPLEFT", portrait, "TOPLEFT", 2, -2)
	container.Frame:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", -2, 2)
	container.Frame:SetFrameLevel(math.max(0, (unitFrame:GetFrameLevel() or 0) - 1))

	-- match the frame strata of the portrait parent
	-- some addons like ClassicFrames adjust this from LOW to MEDIUM
	-- so we want to follow it to ensure the icons are visible
	container.Frame:SetFrameStrata(portrait:GetParent():GetFrameStrata())

	-- inherit scale from portrait so icons scale with it
	container.Frame:SetIgnoreParentScale(false)

	-- Portrait icons do not fade with the parent unit frame (e.g. out of range);
	-- ignore the parent's alpha so they stay fully opaque.
	container.Frame:SetIgnoreParentAlpha(true)

	-- Skip attachment if the portrait dimensions are secret (tainted frame)
	-- seems to happen with ElvUI when their portraits are disabled
	local w = portrait:GetWidth()
	local h = portrait:GetHeight()
	if issecretvalue(w) or issecretvalue(h) then return nil end

	local size = math.min(w - 4, h - 4)
	if size <= 0 then size = 32 end

	container:SetIconSize(size)

	return container
end

-- Returns the aura data for the unit's first important nameplate buff, or nil. These come from
-- Blizzard's own nameplate buff list, so the unit needs a visible nameplate (e.g. an enemy target
-- in range); the player's own portrait only shows one if self-nameplates are enabled. Friendly
-- nameplate buff lists aren't pre-curated to the important ones, so for friendly units an extra
-- nameplate aura filter drops the non-important junk.
local function GetFirstImportantBuff(unit)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unit)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if not (af and af.buffList and af.buffList.Iterate and not (af.IsForbidden and af:IsForbidden())) then
		return nil
	end

	local friendlyFilter = units:IsFriend(unit)
		and "HELPFUL|INCLUDE_NAME_PLATE_ONLY|RAID_IN_COMBAT|PLAYER"
		or nil

	local firstId
	af.buffList:Iterate(function(auraInstanceID)
		if firstId ~= nil then
			return
		end
		if friendlyFilter and C_UnitAuras.IsAuraFilteredOutByInstanceID(unit, auraInstanceID, friendlyFilter) then
			return
		end
		firstId = auraInstanceID
	end)

	if not firstId then
		return nil
	end
	return C_UnitAuras.GetAuraDataByAuraInstanceID(unit, firstId)
end

---@param unit string
---@param watcher Watcher
---@param container IconSlotContainer
local function OnAuraInfo(unit, watcher, container)
	if not enabled or paused then
		return
	end

	local kickEntry = kickTracker:GetKick(unit)
	if kickEntry then
		container:SetSlot(1, {
			Texture = kickEntry.Texture,
			DurationObject = kickEntry.DurationObject,
			Alpha = true,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
			Color = kickEntry.Color,
		})
		return
	end

	local ccAuras = watcher:GetCcState()
	local defensiveAuras = watcher:GetDefensiveState()
	local slotIndex = 1

	-- Show the latest CC aura
	if ccAuras[1] then
		container:SetSlot(slotIndex, {
			Texture = ccAuras[1].SpellIcon,
			DurationObject = ccAuras[1].DurationObject,
			Alpha = ccAuras[1].IsCC,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- Show the latest defensive aura
	if defensiveAuras[1] then
		container:SetSlot(slotIndex, {
			Texture = defensiveAuras[1].SpellIcon,
			DurationObject = defensiveAuras[1].DurationObject,
			Alpha = defensiveAuras[1].IsDefensive,
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- Show the latest important buff (read from Blizzard's nameplate buff list; lowest priority)
	local importantAura = GetFirstImportantBuff(unit)
	if importantAura then
		container:SetSlot(slotIndex, {
			Texture = importantAura.icon,
			DurationObject = C_UnitAuras.GetAuraDuration(unit, importantAura.auraInstanceID),
			Alpha = true,
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
local function GetUUFFrame(unit)
	if unit == "player" then
		if UUF_Player and UUF_Player.Portrait then
			return UUF_Player, UUF_Player.Portrait
		end
	elseif unit == "target" then
		if UUF_Target and UUF_Target.Portrait then
			return UUF_Target, UUF_Target.Portrait
		end
	elseif unit == "focus" then
		if UUF_Focus and UUF_Focus.Portrait then
			return UUF_Focus, UUF_Focus.Portrait
		end
	elseif unit == "pet" then
		if UUF_Pet and UUF_Pet.Portrait then
			return UUF_Pet, UUF_Pet.Portrait
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

---@param unit string
---@return table? unitFrame
---@return table? portrait
local function GetMSUFFrame(unit)
	local registry = _G.MSUF_UnitFrames
	if type(registry) ~= "table" then
		return nil, nil
	end

	local frame = registry[unit]
	if not frame then
		return nil, nil
	end

	if frame.IsForbidden and frame:IsForbidden() then
		return nil, nil
	end

	-- Prefer 3D model when active, fall back to 2D portrait texture
	local portrait = rawget(frame, "portraitModel") or frame.portrait

	return frame, portrait
end

---@param unit string
---@return table? unitFrame
---@return table? portrait
local function GetEllesmereUIFrame(unit)
	local frame
	if unit == "player" then
		frame = _G["EllesmereUIUnitFrames_Player"]
	elseif unit == "target" then
		frame = _G["EllesmereUIUnitFrames_Target"]
	elseif unit == "focus" then
		frame = _G["EllesmereUIUnitFrames_Focus"]
	elseif unit == "pet" then
		frame = _G["EllesmereUIUnitFrames_Pet"]
	end

	if not frame or (frame.IsForbidden and frame:IsForbidden()) then
		return nil, nil
	end

	-- frame.Portrait is the active visual (2D texture / 3D PlayerModel / class icon),
	-- and frame.Portrait.backdrop is the parent Frame that owns the slot. Anchor to the
	-- backdrop since it's always a Frame with stable dimensions across portrait modes.
	local portrait = frame.Portrait and frame.Portrait.backdrop
	if not portrait then
		return nil, nil
	end

	return frame, portrait
end

---@param unit string
---@return table? unitFrame
---@return table? portrait
local function GetEQolFrame(unit)
	local frame
	if unit == "player" then
		frame = _G.EQOLUFPlayerFrame
	elseif unit == "target" then
		frame = _G.EQOLUFTargetFrame
	elseif unit == "focus" then
		frame = _G.EQOLUFFocusFrame
	elseif unit == "pet" then
		frame = _G.EQOLUFPetFrame
	end

	if not frame or (frame.IsForbidden and frame:IsForbidden()) then
		return nil, nil
	end

	local portrait = frame.portraitHolder or frame.portrait
	if not portrait then
		return nil, nil
	end

	return frame, portrait
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
	if not container then return end

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
		OnAuraInfo(unit, watcher, container)
	end)
	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			OnAuraInfo(unit, watcher, container)
		end
	end
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
	if not container then return end
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
		OnAuraInfo(unit, watcher, container)
	end)
	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			OnAuraInfo(unit, watcher, container)
		end
	end
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
	if not container then return end
	local portraitLevel = tperlPortrait.GetFrameLevel and tperlPortrait:GetFrameLevel()
		or tperlFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel)

	watcher:RegisterCallback(function()
		OnAuraInfo(unit, watcher, container)
	end)
	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			OnAuraInfo(unit, watcher, container)
		end
	end
	containers[#containers + 1] = container
end

---@param unit string
local function AttachUUFFrame(unit)
	local uufFrame, uufPortrait = GetUUFFrame(unit)

	if not uufFrame or not uufPortrait then
		return
	end

	local watcher = watchers[unit]

	if not watcher then
		return
	end

	-- Parent to HighLevelContainer (portrait's parent) so frame levels are consistent.
	-- UUF renders portraits inside HighLevelContainer at level 999, so parenting to
	-- uufFrame directly would leave the container far below in the level hierarchy.
	local highLevelContainer = uufPortrait:GetParent()
	local container = CreateContainer(highLevelContainer, uufPortrait)
	if not container then return end
	local portraitLevel = uufPortrait.GetFrameLevel and uufPortrait:GetFrameLevel()
		or highLevelContainer:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 1)

	local originalSetSlot = container.SetSlot
	container.SetSlot = function(self, slotIndex, options)
		originalSetSlot(self, slotIndex, options)
		local slot = self.Slots[slotIndex]
		if slot and slot.Container and slot.Container.Icon and slot.Container.Cooldown then
			slot.Frame:SetAllPoints(uufPortrait)
			slot.Container.Frame:SetAllPoints(uufPortrait)
			slot.Container.Icon:SetAllPoints(uufPortrait)
			slot.Container.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			slot.Container.Cooldown:SetAllPoints(uufPortrait)
		end
	end

	watcher:RegisterCallback(function()
		OnAuraInfo(unit, watcher, container)
	end)
	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			OnAuraInfo(unit, watcher, container)
		end
	end
	containers[#containers + 1] = container
end

---@param unit string
local function AttachMSUFFrame(unit)
	local msufFrame, msufPortrait = GetMSUFFrame(unit)

	if not msufFrame or not msufPortrait then
		return
	end

	local watcher = watchers[unit]

	if not watcher then
		return
	end

	local container = CreateContainer(msufFrame, msufPortrait)
	if not container then return end
	local portraitLevel = msufPortrait.GetFrameLevel and msufPortrait:GetFrameLevel()
		or msufFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 10)

	local originalSetSlot = container.SetSlot
	container.SetSlot = function(self, slotIndex, options)
		originalSetSlot(self, slotIndex, options)
		local slot = self.Slots[slotIndex]
		if slot and slot.Container and slot.Container.Icon and slot.Container.Cooldown then
			slot.Frame:SetAllPoints(msufPortrait)
			slot.Container.Frame:SetAllPoints(msufPortrait)
			slot.Container.Icon:SetAllPoints(msufPortrait)
			slot.Container.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			slot.Container.Cooldown:SetAllPoints(msufPortrait)
		end
	end

	watcher:RegisterCallback(function()
		OnAuraInfo(unit, watcher, container)
	end)
	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			OnAuraInfo(unit, watcher, container)
		end
	end
	containers[#containers + 1] = container
end

---@param unit string
local function AttachEllesmereUIFrame(unit)
	local euiFrame, euiPortrait = GetEllesmereUIFrame(unit)

	if not euiFrame or not euiPortrait then
		return
	end

	local watcher = watchers[unit]

	if not watcher then
		return
	end

	local container = CreateContainer(euiFrame, euiPortrait)
	if not container then return end
	local portraitLevel = euiPortrait.GetFrameLevel and euiPortrait:GetFrameLevel()
		or euiFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 10)

	-- EllesmereUI insets its portrait texture with SetTexCoord(0.15, 0.85). Match that on our
	-- overlay so the CC icon visually fills the same area as the portrait beneath it.
	local originalSetSlot = container.SetSlot
	container.SetSlot = function(self, slotIndex, options)
		originalSetSlot(self, slotIndex, options)
		local slot = self.Slots[slotIndex]
		if slot and slot.Container and slot.Container.Icon and slot.Container.Cooldown then
			slot.Frame:SetAllPoints(euiPortrait)
			slot.Container.Frame:SetAllPoints(euiPortrait)
			slot.Container.Icon:SetAllPoints(euiPortrait)
			slot.Container.Icon:SetTexCoord(0.15, 0.85, 0.15, 0.85)
			slot.Container.Cooldown:SetAllPoints(euiPortrait)
		end
	end

	watcher:RegisterCallback(function()
		OnAuraInfo(unit, watcher, container)
	end)
	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			OnAuraInfo(unit, watcher, container)
		end
	end
	containers[#containers + 1] = container
end

---@param unit string
local function AttachEQolFrame(unit)
	local eqolFrame, eqolPortrait = GetEQolFrame(unit)

	if not eqolFrame or not eqolPortrait then
		return
	end

	local watcher = watchers[unit]

	if not watcher then
		return
	end

	local container = CreateContainer(eqolFrame, eqolPortrait)
	if not container then return end
	local portraitLevel = eqolPortrait.GetFrameLevel and eqolPortrait:GetFrameLevel()
		or eqolFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 10)

	local originalSetSlot = container.SetSlot
	container.SetSlot = function(self, slotIndex, options)
		originalSetSlot(self, slotIndex, options)
		local slot = self.Slots[slotIndex]
		if slot and slot.Container and slot.Container.Icon and slot.Container.Cooldown then
			slot.Frame:SetAllPoints(eqolPortrait)
			slot.Container.Frame:SetAllPoints(eqolPortrait)
			slot.Container.Icon:SetAllPoints(eqolPortrait)
			slot.Container.Icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
			slot.Container.Cooldown:SetAllPoints(eqolPortrait)
		end
	end

	watcher:RegisterCallback(function()
		OnAuraInfo(unit, watcher, container)
	end)
	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			OnAuraInfo(unit, watcher, container)
		end
	end
	containers[#containers + 1] = container
end

local function RefreshTestIcons()
	local spellId = testSpells[1].SpellId
	local tex = C_Spell.GetSpellTexture(spellId)
	local now = GetTime()

	for _, container in pairs(containers) do
		container:SetSlot(1, {
			Texture = tex,
			DurationObject = wowEx:CreateDuration(now, 15),
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

local function GetCCSortOptions()
	if db.CCNativeOrder then
		return Enum.UnitAuraSortRule.Default, Enum.UnitAuraSortDirection.Normal
	end
	return Enum.UnitAuraSortRule.Unsorted, Enum.UnitAuraSortDirection.Reverse
end

function M:Refresh()
	enabled = moduleUtil:IsModuleEnabled(ModuleName.Portrait)

	-- If disabled, disable watchers and clear
	if not enabled then
		DisableWatchers()
		return
	end

	-- Module is enabled, ensure watchers are enabled
	EnableWatchers()

	local sortRule, sortDirection = GetCCSortOptions()
	for _, watcher in pairs(watchers) do
		watcher:SetSort(sortRule, sortDirection)
	end

	if testModeActive then
		RefreshTestIcons()
	end
end

local function FlushImportantUpdates()
	importantUpdateScheduled = false
	for unit in pairs(pendingImportantUnits) do
		pendingImportantUnits[unit] = nil
		local fns = unitUpdateFns[unit]
		if fns then
			for _, fn in ipairs(fns) do
				fn()
			end
		end
	end
end

-- Debounced: coalesces nameplate RefreshAuras bursts into one portrait update per unit per frame.
local function ScheduleImportantUpdate(unit)
	pendingImportantUnits[unit] = true
	if importantUpdateScheduled then
		return
	end
	importantUpdateScheduled = true
	C_Timer.After(0, FlushImportantUpdates)
end

-- Hooks a nameplate's RefreshAuras so the target/focus portrait re-renders when that unit's
-- important buffs change. Watchers only track CC + defensives, so this is the only buff-change
-- signal. The hook is a cheap no-op when the module is off or the nameplate isn't target/focus.
local function HookNameplateAuraFrame(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.RefreshAuras and not hookedAuraFrames[af] then
		hookedAuraFrames[af] = true
		hooksecurefunc(af, "RefreshAuras", function(self)
			if not enabled or paused then
				return
			end
			if self.IsForbidden and self:IsForbidden() then
				return
			end
			local parent = self:GetParent()
			local u = parent and parent.unit
			if not u then
				return
			end
			if units:SameUnit(u, "target") then
				ScheduleImportantUpdate("target")
			end
			if units:SameUnit(u, "focus") then
				ScheduleImportantUpdate("focus")
			end
		end)
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
		AttachUUFFrame("player")
		AttachUUFFrame("target")
		AttachUUFFrame("focus")
		AttachUUFFrame("pet")
		AttachMSUFFrame("player")
		AttachMSUFFrame("target")
		AttachMSUFFrame("focus")
		AttachMSUFFrame("pet")
		AttachEllesmereUIFrame("player")
		AttachEllesmereUIFrame("target")
		AttachEllesmereUIFrame("focus")
		AttachEllesmereUIFrame("pet")
		AttachEQolFrame("player")
		AttachEQolFrame("target")
		AttachEQolFrame("focus")
		AttachEQolFrame("pet")
	end)

	-- Hook each nameplate's aura refresh so important buffs on the target/focus update live.
	local nameplateEvents = CreateFrame("Frame")
	nameplateEvents:RegisterEvent("NAME_PLATE_UNIT_ADDED")
	nameplateEvents:SetScript("OnEvent", function(_, _, unitToken)
		HookNameplateAuraFrame(unitToken)
	end)

	kickTracker:Watch("target", { "PLAYER_TARGET_CHANGED" })
	kickTracker:Subscribe("target", function()
		local fns = unitUpdateFns["target"]
		if fns then
			for _, fn in ipairs(fns) do fn() end
		end
	end)
	kickTracker:Watch("focus", { "PLAYER_FOCUS_CHANGED" })
	kickTracker:Subscribe("focus", function()
		local fns = unitUpdateFns["focus"]
		if fns then
			for _, fn in ipairs(fns) do fn() end
		end
	end)

	M:Refresh()
end
