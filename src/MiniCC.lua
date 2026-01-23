---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local auras = addon.Auras
local scheduler = addon.Scheduler
local config = addon.Config
local eventsFrame
---@type { table: table }
local headers = {}
---@type { table: table }
local testHeaders = {}
local testPartyFrames = {}
local testMode = false
local maxTestFrames = 3
---@type Db
local db
---@type Db
local dbDefaults = config.DbDefaults
local testSpells = {
	-- Kidney Shot
	408,
}

local function IsArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "arena"
end

local function GetDefaultAnchor(i)
	local party = _G["CompactPartyFrameMember" .. i]

	if party and party:IsVisible() then
		return party
	end

	local raid = _G["CompactRaidFrame" .. i]

	if raid and raid:IsVisible() then
		return raid
	end

	-- default to party, even when invisible
	return party
end

local function GetOverrideAnchor(i)
	local anchor = db["Anchor" .. i]

	if not anchor then
		return nil
	end

	local frame = _G[anchor]

	if not frame then
		mini:Notify("Bad anchor '%s' for party%d.", anchor, i)
		return nil
	end

	return frame
end

local function GetAnchor(i)
	local anchor = GetOverrideAnchor(i)

	if anchor and anchor:IsVisible() then
		return anchor
	end

	return GetDefaultAnchor(i)
end

local function AnchorHeader(header, anchor)
	header:ClearAllPoints()

	if db.SimpleMode.Enabled then
		header:SetPoint("CENTER", anchor, "CENTER", db.SimpleMode.Offset.X, db.SimpleMode.Offset.Y)
	else
		header:SetPoint(
			db.AdvancedMode.Point,
			anchor,
			db.AdvancedMode.RelativePoint,
			db.AdvancedMode.Offset.X,
			db.AdvancedMode.Offset.Y
		)
	end
end

local function ShowHideHeader(header, anchor)
	if db.ArenaOnly then
		if IsArena() and anchor:IsVisible() then
			header:Show()
		else
			header:Hide()
		end

		return
	end

	if anchor:IsVisible() then
		header:Show()
	else
		header:Hide()
	end
end

local function EnsureHeader(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")

	if not unit then
		return nil
	end

	local header = headers[anchor]

	if not header then
		header = auras:CreateHeader(unit, db.Icons)
		headers[anchor] = header
	else
		auras:UpdateHeader(header, unit, db.Icons)
	end

	AnchorHeader(header, anchor)
	ShowHideHeader(header, anchor)

	return header
end

local function EnsureCustomHeaders()
	-- for any custom anchors the user may have configured
	local index = 1
	local anchor = GetOverrideAnchor(index)

	while anchor do
		EnsureHeader(anchor)
		index = index + 1
		anchor = GetOverrideAnchor(index)
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
	for i = 1, maxTestFrames do
		local frame = testPartyFrames[i]

		if not frame then
			testPartyFrames[i] = CreateTestFrame(i)
			frame = testPartyFrames[i]
		end

		local anchor = GetAnchor(i)
		frame:ClearAllPoints()

		if anchor and anchor:GetWidth() > 0 and anchor:GetHeight() > 0 then
			-- sit directly on top of Blizzard frames
			frame:SetAllPoints(anchor)

			-- try to keep it above the real frame
			frame:SetFrameStrata(anchor:GetFrameStrata() or "DIALOG")
			frame:SetFrameLevel((anchor:GetFrameLevel() or 0) + 10)
		else
			frame:SetSize(144, 72)
			frame:SetPoint("CENTER", UIParent, "CENTER", 300, -i * frame:GetHeight())
		end
	end
end

local function UpdateTestHeader(frame)
	local cols = #testSpells
	local rows = 1
	local size = tonumber(db.Icons.Size) or dbDefaults.Icons.Size
	local padX = 0
	local padY = 0
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
		local texture = C_Spell.GetSpellTexture(testSpells[i])
		btn.icon:SetTexture(texture)

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

local function EnsureTestHeader(anchor)
	local header = testHeaders[anchor]

	if not header then
		header = CreateFrame("Frame", nil, UIParent)
		testHeaders[anchor] = header
	end

	UpdateTestHeader(header)

	return header
end

local function RealMode()
	for anchor, header in pairs(headers) do
		local unit = header:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

		if unit then
			-- refresh options
			auras:UpdateHeader(header, unit, db.Icons)
		end

		-- refresh anchor
		AnchorHeader(header, anchor)

		-- refresh visibility
		ShowHideHeader(header, anchor)
	end

	for _, testHeader in pairs(testHeaders) do
		testHeader:Hide()
	end

	for _, testPartyFrame in ipairs(testPartyFrames) do
		testPartyFrame:Hide()
	end
end

local function TestMode()
	-- hide the real headers
	for _, header in pairs(headers) do
		header:Hide()
	end

	-- try to show on real frames first
	local anyRealShown = false
	for anchor, _ in pairs(headers) do
		local testHeader = EnsureTestHeader(anchor)

		if anchor and anchor:IsVisible() then
			anyRealShown = true

			AnchorHeader(testHeader, anchor)

			testHeader:Show()
		end
	end

	if anyRealShown then
		-- hide our test frames if any real exist
		for i = 1, #testPartyFrames do
			local testPartyFrame = testPartyFrames[i]
			testPartyFrame:Hide()
		end

		return
	end

	-- no real frames, show our test frames
	EnsureTestPartyFrames()

	local anchor, testHeader = next(testHeaders)
	for i = 1, #testPartyFrames do
		if testHeader then
			local testPartyFrame = testPartyFrames[i]

			AnchorHeader(testHeader, testPartyFrame)

			testHeader:Show()
			testPartyFrame:Show()
			anchor, testHeader = next(testHeaders, anchor)
		end
	end
end

local function IsFriendlyCuf(frame)
	local name = frame:GetName()

	if not name then
		return false
	end

	return string.find(name, "CompactParty") ~= nil or string.find(name, "CompactRaid") ~= nil
end

local function OnCufUpdateVisible(frame)
	local header = headers[frame]

	if not header then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		ShowHideHeader(header, frame)
	end)
end

local function OnCufLoad(frame)
	if not frame or not IsFriendlyCuf(frame) then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		EnsureHeader(frame)
	end)
end

local function OnCufSetUnit(frame, unit)
	if not frame or not IsFriendlyCuf(frame) then
		return
	end

	scheduler:RunWhenCombatEnds(function()
		EnsureHeader(frame, unit)
	end)
end

local function OnEvent(_, event)
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
	addon.Scheduler:Init()

	db = mini:GetSavedVars()

	EnsureCustomHeaders()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
end

function addon:Refresh()
	if InCombatLockdown() then
		scheduler:RunWhenCombatEnds(function()
			addon:Refresh()
		end, "Refresh")
		return
	end

	EnsureCustomHeaders()

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

if CompactUnitFrame_SetUnit then
	hooksecurefunc("CompactUnitFrame_SetUnit", OnCufSetUnit)
end

if CompactUnitFrame_OnLoad then
	hooksecurefunc("CompactUnitFrame_OnLoad", OnCufLoad)
end

if CompactUnitFrame_UpdateVisible then
	hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
end

---@class Addon
---@field Auras AurasModule
---@field Framework MiniFramework
---@field Scheduler Scheduler
---@field Config Config
---@field Refresh fun(self: table)
---@field ToggleTest fun(self: table)
