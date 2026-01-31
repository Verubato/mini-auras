---@type string, Addon
local _, addon = ...
local mini = addon.Framework
local frames = addon.Frames
local unitWatcher = addon.UnitAuraWatcher
local capabilities = addon.Capabilities
local overlays = {}

---@type Db
local db

---@class PortraitManager
local M = {}
addon.PortraitManager = M

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

	-- target of target
	if unitFrame.PortraitMask then
		return unitFrame.PortraitMask
	end

	return nil
end

local function EnsureOverlay(unitFrame, portrait)
	local overlay = overlays[portrait]

	if overlay then
		return overlay
	end

	overlay = CreateFrame("Frame", nil, unitFrame)
	overlay:Hide()

	frames:AnchorFrameToRegionGeometry(overlay, portrait)

	overlay:SetFrameStrata(unitFrame:GetFrameStrata())
	overlay:SetFrameLevel((unitFrame:GetFrameLevel() or 0) + 1)

	local tex = overlay:CreateTexture(nil, "OVERLAY")
	tex:SetAllPoints()

	-- crop the icon like blizzard does
	tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local mask = GetPortraitMask(unitFrame)
	if mask then
		AddMask(tex, mask)
	end

	local cd = CreateFrame("Cooldown", nil, overlay, "CooldownFrameTemplate")
	cd:SetAllPoints(overlay)
	cd:SetFrameLevel((overlay:GetFrameLevel() or 0) + 1)
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	-- keep within the portrait icon
	cd:SetSwipeTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")

	overlay.Icon = tex
	overlay.Cooldown = cd
	overlays[portrait] = overlay

	return overlay
end

---@param watcher Watcher
---@param unitFrame table
---@param portrait table
local function OnCcAppliedChanged(watcher, unitFrame, portrait)
	local overlay = EnsureOverlay(unitFrame, portrait)
	local ccState = watcher:GetCcState()

	if db.Portrait.Enabled and ccState and ccState.IsCcApplied then
		if ccState.CcSpellIcon then
			overlay.Icon:SetTexture(ccState.CcSpellIcon)
		else
			overlay:Hide()
		end

		if ccState.CcStartTime and ccState.CcTotalDuration then
			overlay.Cooldown:SetCooldown(ccState.CcStartTime, ccState.CcTotalDuration)
			overlay.Cooldown:Show()
		else
			overlay.Cooldown:Hide()
		end

		overlay:Show()
	else
		overlay:Hide()
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
	end
	return nil
end

---@return PortraitOverlay? overlay
---@param unit string
function M:GetPortrait(unit)
	local unitFrame, portrait = GetBlizzardFrame(unit)

	if not unitFrame or not portrait then
		return nil
	end

	return EnsureOverlay(unitFrame, portrait)
end

---@return PortraitOverlay[]
function M:GetOverlays()
	return overlays
end

---@param unit string
---@param events string[]?
local function Attach(unit, events)
	local unitFrame, portrait = GetBlizzardFrame(unit)

	if not unitFrame or not portrait then
		return nil
	end

	local overlay = EnsureOverlay(unitFrame, portrait)
	local watcher = unitWatcher:New(unit, nil, events)

	watcher:RegisterCallback(function()
		OnCcAppliedChanged(watcher, unitFrame, portrait)
	end)

	overlay.Watcher = watcher
	return overlay
end

function M:Init()
	if not capabilities:SupportsCrowdControlFiltering() then
		return
	end

	db = mini:GetSavedVars()

	Attach("player")
	Attach("target", { "PLAYER_TARGET_CHANGED" })
	Attach("focus", { "PLAYER_FOCUS_CHANGED" })
end

---@class PortraitOverlay
---@field Show fun(self: PortraitOverlay)
---@field Hide fun(self: PortraitOverlay)
---@field Icon table
