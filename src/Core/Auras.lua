---@type string, Addon
local addonName, addon = ...
local scheduler = addon.Scheduler
local capabilities = addon.Capabilities
local maxAuras = 40
local headerId = 1
local LCG = LibStub and LibStub("LibCustomGlow-1.0", false)

---@class AurasModule
local M = {}
addon.Auras = M

local function NotifyCallbacks(header)
	local callbacks = header.Callbacks

	if not callbacks or #callbacks == 0 then
		return
	end

	for _, callback in ipairs(callbacks) do
		callback()
	end
end

local function OnHeaderEvent(header, event, arg1)
	local unit = header:GetAttribute("unit")
	local filter = header:GetAttribute("filter")
	local glow = header:GetAttribute("x-glow") or false
	local reverseSwipe = header:GetAttribute("x-reverse-cooldown") or false

	if not unit then
		return
	end

	if event ~= "UNIT_AURA" then
		return
	end

	if arg1 ~= unit then
		return
	end

	---@type boolean|boolean[]
	local ccApplied

	for i = 1, maxAuras do
		local child = header:GetAttribute("child" .. i)

		if not child or not child:IsShown() then
			break
		end

		local icon = child.Icon
		local cooldown = child.Cooldown

		if not icon or not cooldown then
			-- invalid xml
			break
		end

		icon:SetAllPoints(child)

		cooldown:SetReverse(reverseSwipe)

		local data = C_UnitAuras.GetAuraDataByIndex(unit, child:GetID(), filter)

		if data then
			icon:SetTexture(data.icon)

			local isCC = C_Spell.IsSpellCrowdControl(data.spellId)

			if not capabilities:SupportsCrowdControlFiltering() then
				icon:SetAlphaFromBoolean(isCC)
				ccApplied = ccApplied or {}
				ccApplied[#ccApplied + 1] = isCC
			end

			local start
			local duration
			local durationInfo = C_UnitAuras.GetAuraDuration(unit, data.auraInstanceID)

			if durationInfo then
				start = durationInfo:GetStartTime()
				duration = durationInfo:GetTotalDuration()
			end

			if start and duration then
				cooldown:SetCooldown(start, duration)
				cooldown:Show()

				if capabilities:SupportsCrowdControlFiltering() then
					ccApplied = true
				end

				if LCG then
					if glow then
						LCG.ProcGlow_Start(child, {
							-- don't flash at the start
							startAnim = false,
						})

						-- this is where LibCustomGlow stores it's frame
						local procGlow = child._ProcGlow
						procGlow:SetAlphaFromBoolean(isCC)
					else
						-- they may have turned off glow icons option since last time we reached here
						LCG.ProcGlow_Stop(child)
					end
				end
			else
				cooldown:Hide()
				cooldown:SetCooldown(0, 0)

				if LCG then
					LCG.ProcGlow_Stop(child)
				end
			end

			if not capabilities:SupportsCrowdControlFiltering() then
				cooldown:SetAlphaFromBoolean(isCC)
			end
		else
			icon:Hide()

			if LCG then
				LCG.ProcGlow_Stop(child)
			end
		end
	end

	if not capabilities:SupportsCrowdControlFiltering() then
		header.IsCcApplied = ccApplied
		NotifyCallbacks(header)
	elseif header.IsCcApplied ~= ccApplied then
		header.IsCcApplied = ccApplied
		NotifyCallbacks(header)
	end
end

---@param header table
---@param options IconOptions
local function RefreshHeaderChildSizes(header, options)
	local iconSize = tonumber(options.Size) or 32

	for i = 1, maxAuras do
		local child = header:GetAttribute("child" .. i)

		if not child then
			-- children are created sequentially; if this one doesn't exist, later ones won't either
			break
		end

		child:SetSize(iconSize, iconSize)

		-- make sure the icon size stays correct
		if child.Icon then
			child.Icon:SetAllPoints(child)
		end

		-- keep cooldown filling the button
		if child.Cooldown then
			child.Cooldown:ClearAllPoints()
			child.Cooldown:SetAllPoints(child)
		end
	end
end

---@param unit string
---@param header table
---@param options IconOptions
local function UpdateHeader(header, unit, options)
	local iconSize = options and tonumber(options.Size) or 32

	header:SetAttribute("unit", unit)
	header:SetAttribute("x-iconSize", iconSize)
	header:SetAttribute("x-glow", options.Glow)
	header:SetAttribute("x-reverse-cooldown", options.ReverseCooldown)

	if capabilities:SupportsCrowdControlFiltering() then
		header:SetAttribute("xOffset", iconSize + 1)
	else
		-- have all icons overlap themselves, and then only the visible on is shown
		-- genius right?
		header:SetAttribute("xOffset", 0)
	end

	-- refresh any icon sizes that may have changed
	RefreshHeaderChildSizes(header, options)
end

local function CreateSecureHeader()
	local header = CreateFrame("Frame", addonName .. "SecureHeader" .. headerId, UIParent, "SecureAuraHeaderTemplate")

	header:SetAttribute("template", "MiniCCAuraButtonTemplate")

	if capabilities:SupportsCrowdControlFiltering() then
		header:SetAttribute("filter", "HARMFUL|CROWD_CONTROL")
	else
		header:SetAttribute("filter", "HARMFUL|INCLUDE_NAME_PLATE_ONLY")
	end

	header:SetAttribute("sortMethod", "TIME")
	header:SetAttribute("sortDirection", "-")
	header:SetAttribute("point", "TOPLEFT")
	header:SetAttribute("minWidth", 1)
	header:SetAttribute("minHeight", 1)

	header:SetAttribute("yOffset", 0)
	header:SetAttribute("wrapAfter", 40)
	header:SetAttribute("maxWraps", 1)
	header:SetAttribute("wrapXOffset", 0)
	header:SetAttribute("wrapYOffset", 0)
	header:SetAttribute(
		"initialConfigFunction",
		[[
			local header = self:GetParent()
			local iconSize = header:GetAttribute("x-iconSize")

			self:SetWidth(iconSize)
			self:SetHeight(iconSize)
			-- disable mouse so you can still mouseover heal on unit frames
			self:EnableMouse(false)
		]]
	)

	header:HookScript("OnEvent", OnHeaderEvent)

	headerId = headerId + 1

	return header
end

---@param unit string
---@param options IconOptions
---@return Header
function M:CreateHeader(unit, options)
	if not unit then
		error("unit must not be nil")
	end

	local header = CreateSecureHeader()
	UpdateHeader(header, unit, options)

	header.Callbacks = {}
	header.IsCcApplied = false

	function header.RegisterCallback(headerSelf, callback)
		if not callback then
			return
		end

		headerSelf.Callbacks[#headerSelf.Callbacks + 1] = callback
	end

	return header
end

---@param unit string
---@param header table
---@param options IconOptions
function M:UpdateHeader(header, unit, options)
	UpdateHeader(header, unit, options)
end

function M:ClearHeader(header)
	scheduler:RunWhenCombatEnds(function()
		header:SetAttribute("unit", nil)
		header.Callbacks = {}
	end)
end

---@class Header : Frame
---@field IsCcApplied boolean|boolean[]
---@field RegisterCallback fun(self: Header, callback: fun(ccApplied: boolean))

---@class Frame
---@field SetPoint fun(self: Frame, point: string, relativeTo: any, relativePoint: string, xOffset: number?, yOffset: number?)
---@field GetAttribute fun(self: Header, attribute: string): any
---@field IsVisible fun(self: Frame): boolean
---@field Show fun(self: Frame)
---@field Hide fun(self: Frame)
