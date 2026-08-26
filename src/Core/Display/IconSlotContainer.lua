---@type string, Addon
local _, addon = ...
local LCG = LibStub and LibStub("LibCustomGlow-1.0", true)
local Masque = LibStub and LibStub("Masque", true)
local changeStamp = addon.Utils.ChangeStamp
local fontUtil = addon.Utils.FontUtil
local iconUtil = addon.Utils.IconUtil
local wowEx = addon.Utils.WoWEx
local glowStyles = addon.Core.GlowStyles

-- The icon crop (Utils/IconUtil) leaves the artwork reaching the icon's edge, so our own border
-- sits flush and the swipe covers exactly the visible square. A Masque skin overrides it with its
-- own crop, since the skin owns the icon's shape.

-- Style name -> the field its built frame is cached under on a parent, so a frame is never
-- built twice per layer. Membership doubles as "this style is texture-based": the shared
-- catalog holds exactly the styles that render without LibCustomGlow.
local STATIC_GLOW_FIELDS = {}
for name in pairs(glowStyles.Specs) do
	STATIC_GLOW_FIELDS[name] = "_StaticGlow_" .. name
end

-- Debounce table keyed by container: one deferred ReSkin per container per frame
local masqueReskinPending = {}
local cachedDb = nil
-- Reused across Layout() calls to avoid a table allocation on the hot path
local layoutScratch = {}
-- What each container's layout was last built from; see Layout.
local layoutStamp = changeStamp:New()
-- Reused by UpdateGlow() to avoid allocating glow option tables on every call.
-- LCG functions read these values immediately and do not store references.
local glowOptionsScratch = { startAnim = false }
local glowColorScratch = { 0, 0, 0, 0 }
local frameIdCounter = 0
-- Cooldowns whose countdown text is being coloured by remaining time, mapped to their expiry.
-- Only cooldowns with an addon-known expiry ever land here (see WoWEx.GetDurationExpiry), so
-- secret aura durations are never read. One shared ticker serves every container.
local coloredCooldowns = {}
local colorTicker
-- Fallbacks while db.CountdownColors is missing, which a profile snapshot saved before the setting
-- existed round-trips without. Must match BAND_DEFAULTS in Core/Auras/AuraCountdownText.
local COUNTDOWN_FALLBACKS = {
	Under5s = { R = 1, G = 0, B = 0 },
	Under60s = { R = 1, G = 0.8, B = 0 },
	Over60s = { R = 1, G = 1, B = 1 },
}

---@class IconSlotContainer
local M = {}
M.__index = M

addon.Core.IconSlotContainer = M

local function UpdateChargeTextFontSize(chargeText, iconSize, fontScale)
	fontUtil:UpdateFontSize(chargeText, iconSize, 0.35, fontScale)
end

local function NextFrameName(frameType)
	frameIdCounter = frameIdCounter + 1
	return "MiniAuras_" .. frameType .. "_" .. frameIdCounter
end

local function GetDb()
	if not cachedDb then
		cachedDb = addon.Framework:GetSavedVars()
	end

	return cachedDb
end

---The cooldown's own countdown fontstring, scanned once and cached under the same field
---FontUtil uses, so whichever side looks first pays for the scan.
local function GetCooldownText(cd)
	if not cd.MiniAurasFontString then
		for i = 1, cd:GetNumRegions() do
			local region = select(i, cd:GetRegions())
			if region and region:GetObjectType() == "FontString" then
				cd.MiniAurasFontString = region
				break
			end
		end
	end

	return cd.MiniAurasFontString
end

---Colour bands by remaining seconds, tinted by db.CountdownColors. They must match the curve stops
---in Core/Auras/AuraCountdownText so these icons show exactly what the curve-bound 12.1 aura icons
---show. Compared by the colour actually applied rather than by band, so a colour changed in the
---options repaints on the next tick.
local function ApplyCountdownColor(cd, remaining)
	local db = GetDb()
	local colors = (db and db.CountdownColors) or COUNTDOWN_FALLBACKS
	local band = (remaining < 5 and (colors.Under5s or COUNTDOWN_FALLBACKS.Under5s))
		or (remaining < 60 and (colors.Under60s or COUNTDOWN_FALLBACKS.Under60s))
		or colors.Over60s or COUNTDOWN_FALLBACKS.Over60s
	local r, g, b = band.R or 1, band.G or 1, band.B or 1

	if cd.MiniAurasColorR == r and cd.MiniAurasColorG == g and cd.MiniAurasColorB == b then
		return
	end

	local text = GetCooldownText(cd)

	if not text then
		return
	end

	cd.MiniAurasColorR, cd.MiniAurasColorG, cd.MiniAurasColorB = r, g, b
	text:SetTextColor(r, g, b)
end

local function ResetCountdownColor(cd)
	coloredCooldowns[cd] = nil

	if cd.MiniAurasColorR then
		cd.MiniAurasColorR, cd.MiniAurasColorG, cd.MiniAurasColorB = nil, nil, nil
		local text = GetCooldownText(cd)
		if text then
			text:SetTextColor(1, 1, 1)
		end
	end
end

---A fixed colour for a preview countdown, routed through the same fields the timed colouring
---uses so ResetCountdownColor can always put white back. The timed colouring wins while it holds
---this cooldown, and white is skipped because that is already the reset state.
local function ApplyStaticCountdownColor(cd, color)
	if coloredCooldowns[cd] then
		return
	end

	local r, g, b = color.r or 1, color.g or 1, color.b or 1

	if r == 1 and g == 1 and b == 1 then
		return
	end

	local text = GetCooldownText(cd)

	if not text then
		return
	end

	cd.MiniAurasColorR, cd.MiniAurasColorG, cd.MiniAurasColorB = r, g, b
	text:SetTextColor(r, g, b)
end

local function OnColorTick()
	local db = GetDb()
	local colorOn = db and db.ColorCountdownByTime
	local now = GetTime()
	local any = false

	for cd, expiry in pairs(coloredCooldowns) do
		if not colorOn or expiry - now <= 0 then
			ResetCountdownColor(cd)
		else
			ApplyCountdownColor(cd, expiry - now)
			any = true
		end
	end

	if not any and colorTicker then
		colorTicker:Cancel()
		colorTicker = nil
	end
end

---Starts colouring a cooldown's countdown by its remaining time, when the global setting is
---on and the duration's expiry is addon-known; otherwise makes sure any old colour is gone.
local function RegisterCountdownColor(cd, durationObject)
	local db = GetDb()
	local expiry = db and db.ColorCountdownByTime and wowEx:GetDurationExpiry(durationObject)
	local remaining = expiry and expiry - GetTime()

	if not remaining or remaining <= 0 then
		ResetCountdownColor(cd)
		return
	end

	coloredCooldowns[cd] = expiry
	ApplyCountdownColor(cd, remaining)

	if not colorTicker then
		-- Bands only change at the 60s and 5s edges, so a coarse tick is plenty.
		colorTicker = C_Timer.NewTicker(0.5, OnColorTick)
	end
end

---Re-fits the skin to the container's current icon size, debounced to one pass per container per
---frame. Scoped to the slots this container owns: a Masque group is shared by every container
---using the same name, and on 12.1 by the aura displays too, whose buttons must only ever be
---touched from their own restriction-gated restyle.
---@param instance IconSlotContainer
local function ScheduleMasqueReSkin(instance)
	local group = instance.MasqueGroup

	if not group or masqueReskinPending[instance] then
		return
	end

	masqueReskinPending[instance] = true
	C_Timer.After(0, function()
		masqueReskinPending[instance] = nil

		for i = 1, instance.Count do
			local slot = instance.Slots[i]
			local container = slot and slot.Container

			if container then
				group:ReSkin(container.Frame)
			end
		end
	end)
end

local function CreateLayer(parentFrame, level, iconSize, noBorder)
	local f = CreateFrame("Frame", NextFrameName("Layer"), parentFrame)
	f:SetAllPoints()

	if level then
		f:SetFrameLevel(level)
	end

	local icon = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	icon:SetAllPoints()
	icon:SetTexCoord(iconUtil:TexCoord())

	local cd = CreateFrame("Cooldown", NextFrameName("Cooldown"), f, "CooldownFrameTemplate")
	cd:SetAllPoints()
	cd:SetDrawEdge(false)
	cd:SetDrawBling(false)
	cd:SetHideCountdownNumbers(false)
	cd:SetSwipeColor(0, 0, 0, 0.7)
	glowStyles:SquareSwipe(cd)
	-- When the cooldown expires naturally the frame hides itself via OnCooldownDone without
	-- any external code calling SetSlot again. Clear desaturation immediately so the icon
	-- doesn't stay grey until the next UpdateDisplay (e.g. the delayed ARENA_COOLDOWNS_UPDATE).
	cd:SetScript("OnCooldownDone", function()
		icon:SetDesaturated(false)
	end)

	local border
	if not noBorder then
		-- The border sits 1px outside the icon, as Blizzard's CompactUnitFrame does:
		-- https://github.com/Gethe/wow-ui-source/blob/aa3d9bc8633244ba017bf2058bf5e84900397ab5/Interface/AddOns/Blizzard_UnitFrame/Shared/CompactUnitFrame.xml#L31
		border = f:CreateTexture(nil, "OVERLAY")
		border:SetPoint("TOPLEFT", f, "TOPLEFT", -1, 1)
		border:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1, -1)
		border:SetTexture("Interface\\Buttons\\UI-Debuff-Overlays")
		border:SetTexCoord(0.296875, 0.5703125, 0, 0.515625)
		border:Hide()
	end

	if iconSize then
		-- Inside nameplate hierarchies GetWidth() can return a secret number, so
		-- remember the size we set ourselves for anything that needs to do math on it.
		f.DesiredSize = iconSize
		cd.DesiredIconSize = iconSize
		-- FontScale will be set when SetSlot is called
		cd.FontScale = 1.0
		fontUtil:UpdateCooldownFontSize(cd, iconSize, nil, cd.FontScale)
	end

	return { Frame = f, Border = border, Icon = icon, Cooldown = cd }
end

local function EnsureContainer(slot, iconSize, group, noBorder)
	if slot.Container then
		return slot.Container
	end

	-- Wrap in its own frame so its alpha does not propagate to the extra layers, which are
	-- siblings under slot.Frame rather than descendants.
	local slotLevel = slot.Frame:GetFrameLevel() or 0
	slot.Container = CreateLayer(slot.Frame, slotLevel + 1, iconSize, noBorder)

	if group then
		group:AddButton(slot.Container.Frame, {
			Icon = slot.Container.Icon,
			Cooldown = slot.Container.Cooldown,
		})
	end

	return slot.Container
end

-- layerIndex is the public layer number (2, 3, ...); extra layer 1 lives at slot.ExtraLayers[1], etc.
local function EnsureExtraLayer(slot, layerIndex, iconSize)
	local extraIdx = layerIndex - 1
	if not slot.ExtraLayers then
		slot.ExtraLayers = {}
	end

	local slotLevel = slot.Frame:GetFrameLevel() or 0
	-- Base layer (slot.Container) occupies slotLevel+1.
	-- Extra layer l (1-based) sits at slotLevel + 1 + l*2 so each layer clears
	-- the cooldown text draw layer of the one below it.
	local baseLevel = slotLevel + 1

	for l = #slot.ExtraLayers + 1, extraIdx do
		slot.ExtraLayers[l] = CreateLayer(slot.Frame, baseLevel + l * 2, iconSize)
	end

	if slot.LastExtraBaseLevel ~= baseLevel then
		slot.LastExtraBaseLevel = baseLevel
		for l = 1, #slot.ExtraLayers do
			local el = slot.ExtraLayers[l]
			if el and el.Frame then
				el.Frame:SetFrameLevel(baseLevel + l * 2)
			end
		end
	end

	return slot.ExtraLayers[extraIdx]
end

local function ApplyAlpha(target, alpha)
	if type(alpha) == "number" then
		target:SetAlpha(alpha)
	else
		target:SetAlphaFromBoolean(alpha)
	end
end

local function ApplyStaticGlowPadding(glowFrame, parent)
	-- GetWidth() returns a secret number inside nameplate hierarchies, which cannot be compared or
	-- multiplied, so fall back to the size we set on the layer ourselves.
	local width = parent:GetWidth()
	if issecretvalue(width) or not (width and width > 0) then
		width = parent.DesiredSize or 30
	end
	local padding = width * glowFrame.PaddingFactor
	glowFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", -padding, padding)
	glowFrame:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", padding, -padding)
end

-- Hooked once per parent. The hook resizes whichever static glows live on this parent so all glow
-- types stay proportional.
local function EnsureStaticGlowResizeHook(parent)
	if parent._StaticGlowResizeHooked then
		return
	end

	parent._StaticGlowResizeHooked = true
	parent:HookScript("OnSizeChanged", function(self)
		for _, fieldName in pairs(STATIC_GLOW_FIELDS) do
			local g = self[fieldName]
			if g then
				ApplyStaticGlowPadding(g, self)
			end
		end
	end)
end

local function GetOrCreateStaticGlow(parent, glowType)
	local field = STATIC_GLOW_FIELDS[glowType]

	if not field then
		return nil
	end

	local cg = parent[field]

	if not cg then
		local spec = glowStyles.Specs[glowType]
		cg = glowStyles:BuildGlowFrame(parent, NextFrameName("StaticGlow"))
		glowStyles:ApplySpec(cg, spec)
		cg:Hide()
		parent[field] = cg

		EnsureStaticGlowResizeHook(parent)
		ApplyStaticGlowPadding(cg, parent)
	end

	return cg
end

local function HideStaticGlowsExcept(parent, exceptType)
	for glowType, field in pairs(STATIC_GLOW_FIELDS) do
		if glowType ~= exceptType and parent[field] then
			parent[field]:Hide()
		end
	end
end

-- LibCustomGlow keeps its glow frames in pools on the shared lib table, and another addon embedding
-- a higher-version copy that loads after ours replaces those pools. Frames we created then belong
-- to the previous pool, so the lib's *_Stop functions raise "Attempted to release object that
-- doesn't belong to this pool". Only call the lib stop while the frame is still active in the
-- current pool, otherwise hide the orphan and drop the stale reference.
local function SafeStopGlow(parent, field, pool, stopFn)
	local f = parent[field]
	if not f then
		return
	end
	-- When the pool can't be inspected (missing field / no IsActive), fall back to the lib stop.
	if not pool or not pool.IsActive or pool:IsActive(f) then
		stopFn(parent)
	else
		f:Hide()
		parent[field] = nil
	end
end

local function StopLCGGlowsExcept(parent, exceptType)
	if not LCG then
		return
	end
	if exceptType ~= "Proc Glow" and parent._ProcGlow and LCG.ProcGlow_Stop then
		SafeStopGlow(parent, "_ProcGlow", LCG.ProcGlowPool, LCG.ProcGlow_Stop)
	end
	if exceptType ~= "Pixel Glow" and parent._PixelGlow and LCG.PixelGlow_Stop then
		SafeStopGlow(parent, "_PixelGlow", LCG.GlowFramePool, LCG.PixelGlow_Stop)
	end
	if exceptType ~= "Autocast Shine" and parent._AutoCastGlow and LCG.AutoCastGlow_Stop then
		SafeStopGlow(parent, "_AutoCastGlow", LCG.GlowFramePool, LCG.AutoCastGlow_Stop)
	end
end

local function ClearLayerData(layer, glowFrame)
	if not layer then
		return
	end
	layer.Icon:SetTexture(nil)
	layer.Cooldown:Clear()
	ResetCountdownColor(layer.Cooldown)
	if layer.Border then
		-- Hide the coloured border too; otherwise a cleared layer that had a border (e.g. a stacked
		-- important layer with Color set) leaves the border visible around an empty icon.
		layer.Border:Hide()
	end
	if layer.ChargeText then
		layer.ChargeText:Hide()
	end
	StopLCGGlowsExcept(glowFrame, nil)
	HideStaticGlowsExcept(glowFrame, nil)
end

local function FillColorScratch(options)
	if options.Color then
		glowColorScratch[1] = options.Color.r or 1
		glowColorScratch[2] = options.Color.g or 1
		glowColorScratch[3] = options.Color.b or 1
		glowColorScratch[4] = options.Color.a or 1
		glowOptionsScratch.color = glowColorScratch
	else
		glowOptionsScratch.color = nil
	end
end

---@return string
local function ResolveGlowType()
	local db = GetDb()
	local glowType = (db and db.GlowType) or "Slot Glow"

	-- Aura icons render through AuraContainerDisplay, which can only use the texture-based glows
	-- because LibCustomGlow cannot attach to AuraButtons. Kick and test icons still render here, so
	-- clamp them to the same set and every glow stays visually consistent.
	if not STATIC_GLOW_FIELDS[glowType] then
		return "Slot Glow"
	end

	return glowType
end

---@param layerFrame table The layer frame to update glow on
---@param options IconLayerOptions Options containing glow settings
local function UpdateGlow(layerFrame, options)
	local glowType = ResolveGlowType()

	if not options.Glow then
		StopLCGGlowsExcept(layerFrame, nil)
		HideStaticGlowsExcept(layerFrame, nil)
		layerFrame._GlowColorKey = nil
		return
	end

	local colorChanged = false
	local newColorKey = nil
	if options.Color then
		newColorKey = string.format(
			"%.2f_%.2f_%.2f_%.2f",
			options.Color.r or 1,
			options.Color.g or 1,
			options.Color.b or 1,
			options.Color.a or 1
		)
	end
	if not newColorKey or not issecretvalue(newColorKey) then
		if layerFrame._GlowColorKey ~= newColorKey then
			colorChanged = true
			layerFrame._GlowColorKey = newColorKey
		end
	elseif newColorKey and issecretvalue(newColorKey) then
		colorChanged = true
	end

	if STATIC_GLOW_FIELDS[glowType] then
		-- Texture-based overlay: stop any LCG glows, hide other static overlays, then
		-- show/tint the one matching the current glow type. Recolouring is a cheap
		-- SetVertexColor so colorChanged doesn't need to recreate anything.
		StopLCGGlowsExcept(layerFrame, nil)
		HideStaticGlowsExcept(layerFrame, glowType)

		local cg = GetOrCreateStaticGlow(layerFrame, glowType)
		if cg then
			if options.Color then
				cg.Texture:SetVertexColor(
					options.Color.r or 1,
					options.Color.g or 1,
					options.Color.b or 1,
					options.Color.a or 1
				)
			else
				cg.Texture:SetVertexColor(1, 1, 1, 1)
			end
			cg:Show()
			ApplyAlpha(cg, options.Alpha)
		end
		return
	end

	HideStaticGlowsExcept(layerFrame, nil)
	StopLCGGlowsExcept(layerFrame, glowType)

	if glowType == "Pixel Glow" then
		if LCG and LCG.PixelGlow_Start then
			local hasPixelGlow = layerFrame._PixelGlow ~= nil
			if not hasPixelGlow or colorChanged then
				if hasPixelGlow and colorChanged and LCG.PixelGlow_Stop then
					SafeStopGlow(layerFrame, "_PixelGlow", LCG.GlowFramePool, LCG.PixelGlow_Stop)
				end
				FillColorScratch(options)
				LCG.PixelGlow_Start(layerFrame, glowOptionsScratch.color)
			end
			if layerFrame._PixelGlow then
				ApplyAlpha(layerFrame._PixelGlow, options.Alpha)
			end
		end
	elseif glowType == "Autocast Shine" then
		if LCG and LCG.AutoCastGlow_Start then
			local hasAutoCastGlow = layerFrame._AutoCastGlow ~= nil
			if not hasAutoCastGlow or colorChanged then
				if hasAutoCastGlow and colorChanged and LCG.AutoCastGlow_Stop then
					SafeStopGlow(layerFrame, "_AutoCastGlow", LCG.GlowFramePool, LCG.AutoCastGlow_Stop)
				end
				FillColorScratch(options)
				LCG.AutoCastGlow_Start(layerFrame, glowOptionsScratch.color)
			end
			if layerFrame._AutoCastGlow then
				ApplyAlpha(layerFrame._AutoCastGlow, options.Alpha)
			end
		end
	else
		-- The remaining type is Proc Glow. Start is called every time so the glow resizes with the
		-- icon.
		if LCG and LCG.ProcGlow_Start then
			if colorChanged and layerFrame._ProcGlow and LCG.ProcGlow_Stop then
				SafeStopGlow(layerFrame, "_ProcGlow", LCG.ProcGlowPool, LCG.ProcGlow_Stop)
			end
			FillColorScratch(options)
			LCG.ProcGlow_Start(layerFrame, glowOptionsScratch)
			if layerFrame._ProcGlow then
				ApplyAlpha(layerFrame._ProcGlow, options.Alpha)
			end
		end
	end
end

---Rounds a layer's icon off while it wears one of the catalog's overlays, since those all have
---rounded inner corners. LibCustomGlow's glows trace a rectangle instead, so an icon under one
---keeps its square corners.
---@param layer table
---@param options IconLayerOptions
local function ApplyIconCorners(layer, options)
	-- Portrait icons carry a round mask and a swipe to match; leave both alone.
	if layer.CustomShape then
		return
	end

	-- The border ring has the same rounded inner corners as the overlays, so it rounds the icon
	-- too. An LCG glow does not, so only the texture-based ones count here.
	local rounded = (options.Border or (options.Glow and STATIC_GLOW_FIELDS[ResolveGlowType()]))
		and true or false

	if layer.CornersRounded == rounded then
		return
	end

	layer.CornersRounded = rounded
	layer.CornerMask = glowStyles:SetIconCorners(layer.Frame, layer.Icon, layer.Cooldown, layer.CornerMask, rounded)
end

---How far a run of icons reaches, where the first of them may be drawn larger than the rest.
---@param count number
---@param firstSize number
---@param size number
---@param spacing number
---@return number
local function RunLength(count, firstSize, size, spacing)
	return firstSize + (count - 1) * (size + spacing)
end

---Where one icon's centre sits in such a run, measured from the edge the run starts at.
---@param index number 0-based place in the run
---@param firstSize number
---@param size number
---@param spacing number
---@return number
local function RunOffset(index, firstSize, size, spacing)
	if index == 0 then
		return firstSize / 2
	end

	return firstSize + spacing + (index - 1) * (size + spacing) + size / 2
end

---@param layer table
---@param size number
local function ApplyLayerSize(layer, size)
	if layer.Frame then
		-- Inside nameplate hierarchies GetWidth() can return a secret number, so remember the
		-- size we set ourselves for anything that needs to do math on it.
		layer.Frame.DesiredSize = size
		layer.Frame:SetSize(size, size)
	end

	if layer.Cooldown then
		layer.Cooldown.DesiredIconSize = size
		fontUtil:UpdateCooldownFontSize(layer.Cooldown, size, nil, layer.Cooldown.FontScale or 1.0)
	end

	if layer.ChargeText then
		UpdateChargeTextFontSize(layer.ChargeText, size, layer.Cooldown and layer.Cooldown.FontScale)
	end
end

---A slot drawn larger than the container's own icon size has to take its countdown text up with
---it.
---@param slot table
---@param size number
local function ApplySlotSize(slot, size)
	if not slot.Frame or slot.DrawnSize == size then
		return
	end

	slot.DrawnSize = size
	slot.Frame:SetSize(size, size)

	if slot.Container then
		ApplyLayerSize(slot.Container, size)
	end

	if slot.ExtraLayers then
		for _, extra in ipairs(slot.ExtraLayers) do
			if extra then
				ApplyLayerSize(extra, size)
			end
		end
	end
end

---@param parent table frame to attach to
---@param count number of slots to create (default: 3)
---@param size number of each icon slot (default: 20)
---@param spacing number between slots (default: 2)
---@param groupName string? Masque sub-group name (e.g. "Crowd Control", "Trinkets"). Omit to skip Masque.
---@param noBorder boolean? When true, skips creating the border texture on each layer.
---@param moduleName string? Overrides the MiniCCModule label set on Frame. Defaults to groupName.
---@return IconSlotContainer
function M:New(parent, count, size, spacing, groupName, noBorder, moduleName)
	local instance = setmetatable({}, M)

	count = count or 3
	size = size or 20
	spacing = spacing or 2

	instance.Frame = CreateFrame("Frame", NextFrameName("Container"), parent)
	instance.Frame:SetIgnoreParentScale(true)
	instance.Slots = {}
	instance.Count = 0
	instance.Size = size
	instance.Spacing = spacing
	instance.NumRows = nil
	instance.RowAlignment = nil
	instance.InvertLayout = false
	instance.Columns = nil
	instance.LeadScale = nil
	instance.GrowDown = false
	instance.GrowUp = false
	instance.NoBorder = noBorder or false
	instance.Frame.MiniCCModule = moduleName or nil
	instance.MasqueGroup = Masque and groupName and Masque:Group("MiniAuras", groupName) or nil

	instance:SetCount(count)

	return instance
end

function M:Layout()
	local n = 0
	for i = 1, self.Count do
		if self.Slots[i] and self.Slots[i].IsUsed then
			n = n + 1
			layoutScratch[n] = i
		end
	end

	-- The current size, row settings and used slot indices. When none of them moved the visual
	-- result would be identical, so every SetPoint/SetSize/Show/Hide below can be skipped.
	-- Vertical layout covers both grow-down and grow-up, which differ only in icon order: grow-up
	-- puts slot 1 at the bottom, nearest the anchor.
	local vertical = self.GrowDown or self.GrowUp
	local numRows = (not vertical and self.NumRows and self.NumRows > 1) and self.NumRows or nil
	local columnsPerRow = (vertical and self.Columns and self.Columns > 1) and self.Columns or nil
	local leadScale = vertical and self.LeadScale or nil
	local verticalTag = self.GrowUp and "U" or (self.GrowDown and "D" or "H")

	layoutStamp:Begin(self)
	layoutStamp:Add(self.Size)
	layoutStamp:Add(numRows or 1)
	layoutStamp:Add(self.RowAlignment or "C")
	layoutStamp:Add(self.OverflowRowAlignment or "C")
	layoutStamp:Add(self.InvertLayout == true)
	layoutStamp:Add(verticalTag)
	layoutStamp:Add(columnsPerRow or 1)
	layoutStamp:Add(leadScale or 1)

	for i = 1, n do
		layoutStamp:Add(layoutScratch[i])
	end

	local generation = layoutStamp:Commit()

	if self.LayoutGeneration == generation then
		return
	end

	self.LayoutGeneration = generation

	-- Trim stale entries left over from a previous call with more slots
	for i = n + 1, #layoutScratch do
		layoutScratch[i] = nil
	end

	local usedCount = n

	if usedCount == 0 then
		self.Frame:SetSize(self.Size, self.Size)
	elseif numRows then
		-- Multi-row layout: divide active icons across the requested number of rows
		local iconsPerRow = math.max(1, math.ceil(usedCount / numRows))
		local actualRows = math.ceil(usedCount / iconsPerRow)
		local rowWidth = iconsPerRow * self.Size + (iconsPerRow - 1) * self.Spacing
		local totalHeight = actualRows * self.Size + (actualRows - 1) * self.Spacing
		self.Frame:SetSize(rowWidth, totalHeight)
		self.Frame:SetAlpha(1)

		local row1Alignment = self.RowAlignment or "CENTER"
		local overflowAlignment = self.OverflowRowAlignment or row1Alignment

		for displayIndex = 1, usedCount do
			local slot = self.Slots[layoutScratch[displayIndex]]
			local rowIndex = math.floor((displayIndex - 1) / iconsPerRow) -- 0-based
			-- When InvertLayout is set, reverse the column order so slot 1 lands at the
			-- rightmost position of every row instead of the leftmost.
			local rawCol = (displayIndex - 1) % iconsPerRow -- 0-based
			local colIndex = self.InvertLayout and (iconsPerRow - 1 - rawCol) or rawCol
			local rowIcons = (rowIndex == actualRows - 1) and (usedCount - (actualRows - 1) * iconsPerRow) or iconsPerRow

			local x
			if self.InvertLayout then
				-- The column reversal already fills right to left, so partial rows are right-aligned
				-- without an extra shift.
				x = colIndex * (self.Size + self.Spacing) - (rowWidth / 2) + (self.Size / 2)
			else
				local alignment = rowIndex == 0 and row1Alignment or overflowAlignment
				if alignment == "LEFT" then
					x = colIndex * (self.Size + self.Spacing) - (rowWidth / 2) + (self.Size / 2)
				elseif alignment == "RIGHT" then
					local shift = (iconsPerRow - rowIcons) * (self.Size + self.Spacing)
					x = colIndex * (self.Size + self.Spacing) - (rowWidth / 2) + (self.Size / 2) + shift
				else -- CENTER
					local thisRowWidth = rowIcons * self.Size + (rowIcons - 1) * self.Spacing
					x = colIndex * (self.Size + self.Spacing) - (thisRowWidth / 2) + (self.Size / 2)
				end
			end
			local y = (totalHeight / 2) - (self.Size / 2) - rowIndex * (self.Size + self.Spacing)

			slot.Frame:ClearAllPoints()
			slot.Frame:SetPoint("CENTER", self.Frame, "CENTER", x, y)
			ApplySlotSize(slot, self.Size)
			slot.Frame:Show()
		end
	elseif vertical then
		-- A single column is this same layout one column wide, so both come through here.
		local cols = columnsPerRow or 1
		local actualRows = math.ceil(usedCount / cols)
		local leadSize = leadScale and self.Size * leadScale or self.Size
		local rowWidth = RunLength(cols, self.Size, self.Size, self.Spacing)
		-- The lead icon reaches past a plain row, and every row after it still hangs off the same
		-- edge, so the frame takes the wider of the two.
		local frameWidth = math.max(rowWidth, RunLength(cols, leadSize, self.Size, self.Spacing))
		local totalHeight = RunLength(actualRows, leadSize, self.Size, self.Spacing)
		self.Frame:SetSize(frameWidth, totalHeight)
		self.Frame:SetAlpha(1)

		for displayIndex = 1, usedCount do
			local slot = self.Slots[layoutScratch[displayIndex]]
			local rowIndex = math.floor((displayIndex - 1) / cols) -- 0-based
			local colIndex = (displayIndex - 1) % cols             -- 0-based
			local rowLead = rowIndex == 0 and leadSize or self.Size
			local size = (rowIndex == 0 and colIndex == 0) and leadSize or self.Size
			-- Measured from the edge the row grows from, so a part-full row hugs that edge and a
			-- lead icon wider than the rest pushes its own row along without moving the others.
			local across = RunOffset(colIndex, rowLead, self.Size, self.Spacing)
			-- The live row hangs every icon off the edge it grows from, so one standing beside a
			-- larger lead drops to that edge instead of centring on it.
			local down = RunOffset(rowIndex, leadSize, self.Size, self.Spacing) - (rowLead - size) / 2
			local x = self.InvertLayout and (frameWidth / 2 - across) or (across - frameWidth / 2)
			local y

			if self.GrowUp then
				y = -(totalHeight / 2) + down
			else
				y = (totalHeight / 2) - down
			end

			slot.Frame:ClearAllPoints()
			slot.Frame:SetPoint("CENTER", self.Frame, "CENTER", x, y)
			ApplySlotSize(slot, size)
			slot.Frame:Show()
		end
	else
		local totalWidth = usedCount * self.Size + (usedCount - 1) * self.Spacing
		self.Frame:SetSize(totalWidth, self.Size)
		self.Frame:SetAlpha(1)

		for displayIndex = 1, usedCount do
			local slot = self.Slots[layoutScratch[displayIndex]]
			-- When InvertLayout is set, mirror the position so slot 1 is rightmost.
			local effIndex = self.InvertLayout and (usedCount - displayIndex + 1) or displayIndex
			local x = (effIndex - 1) * (self.Size + self.Spacing) - (totalWidth / 2) + (self.Size / 2)
			slot.Frame:ClearAllPoints()
			slot.Frame:SetPoint("CENTER", self.Frame, "CENTER", x, 0)
			ApplySlotSize(slot, self.Size)
			slot.Frame:Show()
		end
	end

	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot and not slot.IsUsed then
			slot.Frame:Hide()
		end
	end

	-- Always hide inactive pooled slots
	for i = self.Count + 1, #self.Slots do
		local slot = self.Slots[i]
		if slot then
			slot.IsUsed = false
			slot.Frame:Hide()
		end
	end

	-- Re-skin after a layout, or Masque borders come out randomly oversized.
	ScheduleMasqueReSkin(self)
end

---@param newSpacing number
function M:SetSpacing(newSpacing)
	---@diagnostic disable-next-line: cast-local-type
	newSpacing = tonumber(newSpacing)
	if not newSpacing or newSpacing < 0 then
		return
	end
	if self.Spacing == newSpacing then
		return
	end

	self.Spacing = newSpacing
	self.LayoutGeneration = nil
	self:Layout()
end

---Sets the number of rows to distribute icons across, and the alignment of partial rows.
---Rows 2+ automatically use the opposite alignment (LEFT<->RIGHT) so that overflow icons
---hug the edge the container grows from.
---@param numRows number? 1 or nil means single row (no multi-row layout)
---@param alignment string? "LEFT", "RIGHT", or "CENTER" (default)
---@param invertLayout boolean? When true, slot 1 is placed at the rightmost position and the layout fills right-to-left. Use this instead of reversing the slots array so multi-row behaves consistently.
function M:SetRows(numRows, alignment, invertLayout)
	numRows = (numRows and numRows > 1) and math.floor(numRows) or nil
	alignment = alignment or "CENTER"
	local overflowAlignment
	if alignment == "LEFT" then
		overflowAlignment = "RIGHT"
	elseif alignment == "RIGHT" then
		overflowAlignment = "LEFT"
	else
		overflowAlignment = alignment
	end
	invertLayout = invertLayout and true or false
	if self.NumRows == numRows and self.RowAlignment == alignment and self.OverflowRowAlignment == overflowAlignment and self.InvertLayout == invertLayout then
		return
	end
	self.NumRows = numRows
	self.RowAlignment = alignment
	self.OverflowRowAlignment = overflowAlignment
	self.InvertLayout = invertLayout
	self.LayoutGeneration = nil
	self:Layout()
end

---Switches the container to a vertical layout, growing downward (slot 1 at the top).
---When enabled, multi-row settings are ignored and grow-up is cleared (mutually exclusive).
---@param enabled boolean
function M:SetGrowDown(enabled)
	enabled = enabled and true or false
	local newGrowUp = enabled and false or self.GrowUp
	if self.GrowDown == enabled and self.GrowUp == newGrowUp then
		return
	end
	self.GrowDown = enabled
	self.GrowUp = newGrowUp
	self.LayoutGeneration = nil
	self:Layout()
end

---Switches the container to a vertical layout, growing upward (slot 1 at the bottom, nearest
---the anchor).  When enabled, multi-row settings are ignored and grow-down is cleared.
---@param enabled boolean
function M:SetGrowUp(enabled)
	enabled = enabled and true or false
	local newGrowDown = enabled and false or self.GrowDown
	if self.GrowUp == enabled and self.GrowDown == newGrowDown then
		return
	end
	self.GrowUp = enabled
	self.GrowDown = newGrowDown
	self.LayoutGeneration = nil
	self:Layout()
end

---Sets the maximum number of icons per row when growing up or down.
---A value of 1 or nil reverts to a single column.
---@param n number? Maximum icons per row; nil or 1 means single column
---@param invertLayout boolean? When true, slot 1 is placed at the rightmost column and every row fills right-to-left.
function M:SetColumns(n, invertLayout)
	n = (n and n > 1) and math.floor(n) or nil
	invertLayout = invertLayout and true or false
	if self.Columns == n and self.InvertLayout == invertLayout then
		return
	end
	self.Columns = n
	self.InvertLayout = invertLayout
	self.LayoutGeneration = nil
	self:Layout()
end

---Draws the first icon at a multiple of the container's icon size, the way a live row leads with
---a category worth more than what follows it. Vertical layouts only.
---@param scale number? nil or 1 draws the whole row at one size
function M:SetLeadScale(scale)
	---@diagnostic disable-next-line: cast-local-type
	scale = tonumber(scale)
	-- Under 1 the lead icon's row would be shorter than the icons standing in it, and the rows
	-- behind it would be laid over the top.
	scale = (scale and scale > 1) and scale or nil
	if self.LeadScale == scale then
		return
	end

	self.LeadScale = scale
	self.LayoutGeneration = nil
	self:Layout()
end

---@param newSize number
function M:SetIconSize(newSize)
	---@diagnostic disable-next-line: cast-local-type
	newSize = tonumber(newSize)
	if not newSize or newSize <= 0 then
		return
	end
	if self.Size == newSize then
		return
	end

	self.Size = newSize

	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot then
			ApplySlotSize(slot, self.Size)
		end
	end

	-- Re-apply the Masque skin at the new size, debounced per group.
	ScheduleMasqueReSkin(self)

	self:Layout()
end

---@param newCount number of slots to maintain
function M:SetCount(newCount)
	newCount = math.max(0, newCount or 0)
	if newCount == self.Count then
		return
	end

	-- If shrinking, disable anything beyond newCount (pooled slots)
	if newCount < self.Count then
		for i = newCount + 1, #self.Slots do
			local slot = self.Slots[i]
			if slot then
				slot.IsUsed = false
				self:ClearSlot(i)
				slot.Frame:Hide()
			end
		end
	end

	self.Count = newCount

	for i = #self.Slots + 1, newCount do
		local slotFrame = CreateFrame(self.MasqueGroup and "Button" or "Frame", NextFrameName("Slot"), self.Frame)
		slotFrame:SetSize(self.Size, self.Size)
		slotFrame:EnableMouse(false)
		-- Composite the slot's icon/cooldown/border/glow regions in a single render pass. Per slot
		-- rather than per bar, so an animating cooldown swipe only re-composites its own icon.
		slotFrame:SetFlattensRenderLayers(true)

		self.Slots[i] = {
			Frame = slotFrame,
			Container = nil,
			ExtraLayers = {},
			IsUsed = false,
		}
	end

	self:Layout()
end

---Sets an icon on a specific slot, optionally on a stacked layer above it.
---@param slotIndex number Slot index (1-based)
---@param options IconLayerOptions Options for the layer
---@class IconLayerOptions
---@field Texture string Texture path/ID
---@field DurationObject table? DurationObject from C_DurationUtil.CreateDuration or C_UnitAuras.GetAuraDuration
---@field Alpha number|boolean? Control alpha: number sets it directly, boolean uses SetAlphaFromBoolean
---@field Glow boolean? Whether to show glow effect (requires LibCustomGlow)
---@field ReverseCooldown boolean? Whether to reverse the cooldown animation
---@field HideIcon boolean? Drop the icon art, leaving the slot as its countdown alone
---@field HideSwipe boolean? Drop the cooldown swipe, whatever the global setting says
---@field HideNumbers boolean? Drop the countdown text
---@field ShowNumbers boolean? Keep the countdown text, whatever the global setting says
---@field Color table? RGBA color table {r, g, b, a} for glow and border color
---@field Border boolean? Show the coloured border even while a glow is active
---@field FontScale number? Font scale multiplier for cooldown text (default: 1.0)
---@field Layer number? Which layer to render on (1 = base, 2+ = stacked above; default: 1)
---@field SpellId number? Spell ID for tooltip on hover
---@field ChargeText string? Stand-in charge or stack count text
---@field ChargeTextCenter boolean? Centre the charge text where the countdown sits, at its size,
---instead of in the corner
---@field TextColor table? {r, g, b} for the countdown and charge text. Setting one replaces the
---global colour-by-time countdown (white included), so pass nil rather than white for the
---default colouring
function M:SetSlot(slotIndex, options)
	if slotIndex < 1 or slotIndex > self.Count then
		return
	end

	if not options.Texture and not options.HideIcon then
		return
	end

	local slot = self.Slots[slotIndex]

	if not slot then
		return
	end

	if not slot.IsUsed then
		slot.IsUsed = true
		self:Layout()
	end

	slot.SpellId = options.SpellId
	if options.SpellId then
		if not slot.MouseEnabled then
			slot.MouseEnabled = true
			slot.Frame:EnableMouse(true)
			slot.Frame:SetScript("OnEnter", function(f)
				if slot.SpellId then
					GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
					GameTooltip:SetSpellByID(slot.SpellId)
					GameTooltip:Show()
				end
			end)
			slot.Frame:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
		end
	elseif slot.MouseEnabled then
		slot.MouseEnabled = false
		slot.Frame:EnableMouse(false)
		slot.Frame:SetScript("OnEnter", nil)
		slot.Frame:SetScript("OnLeave", nil)
	end

	-- The size this slot is drawn at, which is larger than the container's own for one leading
	-- a row.
	local iconSize = slot.DrawnSize or self.Size
	local layerIndex = options.Layer or 1
	local layer

	if layerIndex <= 1 then
		layer = EnsureContainer(slot, iconSize, self.MasqueGroup, self.NoBorder)
		-- Setting the base layer means this slot is now a single icon. Clear any stacked extra
		-- layers left from a prior stacked render (e.g. the important slot relocating to a new
		-- index), otherwise those old layers linger visible underneath the new icon.
		if slot.ExtraLayers then
			for _, el in ipairs(slot.ExtraLayers) do
				if el then
					ClearLayerData(el, el.Frame)
				end
			end
		end
	else
		layer = EnsureExtraLayer(slot, layerIndex, iconSize)
	end

	local db = GetDb()
	layer.Icon:SetTexture(not options.HideIcon and options.Texture or nil)
	layer.Cooldown:SetReverse(options.ReverseCooldown)
	layer.Cooldown:SetHideCountdownNumbers(not options.ShowNumbers
		and (options.HideNumbers == true or (db and db.DisableNumbers) == true))
	if layer.Cooldown.SetCountdownMillisecondsThreshold then
		layer.Cooldown:SetCountdownMillisecondsThreshold(options.ShowMilliseconds and (db and db.MillisecondsThreshold or 5) or 0)
	end

	if options.DurationObject then
		layer.Cooldown:SetCooldownFromDurationObject(options.DurationObject)
		layer.Cooldown:SetDrawSwipe(options.HideSwipe ~= true and not (db and db.DisableSwipe))

		-- A slot with its own text colour never registers for the timed colouring: the fixed
		-- colour replaces it, whatever the global setting says. Matches StyleCountdown, where a
		-- set TextColor takes the countdown off the ramp.
		if options.TextColor then
			ResetCountdownColor(layer.Cooldown)
			ApplyStaticCountdownColor(layer.Cooldown, options.TextColor)
		else
			RegisterCountdownColor(layer.Cooldown, options.DurationObject)
		end
	else
		layer.Cooldown:Clear()
		layer.Cooldown:SetDrawSwipe(false)
		ResetCountdownColor(layer.Cooldown)
	end
	-- The frame hides itself when the duration is zero or expired, so IsShown() only answers the
	-- "on cooldown" question once the cooldown has been set.
	layer.Icon:SetDesaturated(options.Desaturate and layer.Cooldown:IsShown() or false)

	if options.ChargeText then
		if not layer.ChargeText then
			local overlay = CreateFrame("Frame", nil, layer.Frame)
			overlay:SetAllPoints(layer.Frame)
			overlay:SetFrameLevel(layer.Cooldown:GetFrameLevel() + 1)
			layer.ChargeText = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
			layer.ChargeText:SetPoint("BOTTOMRIGHT", layer.Frame, "BOTTOMRIGHT", -3, 1)
			layer.ChargeTextCentered = false
			-- The template face, kept so the centred stand-in can be put back in the corner state.
			local face, _, flags = layer.ChargeText:GetFont()
			layer.ChargeTextFace, layer.ChargeTextFlags = face, flags
		end

		-- Centred the text stands in for the countdown, so it takes that text's spot, face and
		-- size rather than the corner's, matching what the live icons draw.
		local centered = options.ChargeTextCenter == true

		if layer.ChargeTextCentered ~= centered then
			layer.ChargeTextCentered = centered
			layer.ChargeText:ClearAllPoints()

			if centered then
				layer.ChargeText:SetPoint("CENTER", layer.Frame, "CENTER", 0, 0)
			else
				layer.ChargeText:SetPoint("BOTTOMRIGHT", layer.Frame, "BOTTOMRIGHT", -3, 1)

				if layer.ChargeTextFace then
					local _, currentSize = layer.ChargeText:GetFont()

					fontUtil:Apply(layer.ChargeText, currentSize or 10, layer.ChargeTextFlags,
						layer.ChargeTextFace)
				end
			end
		end

		local chargeScale = options.FontScale or layer.Cooldown.FontScale

		if centered then
			local cdText = GetCooldownText(layer.Cooldown)
			local face, _, flags

			if cdText then
				face, _, flags = cdText:GetFont()
			end

			if face then
				fontUtil:Apply(layer.ChargeText,
					math.max(1, math.floor(iconSize * 0.4 * (chargeScale or 1.0))), flags,
					fontUtil:BaseFace(cdText))
			else
				fontUtil:UpdateFontSize(layer.ChargeText, iconSize, nil, chargeScale)
			end
		else
			UpdateChargeTextFontSize(layer.ChargeText, iconSize, chargeScale)
		end

		local textColor = options.TextColor
		layer.ChargeText:SetTextColor(
			textColor and textColor.r or 1,
			textColor and textColor.g or 1,
			textColor and textColor.b or 1
		)
		layer.ChargeText:SetText(options.ChargeText)
		layer.ChargeText:Show()
	elseif layer.ChargeText then
		layer.ChargeText:Hide()
	end

	ApplyAlpha(layer.Frame, options.Alpha)

	-- The coloured border normally gives way to an active glow so the two rings do not double up.
	-- Border forces both, for icons standing in for aura buttons: the engine draws border and glow
	-- together on those, and a preview rendered here must not look different from live.
	if options.Color and layer.Border and (options.Border == true or not options.Glow) then
		layer.Border:SetVertexColor(
			options.Color.r or 1,
			options.Color.g or 1,
			options.Color.b or 1,
			options.Color.a or 1
		)
		layer.Border:Show()
	elseif layer.Border then
		layer.Border:Hide()
	end

	if options.FontScale then
		layer.Cooldown.FontScale = options.FontScale
	end

	-- Every slot, not only the ones handed a scale: the countdown's face can change under a
	-- scale that has not moved, and a caller that never passes one would keep the old face for
	-- as long as the icon lives. Created with a scale of 1, so there is always one to size by.
	fontUtil:UpdateCooldownFontSize(layer.Cooldown, iconSize, nil, layer.Cooldown.FontScale)

	UpdateGlow(layer.Frame, options)
	ApplyIconCorners(layer, options)
end

---@param slotIndex number Slot index
function M:ClearSlot(slotIndex)
	if slotIndex < 1 or slotIndex > #self.Slots then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot or not slot.Container then
		return
	end

	slot.SpellId = nil
	ClearLayerData(slot.Container, slot.Container.Frame)

	if slot.ExtraLayers then
		for _, el in ipairs(slot.ExtraLayers) do
			if el then
				ClearLayerData(el, el.Frame)
			end
		end
	end

	-- Stop any slot-level glow on slot.Frame, so none lingers when the slot is freed and reused.
	StopLCGGlowsExcept(slot.Frame, nil)
	HideStaticGlowsExcept(slot.Frame, nil)
end

---Marks a slot as unused. The other used slots shift up to fill the gap.
---@param slotIndex number Slot index
function M:SetSlotUnused(slotIndex)
	if slotIndex < 1 or slotIndex > self.Count then
		return
	end

	local slot = self.Slots[slotIndex]
	if not slot then
		return
	end

	if slot.IsUsed then
		slot.IsUsed = false
		self:ClearSlot(slotIndex)
		self:Layout()
	end
end

---@return number Count of used slots
function M:GetUsedSlotCount()
	local count = 0
	for i = 1, self.Count do
		if self.Slots[i] and self.Slots[i].IsUsed then
			count = count + 1
		end
	end
	return count
end

---Resets every slot in the active range to unused.
function M:ResetAllSlots()
	local needsLayout = false
	for i = 1, self.Count do
		local slot = self.Slots[i]
		if slot and slot.IsUsed then
			slot.IsUsed = false
			self:ClearSlot(i)
			needsLayout = true
		end
	end
	if needsLayout then
		self:Layout()
	end
end

---@class IconLayer
---@field Frame table
---@field Icon table
---@field Cooldown table
---@field Border table

---@class IconSlot
---@field Frame table
---@field Container IconLayer?
---@field ExtraLayers IconLayer[]
---@field IsUsed boolean
---@field DrawnSize number?

---@class IconSlotContainer
---@field Frame table
---@field MasqueGroup table?
---@field Slots IconSlot[]
---@field Count number
---@field Size number
---@field Spacing number
---@field NumRows number?
---@field RowAlignment string?
---@field OverflowRowAlignment string?
---@field InvertLayout boolean
---@field Columns number?
---@field LeadScale number?
---@field GrowDown boolean
---@field GrowUp boolean
---@field NoBorder boolean
---@field SetCount fun(self: IconSlotContainer, count: number)
---@field SetSpacing fun(self: IconSlotContainer, spacing: number)
---@field SetRows fun(self: IconSlotContainer, iconsPerRow: number?, alignment: string?, invertLayout: boolean?)
---@field SetGrowDown fun(self: IconSlotContainer, enabled: boolean)
---@field SetGrowUp fun(self: IconSlotContainer, enabled: boolean)
---@field SetColumns fun(self: IconSlotContainer, n: number?, invertLayout: boolean?)
---@field SetLeadScale fun(self: IconSlotContainer, scale: number?)
---@field SetIconSize fun(self: IconSlotContainer, size: number)
---@field SetSlot fun(self: IconSlotContainer, slotIndex: number, options: IconLayerOptions)
---@field ClearSlot fun(self: IconSlotContainer, slotIndex: number)
---@field SetSlotUnused fun(self: IconSlotContainer, slotIndex: number)
---@field GetUsedSlotCount fun(self: IconSlotContainer): number
---@field ResetAllSlots fun(self: IconSlotContainer)

