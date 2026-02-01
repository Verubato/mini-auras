---@type string, Addon
local _, addon = ...
local frames = addon.Frames
local unitWatcher = addon.UnitAuraWatcher
local overlays = {}

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

local function EnsureOverlay(unitFrame, portrait, index)
	local portraitOverlays = overlays[portrait]

	if not portraitOverlays then
		portraitOverlays = {}
		overlays[portrait] = portraitOverlays
	end

	local overlay = portraitOverlays[index]

	if overlay then
		return overlay
	end

	overlay = CreateFrame("Frame", nil, unitFrame)
	overlay:SetAlpha(0)
	overlay:Show()

	frames:AnchorFrameToRegionGeometry(overlay, portrait)

	overlay:SetFrameStrata(unitFrame:GetFrameStrata())
	overlay:SetFrameLevel((unitFrame:GetFrameLevel() or 0) + 5)

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

	portraitOverlays[index] = overlay

	return overlay
end

local function HideFrom(portrait, index)
	local portraits = overlays[portrait]

	if portraits then
		for i = index, #portraits do
			portraits[i]:SetAlpha(0)
		end
	end
end

---@param watcher Watcher
---@param unitFrame table
---@param portrait table
local function OnAuraInfo(watcher, unitFrame, portrait)
	local portraitIndex = 1
	local ccAuras = watcher:GetCcState()
	local importantAuras = watcher:GetImportantState()
	local defensiveAuras = watcher:GetDefensiveState()

	for _, aura in ipairs(ccAuras) do
		local overlay = EnsureOverlay(unitFrame, portrait, portraitIndex)
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			overlay.Icon:SetTexture(aura.SpellIcon)
			overlay.Cooldown:SetCooldown(aura.StartTime, aura.TotalDuration)

			if not issecretvalue(aura.IsCC) then
				-- we're in 12.0.1
				if aura.IsCC then
					overlay:SetAlpha(1)
					HideFrom(portrait, portraitIndex + 1)
					return
				end
			else
				overlay:SetAlphaFromBoolean(aura.IsCC)
			end
		else
			overlay:SetAlpha(0)
		end

		portraitIndex = portraitIndex + 1
	end

	for _, aura in ipairs(defensiveAuras) do
		local overlay = EnsureOverlay(unitFrame, portrait, portraitIndex)
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			overlay.Icon:SetTexture(aura.SpellIcon)
			overlay.Cooldown:SetCooldown(aura.StartTime, aura.TotalDuration)

			-- we only get defensives in 12.0.1 which we got from a filter
			overlay:SetAlpha(1)
			HideFrom(portrait, portraitIndex + 1)
			return
		else
			overlay:SetAlpha(0)
		end

		portraitIndex = portraitIndex + 1
	end

	for _, aura in ipairs(importantAuras) do
		local overlay = EnsureOverlay(unitFrame, portrait, portraitIndex)
		if aura.SpellIcon and aura.StartTime and aura.TotalDuration then
			overlay.Icon:SetTexture(aura.SpellIcon)
			overlay.Cooldown:SetCooldown(aura.StartTime, aura.TotalDuration)
			overlay:SetAlphaFromBoolean(aura.IsImportant)
		else
			overlay:SetAlpha(0)
		end

		portraitIndex = portraitIndex + 1
	end

	HideFrom(portrait, portraitIndex)
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

---@return PortraitOverlay[]
function M:GetOverlays()
	local result = {}
	for _, portraitOverlays in pairs(overlays) do
		for _, overlay in ipairs(portraitOverlays) do
			result[#result + 1] = overlay
		end
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

	local overlay = EnsureOverlay(unitFrame, portrait, 1)
	local watcher = unitWatcher:New(unit, events)

	watcher:RegisterCallback(function()
		OnAuraInfo(watcher, unitFrame, portrait)
	end)

	overlay.Watcher = watcher
	return overlay
end

function M:Init()
	Attach("player")
	Attach("target", { "PLAYER_TARGET_CHANGED" })
	Attach("focus", { "PLAYER_FOCUS_CHANGED" })
end

---@class PortraitOverlay
---@field SetAlpha fun(self: PortraitOverlay, alpha: number)
---@field Icon table
