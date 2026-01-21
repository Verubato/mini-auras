local addonName, addon = ...
---@type MiniFramework
local mini = addon.Framework
local eventsFrame
local headers = {}
local testHeaders = {}
local testPartyFrames = {}
local testMode = false
local maxHeaders = 3
local maxAuras = 40
local questionMarkIcon = 134400
local pendingRefresh = false

---@type Db
local dbDefaults = addon.Config.DbDefaults

---@type Db
local db

local testSpells = {
	33786, -- Cyclone
	118, -- Polymorph
	51514, -- Hex
	3355, -- Freezing Trap
	853, -- Hammer of Justice
	408, -- Kidney Shot
}

local function GetSpellIcon(spellID)
	if C_Spell and C_Spell.GetSpellTexture then
		return C_Spell.GetSpellTexture(spellID)
	end

	if not GetSpellInfo then
		return nil
	end

	local _, _, icon = GetSpellInfo(spellID)
	return icon
end

local function GetRealPartyFrame(i)
	local anchor = db["Anchor" .. i]
	local default = _G["CompactPartyFrameMember" .. i]

	if not anchor then
		return default
	end

	local frame = _G[anchor]

	if not frame then
		mini:Notify("Bad anchor '%s' for party%d.", anchor, i)
		return default
	end

	return frame
end

local function OnHeaderEvent(header, event, arg1)
	local unit = header:GetAttribute("unit")
	local filter = header:GetAttribute("filter")

	if not unit then
		return
	end

	if event ~= "UNIT_AURA" then
		return
	end

	if arg1 ~= unit then
		return
	end

	for i = 1, maxAuras do
		local child = header:GetAttribute("child" .. i)

		if not child or not child:IsShown() then
			break
		end

		local icon = child.Icon or child.Texture

		if not icon then
			icon = child:CreateTexture(nil, "ARTWORK")
			child.Texture = icon
		end

		icon:SetAllPoints(child)

		local data = C_UnitAuras.GetAuraDataByIndex(unit, child:GetID(), filter)

		if data then
			-- this will be a secret value in midnight, but it's still usable as a parameter
			icon:SetTexture(data.icon)

			local isCC = C_Spell.IsSpellCrowdControl(data.spellId)
			icon:SetAlphaFromBoolean(isCC)

			if child.Cooldown then
				local start
				local duration
				local durationInfo = C_UnitAuras.GetAuraDuration(unit, data.auraInstanceID)

				if durationInfo then
					start = durationInfo:GetStartTime()
					duration = durationInfo:GetTotalDuration()
				end

				if start and duration then
					child.Cooldown:SetCooldown(start, duration)
					child.Cooldown:Show()
				else
					child.Cooldown:Hide()
					child.Cooldown:SetCooldown(0, 0)
				end

				child.Cooldown:SetAlphaFromBoolean(isCC)
			end
		else
			icon:Hide()
		end
	end
end

local function RefreshHeaderChildSizes(header)
	local iconSize = tonumber(db.Icons.Size) or dbDefaults.Icons.Size

	for i = 1, maxAuras do
		local child = header:GetAttribute("child" .. i)

		if not child then
			-- children are created sequentially; if this one doesn't exist, later ones won't either
			break
		end

		child:SetSize(iconSize, iconSize)

		-- make sure any custom texture stays correct
		if child.Texture then
			child.Texture:SetAllPoints(child)
		end

		-- keep cooldown filling the button
		if child.Cooldown then
			child.Cooldown:ClearAllPoints()
			child.Cooldown:SetAllPoints(child)
		end
	end
end

local function UpdateHeader(header, anchorFrame, unit)
	header:ClearAllPoints()
	header:SetPoint(
		db.Container.Point,
		anchorFrame,
		db.Container.RelativePoint,
		db.Container.Offset.X,
		db.Container.Offset.Y
	)

	local iconSize = tonumber(db.Icons.Size) or dbDefaults.Icons.Size

	header:SetAttribute("unit", unit)
	header:SetAttribute("filter", "HARMFUL|INCLUDE_NAME_PLATE_ONLY")
	-- xoffset of each icon within the container is the width of the icon itself plus some padding
	--header:SetAttribute("xOffset", iconSize + (tonumber(db.IconPaddingX) or dbDefaults.IconPaddingX))
	-- have all icons overlap themselves, and then only the visible on is shown
	-- genius right?
	header:SetAttribute("xOffset", 0)
	header:SetAttribute("yOffset", 0)
	header:SetAttribute("wrapAfter", 40)
	header:SetAttribute("maxWraps", 1)
	-- maintain the same x offset
	header:SetAttribute("wrapXOffset", 0)
	-- wrap the next icons upwards
	header:SetAttribute("wrapYOffset", -iconSize - (tonumber(db.Icons.Padding.Y) or dbDefaults.Icons.Padding.Y))
	header:SetAttribute("x-iconSize", iconSize)

	-- refresh any icon sizes that may have changed
	RefreshHeaderChildSizes(header)

	header:SetShown(not testMode)
end

local function CreateSecureHeader(partyFrame, unit, index)
	local header = CreateFrame("Frame", addonName .. "SecureHeader" .. index, UIParent, "SecureAuraHeaderTemplate")

	header:SetAttribute("template", "MiniCCAuraButtonTemplate")
	header:SetAttribute("point", "TOPLEFT")
	header:SetAttribute("unit", unit)
	header:SetAttribute("sortMethod", "TIME")
	header:SetAttribute("sortDirection", "-")
	header:SetAttribute("minWidth", 1)
	header:SetAttribute("minHeight", 1)

	header:SetAttribute(
		"initialConfigFunction",
		[[
			local header = self:GetParent()
			local iconSize = header:GetAttribute("x-iconSize")

			self:SetWidth(iconSize)
			self:SetHeight(iconSize)

			if self.Cooldown then
				self.Cooldown:SetDrawSwipe(true)
				self.Cooldown:SetSwipeColor(0, 0, 0, 0.6)
				self.Cooldown:SetDrawEdge(false)
				self.Cooldown:SetHideCountdownNumbers(false)
			end
		]]
	)

	header:HookScript("OnEvent", OnHeaderEvent)

	UpdateHeader(header, partyFrame, unit)

	return header
end

local function EnsureHeaders()
	for i = 1, maxHeaders do
		local partyFrame = GetRealPartyFrame(i)
		local header = headers[i]

		if not partyFrame then
			if header then
				header:Hide()
			end
		else
			local unit = partyFrame.unit or ("party" .. i)

			if not header then
				headers[i] = CreateSecureHeader(partyFrame, unit, i)
			else
				UpdateHeader(header, partyFrame, unit)
			end
		end
	end
end

local function CreateTestFrame(i)
	local frame = CreateFrame("Frame", addonName .. "TestFrame" .. i, UIParent, "BackdropTemplate")

	-- same as the max blizzard party frames size
	frame:SetSize(144, 72)

	local _, class = UnitClass("player")
	local colour = RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR

	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})

	frame:SetBackdropColor(colour.r, colour.g, colour.b, 0.9)
	frame:SetBackdropBorderColor(0, 0, 0, 1)

	frame.Text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	frame.Text:SetPoint("CENTER")
	frame.Text:SetText(("party%d"):format(i))
	frame.Text:SetTextColor(1, 1, 1)

	return frame
end

local function EnsureTestPartyFrames()
	for i = 1, maxHeaders do
		local frame = testPartyFrames[i]

		if not frame then
			testPartyFrames[i] = CreateTestFrame(i)
			frame = testPartyFrames[i]
		end

		local real = GetRealPartyFrame(i)
		frame:ClearAllPoints()

		if real and real:GetWidth() > 0 and real:GetHeight() > 0 then
			-- sit directly on top of Blizzard frames
			frame:SetAllPoints(real)

			-- try to keep it above the real frame
			frame:SetFrameStrata(real:GetFrameStrata() or "DIALOG")
			frame:SetFrameLevel((real:GetFrameLevel() or 0) + 10)
		else
			frame:SetSize(144, 72)
			frame:SetPoint("CENTER", UIParent, "CENTER", 300, -i * frame:GetHeight())
		end
	end
end

local function UpdateTestHeader(frame)
	local cols = 3
	local rows = 1
	local size = math.max(1, tonumber(db.Icons.Size) or 20)
	local padX = tonumber(db.Icons.Padding.X) or 0
	local padY = tonumber(db.Icons.Padding.Y) or 0
	local stepX = size + padX
	local stepY = -(size + padY)
	local maxIcons = math.min(#testSpells, cols * rows)

	frame.icons = frame.icons or {}

	for i = 1, maxIcons do
		local btn = frame.icons[i]

		if not btn then
			btn = CreateFrame("Frame", nil, frame)
			btn.icon = btn:CreateTexture(nil, "ARTWORK")
			btn.icon:SetAllPoints()

			frame.icons[i] = btn
		end

		btn:SetSize(size, size)
		btn.icon:SetTexture(GetSpellIcon(testSpells[i]) or questionMarkIcon)

		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)

		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", frame, "TOPLEFT", col * stepX, row * stepY)
		btn:Show()
	end

	-- Hide any extra buttons we previously created but no longer need
	for i = maxIcons + 1, #frame.icons do
		frame.icons[i]:Hide()
	end

	local width = (cols * size) + ((cols - 1) * padX)
	local height = (rows * size) + ((rows - 1) * padY)
	frame:SetSize(width, height)
end

local function EnsureTestHeaders()
	for i = 1, maxHeaders do
		local header = testHeaders[i]

		if not header then
			header = CreateFrame("Frame", nil, UIParent)
			testHeaders[i] = header
		end

		UpdateTestHeader(header)
	end
end

local function QueueRefresh()
	pendingRefresh = true
end

local function RealMode()
	for i = 1, maxHeaders do
		local header = headers[i]
		local testHeader = testHeaders[i]
		local testPartyFrame = testPartyFrames[i]

		header:Show()

		if testHeader then
			testHeader:Hide()
		end

		if testPartyFrame then
			testPartyFrame:Hide()
		end
	end
end

local function TestMode()
	EnsureTestPartyFrames()
	EnsureTestHeaders()

	-- hide the real headers
	for i = 1, maxHeaders do
		local header = headers[i]

		header:Hide()
	end

	-- try to show on real frames first
	local anyRealShown = false

	for i = 1, maxHeaders do
		local testHeader = testHeaders[i]
		local anchor = GetRealPartyFrame(i)

		if anchor and anchor:IsVisible() then
			anyRealShown = true

			testHeader:ClearAllPoints()
			testHeader:SetPoint(
				db.Container.Point,
				anchor,
				db.Container.RelativePoint,
				db.Container.Offset.X,
				db.Container.Offset.Y
			)

			testHeader:Show()
		end
	end

	if anyRealShown then
		-- hide our fake frames if any real exist
		for i = 1, maxHeaders do
			local partyFrame = testPartyFrames[i]
			partyFrame:Hide()
		end
	else
		for i = 1, maxHeaders do
			local testHeader = testHeaders[i]
			local partyFrame = testPartyFrames[i]

			testHeader:ClearAllPoints()
			testHeader:SetPoint(
				db.Container.Point,
				partyFrame,
				db.Container.RelativePoint,
				db.Container.Offset.X,
				db.Container.Offset.Y
			)

			testHeader:Show()
			partyFrame:Show()
		end
	end
end

local function OnEvent(_, event)
	if event == "PLAYER_REGEN_ENABLED" then
		if not pendingRefresh then
			return
		end

		pendingRefresh = false
		addon:Refresh()
		return
	end

	if event == "PLAYER_REGEN_DISABLED" then
		if testMode then
			-- disable test mode as we enter combat
			testMode = false
			addon:Refresh()
		end
	end

	if event == "PLAYER_ENTERING_WORLD" then
		addon:Refresh()
	end

	if event == "GROUP_ROSTER_UPDATE" then
		addon:Refresh()
	end
end

local function OnAddonLoaded()
	addon.Config:Init()

	db = mini:GetSavedVars()

	EnsureHeaders()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
end

function addon:Refresh()
	if InCombatLockdown() then
		QueueRefresh()
		return
	end

	EnsureHeaders()

	if testMode then
		TestMode()
	else
		RealMode()
	end
end

function addon:ToggleTest()
	testMode = not testMode
	addon:Refresh()

	if InCombatLockdown() then
		mini:Notify("Can't test during combat, we'll test once combat drops.")
	end
end

mini:WaitForAddonLoad(OnAddonLoaded)
