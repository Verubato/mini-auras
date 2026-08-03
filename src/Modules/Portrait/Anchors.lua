---@type string, Addon
local _, addon = ...
local wowEx = addon.Utils.WoWEx

-- Loaded before this file in TOC order.
local observer = addon.Modules.Portrait.Observer
local display  = addon.Modules.Portrait.Display

---@class PortraitAnchors
local M = {}
addon.Modules.Portrait.Anchors = M

-- TEMPORARY dual path: the legacy branch needs a watcher per portrait; on 12.1 the containers
-- track their own auras and a portrait can be attached without one.
local USE_AURA_CONTAINERS = wowEx:UseAuraContainers()

---Registers the per-unit re-render hooks shared by every attach variant: the watcher callback
---(legacy) and the target/focus update list used by kick and important-buff refreshes.
---@param unit string
---@param watcher Watcher?
---@param container IconSlotContainer
local function RegisterUnitUpdate(unit, watcher, container)
	if watcher then
		watcher:RegisterCallback(function()
			display:OnAuraInfo(unit, watcher, container)
		end)
	end

	if unit == "target" or unit == "focus" then
		observer:RegisterUnitUpdate(unit, function()
			if watcher then
				display:OnAuraInfo(unit, watcher, container)
			else
				display:UpdateKickIcon(unit, container)
			end
		end)
	end
end

---Points every icon region in a slot at the portrait itself, cropped to `inset`. Third-party
---portraits are plain textures of arbitrary shape, so the slot has to be stretched onto them
---rather than sitting in the container's own laid-out rect.
---@param container IconSlotContainer
---@param portrait table
---@param min number crop coordinate for the left/top edge
---@param max number crop coordinate for the right/bottom edge
local function StretchSlotsOverPortrait(container, portrait, min, max)
	local originalSetSlot = container.SetSlot
	container.SetSlot = function(self, slotIndex, options)
		originalSetSlot(self, slotIndex, options)
		local slot = self.Slots[slotIndex]
		if slot and slot.Container and slot.Container.Icon and slot.Container.Cooldown then
			slot.Frame:SetAllPoints(portrait)
			slot.Container.Frame:SetAllPoints(portrait)
			slot.Container.Icon:SetAllPoints(portrait)
			slot.Container.Icon:SetTexCoord(min, max, min, max)
			slot.Container.Cooldown:SetAllPoints(portrait)
		end
	end
end

-- Frame lookups, one per supported unit-frame addon. Each returns the frame the container hangs
-- off and the portrait region it covers, or nil when that addon is not the one running.

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

---@param unit string
---@param events string[]?
local function AttachBlizzardFrame(unit, events)
	local unitFrame, portrait = GetBlizzardFrame(unit)

	if not unitFrame or not portrait then
		return
	end

	local watcher
	if not USE_AURA_CONTAINERS then
		watcher = observer:CreateWatcher(unit, events)
	end

	local mask = display:GetPortraitMask(unitFrame) or display:CreatePortraitMask(portrait)

	local container = display:CreateContainer(unitFrame, portrait, unit, { 0.1, 0.9, 0.1, 0.9 }, mask)
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
				display:ApplyMaskToLayer(slot.Container, mask)
			end
		end
	end

	RegisterUnitUpdate(unit, watcher, container)
	portrait:SetDrawLayer("BACKGROUND", 0)
	display:AddContainer(container)
end

---@param unit string
local function AttachElvUIFrame(unit)
	local elvuiFrame, elvuiPortrait = GetElvUIFrame(unit)

	if not elvuiFrame or not elvuiPortrait then
		return
	end

	local watcher = observer:GetWatcher(unit)

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = display:CreateContainer(elvuiFrame, elvuiPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
	if not container then return end
	-- 3d models are a frame, where as 2d portraits are textures which don't have a frame level
	-- so for 2d textures we get the frame level from the parent frame, for 3d portraits we get it directly from the portrait frame
	local portraitLevel = elvuiPortrait.GetFrameLevel and elvuiPortrait:GetFrameLevel()
		or elvuiFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel)

	-- ElvUI is the one case that leaves the slot frame where the container put it and only
	-- stretches the icon and cooldown, so it cannot use the shared helper.
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
	display:AddContainer(container)
end

---@param unit string
local function AttachTPerlFrame(unit)
	local tperlFrame, tperlPortrait = GetTPerlFrame(unit)

	if not tperlFrame or not tperlPortrait then
		return
	end

	local watcher = observer:GetWatcher(unit)

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = display:CreateContainer(tperlFrame, tperlPortrait, unit)
	if not container then return end
	local portraitLevel = tperlPortrait.GetFrameLevel and tperlPortrait:GetFrameLevel()
		or tperlFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel)

	RegisterUnitUpdate(unit, watcher, container)
	display:AddContainer(container)
end

---@param unit string
local function AttachUUFFrame(unit)
	local uufFrame, uufPortrait = GetUUFFrame(unit)

	if not uufFrame or not uufPortrait then
		return
	end

	local watcher = observer:GetWatcher(unit)

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	-- Parent to HighLevelContainer (portrait's parent) so frame levels are consistent.
	-- UUF renders portraits inside HighLevelContainer at level 999, so parenting to
	-- uufFrame directly would leave the container far below in the level hierarchy.
	local highLevelContainer = uufPortrait:GetParent()
	local container = display:CreateContainer(highLevelContainer, uufPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
	if not container then return end
	local portraitLevel = uufPortrait.GetFrameLevel and uufPortrait:GetFrameLevel()
		or highLevelContainer:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 1)

	StretchSlotsOverPortrait(container, uufPortrait, 0.07, 0.93)

	RegisterUnitUpdate(unit, watcher, container)
	display:AddContainer(container)
end

---@param unit string
local function AttachMSUFFrame(unit)
	local msufFrame, msufPortrait = GetMSUFFrame(unit)

	if not msufFrame or not msufPortrait then
		return
	end

	local watcher = observer:GetWatcher(unit)

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = display:CreateContainer(msufFrame, msufPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
	if not container then return end
	local portraitLevel = msufPortrait.GetFrameLevel and msufPortrait:GetFrameLevel()
		or msufFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 10)

	StretchSlotsOverPortrait(container, msufPortrait, 0.07, 0.93)

	RegisterUnitUpdate(unit, watcher, container)
	display:AddContainer(container)
end

---@param unit string
local function AttachEllesmereUIFrame(unit)
	local euiFrame, euiPortrait = GetEllesmereUIFrame(unit)

	if not euiFrame or not euiPortrait then
		return
	end

	local watcher = observer:GetWatcher(unit)

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = display:CreateContainer(euiFrame, euiPortrait, unit, { 0.15, 0.85, 0.15, 0.85 })
	if not container then return end
	local portraitLevel = euiPortrait.GetFrameLevel and euiPortrait:GetFrameLevel()
		or euiFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 10)

	-- EllesmereUI insets its portrait texture with SetTexCoord(0.15, 0.85). Match that on our
	-- overlay so the CC icon visually fills the same area as the portrait beneath it.
	StretchSlotsOverPortrait(container, euiPortrait, 0.15, 0.85)

	RegisterUnitUpdate(unit, watcher, container)
	display:AddContainer(container)
end

---@param unit string
local function AttachEQolFrame(unit)
	local eqolFrame, eqolPortrait = GetEQolFrame(unit)

	if not eqolFrame or not eqolPortrait then
		return
	end

	local watcher = observer:GetWatcher(unit)

	if not USE_AURA_CONTAINERS and not watcher then
		return
	end

	local container = display:CreateContainer(eqolFrame, eqolPortrait, unit, { 0.07, 0.93, 0.07, 0.93 })
	if not container then return end
	local portraitLevel = eqolPortrait.GetFrameLevel and eqolPortrait:GetFrameLevel()
		or eqolFrame:GetFrameLevel()
		or 0
	container.Frame:SetFrameLevel(portraitLevel + 10)

	StretchSlotsOverPortrait(container, eqolPortrait, 0.07, 0.93)

	RegisterUnitUpdate(unit, watcher, container)
	display:AddContainer(container)
end

-- Third-party attach functions and the units each one supports. Ordering matters only in that
-- every addon gets a look at every unit; whichever is actually loaded is the one that attaches.
local THIRD_PARTY_ATTACH = { -- luaconv: references the attach functions above
	{ Attach = AttachElvUIFrame,        Units = { "player", "target", "focus" } },
	{ Attach = AttachTPerlFrame,        Units = { "player", "target", "focus" } },
	{ Attach = AttachUUFFrame,          Units = { "player", "target", "focus", "pet" } },
	{ Attach = AttachMSUFFrame,         Units = { "player", "target", "focus", "pet" } },
	{ Attach = AttachEllesmereUIFrame,  Units = { "player", "target", "focus", "pet" } },
	{ Attach = AttachEQolFrame,         Units = { "player", "target", "focus", "pet" } },
}

function M:AttachBlizzardFrames()
	AttachBlizzardFrame("player")
	AttachBlizzardFrame("target", { "PLAYER_TARGET_CHANGED" })
	AttachBlizzardFrame("focus", { "PLAYER_FOCUS_CHANGED" })
	AttachBlizzardFrame("pet")
end

---Deferred until the world loads, since third-party frames do not exist before then.
function M:AttachThirdPartyFrames()
	for _, entry in ipairs(THIRD_PARTY_ATTACH) do
		for _, unit in ipairs(entry.Units) do
			entry.Attach(unit)
		end
	end
end
