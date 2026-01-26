---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local frames = addon.Frames
local auras = addon.Auras
local scheduler = addon.Scheduler
local config = addon.Config
local eventsFrame
---@type { table: table }
local headers = {}
local testContainer
---@type { table: table }
local testHeaders = {}
local testPartyFrames = {}
local testMode = false
local maxTestFrames = 3
local LCG = LibStub and LibStub("LibCustomGlow-1.0", false)
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

local function IsPet(unit)
	if UnitIsUnit(unit, "pet") then
		return true
	end

	if UnitIsOtherPlayersPet(unit) then
		return true
	end

	return false
end

local function GetAnchors(i, visibleOnly)
	local anchors = {}
	local danders = frames:GetDandersFrames(i)

	if danders and (danders:IsVisible() or not visibleOnly) then
		anchors[#anchors + 1] = danders
	end

	local grid2 = frames:GetGrid2Frame(i)

	if grid2 and (grid2:IsVisible() or not visibleOnly) then
		anchors[#anchors + 1] = grid2
	end

	local elvui = frames:GetElvUIFrame(i)

	if elvui and (elvui:IsVisible() or not visibleOnly) then
		anchors[#anchors + 1] = elvui
	end

	-- it's possible blizzard are still shown alongside the other addons
	local blizzard = frames:GetBlizzardFrame(i)

	if blizzard and (blizzard:IsVisible() or not visibleOnly) then
		anchors[#anchors + 1] = blizzard
	end

	if i > 0 then
		local anchor = db["Anchor" .. i]

		if anchor and anchor ~= "" then
			local frame = _G[anchor]

			if not frame then
				mini:Notify("Bad anchor%d: '%s'.", i, anchor)
			elseif frame:IsVisible() or not visibleOnly then
				anchors[#anchors + 1] = frame
			end
		end
	end

	return anchors
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

	-- raise above the anchor
	header:SetFrameLevel(anchor:GetFrameLevel() + 1)
	header:SetFrameStrata("HIGH")
end

local function ShowHideHeader(header, anchor, isTest)
	local unit = header:GetAttribute("unit")

	-- unit is an empty string for test headers
	if unit and unit ~= "" then
		if IsPet(unit) then
			header:Hide()
			return
		end

		if not isTest and db.ExcludePlayer and UnitIsUnit(unit, "player") then
			header:Hide()
			return
		end
	end

	if not isTest and db.ArenaOnly and not IsArena() then
		header:Hide()
		return
	end

	-- danders doesn't hide blizzard frames, but rather sets the alpha to 0 using a secret value
	local alpha = anchor:GetAlpha()
	if mini:IsSecret(alpha) and anchor:IsVisible() then
		header:SetAlpha(alpha)
		header:Show()
		return
	end

	if anchor:IsVisible() then
		header:SetAlpha(1)
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
	ShowHideHeader(header, anchor, false)

	return header
end

local function EnsureHeaderss()
	-- for any custom anchors the user may have configured
	-- 0 = player
	-- 1 = party1
	-- 40 = raid40
	for i = 0, MAX_RAID_MEMBERS or 40 do
		local anchors = GetAnchors(i, true)

		if anchors then
			for _, anchor in ipairs(anchors) do
				EnsureHeader(anchor)
			end
		end
	end
end

local function CreateTestFrame(i)
	local frame = CreateFrame("Frame", addonName .. "TestFrame" .. i, testContainer, "BackdropTemplate")

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
	if not testContainer then
		testContainer = CreateFrame("Frame", addonName .. "TestContainer")
		testContainer:SetClampedToScreen(true)
		testContainer:EnableMouse(true)
		testContainer:SetMovable(true)
		testContainer:RegisterForDrag("LeftButton")
		testContainer:SetScript("OnDragStart", function(self)
			self:StartMoving()
		end)
		testContainer:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
		end)
		testContainer:Show()

		local xOffset = -450
		local yOffset = 0

		-- it's too complicated to try and anchor over the top of real frame positions
		-- as with various addons the real frames will be hidden and moved to off screen positions
		-- so just use a fixed position
		testContainer:SetPoint("CENTER", UIParent, "CENTER", xOffset, yOffset)
	end

	local width = 144
	local height = 72
	local padding = 10

	for i = 1, maxTestFrames do
		local frame = testPartyFrames[i]

		if not frame then
			testPartyFrames[i] = CreateTestFrame(i)
			frame = testPartyFrames[i]
		end

		frame:ClearAllPoints()
		frame:SetSize(width, height)
		frame:SetPoint("TOP", testContainer, "TOP", 0, (i - 1) * -frame:GetHeight() - padding)
	end

	testContainer:SetSize(width + padding * 2, height * maxTestFrames + padding * 2)
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

	-- glow icons
	if LCG then
		for _, icon in ipairs(frame.icons) do
			if db.Icons.Glow then
				LCG.ProcGlow_Start(icon, {
					startAnim = false,
				})
			else
				LCG.ProcGlow_Stop(icon)
			end
		end
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
		ShowHideHeader(header, anchor, false)
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

		AnchorHeader(testHeader, anchor)
		ShowHideHeader(testHeader, anchor, true)
		anyRealShown = anyRealShown or testHeader:IsVisible()
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
			testHeader:SetAlpha(1)
			testPartyFrame:Show()

			anchor, testHeader = next(testHeaders, anchor)
		end
	end
end

local function IsFriendlyCuf(frame)
	if frame:IsForbidden() then
		return false
	end

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
		ShowHideHeader(header, frame, false)
	end)
end

local function OnCufSetUnit(frame, unit)
	if not frame or not IsFriendlyCuf(frame) then
		return
	end

	if not unit then
		return
	end

	if IsPet(unit) then
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

	EnsureHeaderss()

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

	EnsureHeaderss()

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

if CompactUnitFrame_UpdateVisible then
	hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
end

---@class Addon
---@field Framework MiniFramework
---@field Auras AurasModule
---@field Frames Frames
---@field Scheduler Scheduler
---@field Config Config
---@field Refresh fun(self: table)
---@field ToggleTest fun(self: table)
