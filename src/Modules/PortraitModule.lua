---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local wowEx = addon.Utils.WoWEx
local unitWatcher = addon.Core.UnitAuraWatcher
local kickTracker = addon.Core.KickTracker
local iconSlotContainer = addon.Core.IconSlotContainer
local eventGate = addon.Core.EventGate
local fontUtil = addon.Utils.FontUtil
local moduleUtil = addon.Utils.ModuleUtil
local ModuleName = addon.Utils.ModuleName
local units = addon.Utils.Units
local auras = addon.Utils.Auras
-- 12.1 path: each portrait gets an AuraContainer with four manually-anchored AuraSlots (cc, big
-- defensive, external defensive, important) covering the portrait. The legacy strict priority is
-- expressed with frame levels: kick (IconSlotContainer, topmost) > cc > big > external >
-- important - a higher-priority icon simply covers the ones below, and empty slots hide
-- themselves (secretly). Slot containers carry no aura groups, so none of the group-related
-- layout restrictions apply. The Blizzard nameplate buffList scan for important buffs is
-- replaced by the HELPFUL|IMPORTANT slot. TEMPORARY dual path: remove the watcher branch once
-- 12.1 is live everywhere.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()
local testModeActive = false
local paused = false
local enabled = false
local containers = {}
-- Legacy-only / 12.1-only event gates (see Init); a disabled portrait module receives no
-- events at all.
---@type EventGate?
local nameplateGate
---@type EventGate?
local unitChangeGate
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

---12.1 path: builds the layered AuraSlot stack over a portrait. The container is parented to
---the kick container's frame so it follows the per-addon frame level adjustments the attach
---functions apply afterwards (child levels shift with the parent).
---@param kickFrame table The kick IconSlotContainer's frame (already anchored over the portrait).
---@param unit string
---@param texCoord table? {left, right, top, bottom} icon crop, per unit-frame addon.
---@param mask table? MaskTexture for round portraits (Blizzard frames).
---@param iconSize number Used for the cooldown countdown font size.
local function CreatePortraitAuraDisplay(kickFrame, unit, texCoord, mask, iconSize)
	-- One single-icon aura GROUP container per category, stacked by frame level (priority:
	-- kick > cc > big defensive > external defensive > important; a higher-priority icon
	-- covers the ones below, and empty containers hide their button secretly). AuraSlots
	-- would be the natural fit, but they silently failed to render on the 12.1 PTR and no
	-- known addon exercises them - single-icon groups are the same thing ("slots" are
	-- documented as groups with maxFrameCount 1) built on the verified-working group API.
	--
	-- Levels stack UP from the kick frame: the kick frame sits at unitFrame-1, so anything
	-- below it renders BEHIND the unit frame's own portrait texture (diagnosed on PTR:
	-- TargetFrame is level 500 and displays at 494-497 were invisible under it, while
	-- PlayerFrame at level 1 with displays at 1-4 happened to work). Displays are children
	-- of the kick frame so per-addon level adjustments shift the whole stack together.
	local baseLevel = (kickFrame:GetFrameLevel() or 0) + 1
	local cooldowns = {}
	local frames = {}

	local function InitButton(button)
		button:SetSize(iconSize, iconSize)

		local icon = button:CreateTexture(nil, "BACKGROUND", nil, 1)
		icon:SetAllPoints(button)
		if texCoord then
			icon:SetTexCoord(texCoord[1], texCoord[2], texCoord[3], texCoord[4])
		end
		if mask then
			icon:AddMaskTexture(mask)
		end
		button:SetIcon(icon)

		local cd = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
		cd:SetAllPoints(button)
		cd:SetDrawEdge(false)
		cd:SetDrawBling(false)
		cd:SetHideCountdownNumbers(false)
		cd:SetSwipeColor(0, 0, 0, 0.8)
		if mask then
			-- Keep cooldown within the portrait icon
			cd:SetSwipeTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
		end
		cd:SetReverse(db.Modules.PortraitModule.ReverseCooldown or false)
		fontUtil:UpdateCooldownFontSize(cd, iconSize, nil, db.FontScale or 1.0)
		button:SetDurationCooldown(cd)
		cooldowns[#cooldowns + 1] = cd

		button:EnableMouse(false)
	end

	-- Priority stack, lowest first (buttons render one level above their container).
	local categorySpecs = {
		{ filter = "HELPFUL|IMPORTANT", level = baseLevel },
		{ filter = "HELPFUL|EXTERNAL_DEFENSIVE", level = baseLevel + 1 },
		{ filter = "HELPFUL|BIG_DEFENSIVE", level = baseLevel + 2 },
		{ filter = "HARMFUL|CROWD_CONTROL", level = baseLevel + 3 },
	}

	for _, spec in ipairs(categorySpecs) do
		local ac = CreateFrame("AuraContainer", nil, kickFrame, "CustomAuraContainerTemplate")
		ac:SetAllPoints(kickFrame)
		ac:SetIgnoreParentAlpha(true)
		ac:SetFrameLevel(spec.level)
		ac:SetUnit(unit)
		ac:AddAuraGroup("main", spec.filter, {
			maxFrameCount = 1,
			-- Reverse instance-id order = newest aura first, matching the legacy Reverse sort.
			sortMethod = AuraContainerSortMethod.AuraInstanceIDOnly,
			sortDirection = AuraContainerSortDirection.Reverse,
			initializeFrame = InitButton,
			layout = { elementWidth = iconSize, elementHeight = iconSize },
		})
		frames[#frames + 1] = ac
	end

	return { Frames = frames, Cooldowns = cooldowns }
end

local function CreateContainer(unitFrame, portrait, unit, texCoord, mask)
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

	if USE_AURA_CONTAINERS and unit then
		-- Lift the kick slot above the whole aura display stack (displays at kick+1..+4,
		-- buttons one higher) so an active kick lockout covers any aura icon. The slot frame
		-- is a child of the kick frame, so later per-addon level adjustments shift everything
		-- together and the ordering holds.
		local slot = container.Slots[1]
		if slot and slot.Frame then
			slot.Frame:SetFrameLevel(container.Frame:GetFrameLevel() + 7)
		end

		container.AuraDisplay = CreatePortraitAuraDisplay(container.Frame, unit, texCoord, mask, size)
		container.AuraUnit = unit
	end

	return container
end

---12.1 path: renders the kick icon into the kick container (the aura slots underneath handle
---everything else). Schedules a follow-up when the kick expires, since no aura event will fire
---to clear it.
---@param unit string
---@param container IconSlotContainer
local function UpdateKickIcon(unit, container)
	if not enabled or paused then
		return
	end

	if container.KickTimer then
		container.KickTimer:Cancel()
		container.KickTimer = nil
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

		local remaining = (kickEntry.StartTime or 0) + (kickEntry.Duration or 0) - GetTime()
		if remaining > 0 then
			container.KickTimer = C_Timer.NewTimer(remaining + 0.05, function()
				container.KickTimer = nil
				UpdateKickIcon(unit, container)
			end)
		end
	else
		container:SetSlotUnused(1)
	end
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
		-- Drop purgeable non-defensive buffs (the non-important garbage Blizzard's enemy list bundles
		-- in); purgeable defensives like magic barriers are kept.
		if auras:IsPurgeableNonDefensive(unit, auraInstanceID) then
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
			-- Hide a non-important buff via alpha: IsSpellImportant is a secret boolean SetAlphaFromBoolean
			-- accepts directly. Catches the non-important garbage the purgeable filter can't (e.g. for
			-- non-dispel specs).
			Alpha = C_Spell.IsSpellImportant(importantAura.spellId),
			ReverseCooldown = db.Modules.PortraitModule.ReverseCooldown,
			FontScale = db.FontScale,
		})
		return
	end

	-- No auras to display, clear the slot if it was used
	container:SetSlotUnused(slotIndex)
end

---Registers the per-unit re-render hooks shared by every attach variant: the watcher callback
---(legacy) and the target/focus update list used by kick and important-buff refreshes.
---@param unit string
---@param watcher Watcher?
---@param container IconSlotContainer
local function RegisterUnitUpdate(unit, watcher, container)
	if watcher then
		watcher:RegisterCallback(function()
			OnAuraInfo(unit, watcher, container)
		end)
	end

	if unit == "target" or unit == "focus" then
		unitUpdateFns[unit] = unitUpdateFns[unit] or {}
		unitUpdateFns[unit][#unitUpdateFns[unit] + 1] = function()
			if watcher then
				OnAuraInfo(unit, watcher, container)
			else
				UpdateKickIcon(unit, container)
			end
		end
	end
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

	local watcher
	if not USE_AURA_CONTAINERS then
		watcher = unitWatcher:New(unit, events, nil, nil, Enum.UnitAuraSortDirection.Reverse)
		watchers[unit] = watcher
	end

	local mask = GetPortraitMask(unitFrame) or CreatePortraitMask(portrait)

	local container = CreateContainer(unitFrame, portrait, unit, { 0.1, 0.9, 0.1, 0.9 }, mask)
	if not container then return end

	if unit == "pet" then
		container.Frame:SetFrameLevel(math.max(0, (PetFrame:GetFrameLevel() or 0) - 2))
	end

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

	RegisterUnitUpdate(unit, watcher, container)
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

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = CreateContainer(elvuiFrame, elvuiPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
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

	RegisterUnitUpdate(unit, watcher, container)
	containers[#containers + 1] = container
end

---@param unit string
local function AttachTPerlFrame(unit)
	local tperlFrame, tperlPortrait = GetTPerlFrame(unit)

	if not tperlFrame or not tperlPortrait then
		return
	end

	local watcher = watchers[unit]

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = CreateContainer(tperlFrame, tperlPortrait, unit)
	if not container then return end
	local portraitLevel = tperlPortrait.GetFrameLevel and tperlPortrait:GetFrameLevel()
		or tperlFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel)

	RegisterUnitUpdate(unit, watcher, container)
	containers[#containers + 1] = container
end

---@param unit string
local function AttachUUFFrame(unit)
	local uufFrame, uufPortrait = GetUUFFrame(unit)

	if not uufFrame or not uufPortrait then
		return
	end

	local watcher = watchers[unit]

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	-- Parent to HighLevelContainer (portrait's parent) so frame levels are consistent.
	-- UUF renders portraits inside HighLevelContainer at level 999, so parenting to
	-- uufFrame directly would leave the container far below in the level hierarchy.
	local highLevelContainer = uufPortrait:GetParent()
	local container = CreateContainer(highLevelContainer, uufPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
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

	RegisterUnitUpdate(unit, watcher, container)
	containers[#containers + 1] = container
end

---@param unit string
local function AttachMSUFFrame(unit)
	local msufFrame, msufPortrait = GetMSUFFrame(unit)

	if not msufFrame or not msufPortrait then
		return
	end

	local watcher = watchers[unit]

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = CreateContainer(msufFrame, msufPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
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

	RegisterUnitUpdate(unit, watcher, container)
	containers[#containers + 1] = container
end

---@param unit string
local function AttachEllesmereUIFrame(unit)
	local euiFrame, euiPortrait = GetEllesmereUIFrame(unit)

	if not euiFrame or not euiPortrait then
		return
	end

	local watcher = watchers[unit]

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = CreateContainer(euiFrame, euiPortrait, unit, { 0.15, 0.85, 0.15, 0.85 })
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

	RegisterUnitUpdate(unit, watcher, container)
	containers[#containers + 1] = container
end

---@param unit string
local function AttachEQolFrame(unit)
	local eqolFrame, eqolPortrait = GetEQolFrame(unit)

	if not eqolFrame or not eqolPortrait then
		return
	end

	local watcher = watchers[unit]

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = CreateContainer(eqolFrame, eqolPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
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

	RegisterUnitUpdate(unit, watcher, container)
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
		if container.AuraDisplay then
			for _, frame in ipairs(container.AuraDisplay.Frames) do
				frame:SetEnabled(false)
				frame:Hide()
			end
		end
	end
end

local function EnableWatchers()
	for _, watcher in pairs(watchers) do
		watcher:Enable()
	end

	for _, container in pairs(containers) do
		if container.AuraDisplay then
			for _, frame in ipairs(container.AuraDisplay.Frames) do
				frame:SetEnabled(true)
				frame:Show()
			end
		end
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

	-- Events stay unregistered while disabled; the addon-wide Refresh (config, world
	-- change, raid flip) re-runs this gate.
	if nameplateGate then
		nameplateGate:SetActive(enabled)
	end
	if unitChangeGate then
		unitChangeGate:SetActive(enabled)
	end

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

	-- 12.1: re-apply the cooldown style to the aura buttons (only possible while auras aren't
	-- secret - button APIs error otherwise, including out-of-combat in M+/encounters/PvP) and
	-- hide the live displays in test mode so real and fake icons don't mix.
	if USE_AURA_CONTAINERS then
		local reverse = db.Modules.PortraitModule.ReverseCooldown or false
		local canStyle = not wowEx:IsAuraStylingRestricted()
		for _, container in pairs(containers) do
			local auraDisplay = container.AuraDisplay
			if auraDisplay then
				if canStyle then
					for _, cd in ipairs(auraDisplay.Cooldowns) do
						cd:SetReverse(reverse)
					end
				end
				for _, frame in ipairs(auraDisplay.Frames) do
					frame:SetShown(not testModeActive)
				end
			end
		end
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
	-- Legacy only: on 12.1 the important slot tracks its unit itself.
	if not USE_AURA_CONTAINERS then
		local nameplateEvents = CreateFrame("Frame")
		nameplateEvents:SetScript("OnEvent", function(_, _, unitToken)
			HookNameplateAuraFrame(unitToken)
		end)
		nameplateGate = eventGate:New(nameplateEvents, { "NAME_PLATE_UNIT_ADDED" }, {
			-- Hook plates that spawned while disabled - their add events were never seen.
			OnActivate = function()
				for _, nameplate in pairs(C_NamePlate.GetNamePlates()) do
					if nameplate.unitToken then
						HookNameplateAuraFrame(nameplate.unitToken)
					end
				end
			end,
		})
	end

	-- 12.1: containers track their unit token but don't refresh when the token's occupant
	-- changes (the legacy watchers registered these events themselves); Blizzard's container
	-- mixin exposes UpdateAllAuras for exactly this.
	if USE_AURA_CONTAINERS then
		local unitChangeEvents = CreateFrame("Frame")
		unitChangeEvents:SetScript("OnEvent", function(_, event)
			local unit = event == "PLAYER_TARGET_CHANGED" and "target" or "focus"
			for _, container in pairs(containers) do
				if container.AuraUnit == unit and container.AuraDisplay then
					for _, frame in ipairs(container.AuraDisplay.Frames) do
						frame:UpdateAllAuras()
					end
				end
			end
			local fns = unitUpdateFns[unit]
			if fns then
				for _, fn in ipairs(fns) do
					fn()
				end
			end
		end)
		unitChangeGate = eventGate:New(unitChangeEvents, { "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED" })
	end

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
