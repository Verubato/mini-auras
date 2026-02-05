---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local units = addon.Utils.Units
local capabilities = addon.Capabilities
local headerManager = addon.HeaderManager
local healerCcManager = addon.HealerCcManager
local portraitManager = addon.PortraitManager
local alertsManager = addon.ImportantSpellsManager
local nameplateManager = addon.NameplatesManager
local kickTimerManager = addon.KickTimerManager
local frames = addon.FramesManager
local LCG
---@type Db
local db
local enabled = false
---@type InstanceOptions|nil
local instanceOptions = nil
---@type table<table, table>
local testHeaders = {}
---@type table<number, table>
local testPartyFrames = {}
---@type table|nil
local testFramesContainer = nil
local maxTestFrames = 3
---@type TestSpell[]
local testSpells = {}
local testCcNameplateSpellIds = {
	-- kidney shot
	408,
	-- fear
	5782,
}
local testImportantNameplateSpellIds = {
	-- warlock wall
	104773,
}
local hasDanders = false
local testHealerHeader
local previousSoundEnabled

---@class TestModeManager
local M = {}
addon.TestModeManager = M

local function CreateTestFrame(i)
	local frame = CreateFrame("Frame", addonName .. "TestFrame" .. i, UIParent, "BackdropTemplate")
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

local function HideTestFrames()
	for _, testHeader in pairs(testHeaders) do
		testHeader:Hide()
	end

	for _, testPartyFrame in ipairs(testPartyFrames) do
		testPartyFrame:Hide()
	end

	if testFramesContainer then
		testFramesContainer:Hide()
	end
end

local function HideHealerOverlay()
	testHealerHeader:Hide()
	healerCcManager:Hide()

	-- resume tracking cc events
	healerCcManager:Resume()

	previousSoundEnabled = nil
end

local function HidePortraitIcons()
	local containers = portraitManager:GetContainers()

	for _, container in ipairs(containers) do
		container:ResetAllSlots()
	end

	portraitManager:Refresh()
end

local function HideAlertsTestMode()
	alertsManager:ClearAll()
	alertsManager:Resume()
	alertsManager:RefreshData()

	local alertAnchor = alertsManager:GetAnchor()
	if not alertAnchor then
		return
	end

	alertAnchor.Frame:EnableMouse(false)
	alertAnchor.Frame:SetMovable(false)
end

local function HideNameplateTestMode()
	nameplateManager:Resume()
end

local function HideKickTimer()
	local container = kickTimerManager:GetContainer()
	kickTimerManager:ClearIcons()
	container:Hide()

	container:SetMovable(false)
	container:EnableMouse(false)
end

local function ShowKickTimer()
	local container = kickTimerManager:GetContainer()
	container:Show()

	container:SetMovable(true)
	container:EnableMouse(true)

	kickTimerManager:ClearIcons()
	kickTimerManager:Kicked()
	kickTimerManager:Kicked()
	kickTimerManager:Kicked()
end

local function ShowAlertsTestMode()
	local alertAnchor = alertsManager:GetAnchor()
	if not alertAnchor then
		return
	end

	alertsManager:Pause()

	alertAnchor.Frame:EnableMouse(true)
	alertAnchor.Frame:SetMovable(true)

	local testAlertSpellIds = {
		190319, -- Combustion
		121471, -- Shadow Blades
		107574, -- Avatar
	}

	local count = math.min(#testAlertSpellIds, alertAnchor.Count or #testAlertSpellIds)
	alertAnchor:SetCount(count)

	local now = GetTime()
	for i = 1, count do
		alertAnchor:SetSlotUsed(i)

		local spellId = testAlertSpellIds[i]
		local tex = C_Spell.GetSpellTexture(spellId)
		local duration = 12 + (i - 1) * 3
		local startTime = now - (i - 1) * 1.25

		alertAnchor:SetLayer(
			i,
			1,
			tex,
			startTime,
			duration,
			true,
			db.Alerts.Icons.Glow,
			db.Alerts.Icons.ReverseCooldown
		)

		alertAnchor:FinalizeSlot(i, 1)
	end

	for i = count + 1, alertAnchor.Count do
		alertAnchor:SetSlotUnused(i)
	end
end

local function ShowTestFrames()
	if not instanceOptions then
		return
	end

	-- hide real headers
	headerManager:HideHeaders()

	local headers = headerManager:GetHeaders()

	-- try to show on real frames first
	local anyRealShown = false
	for anchor, _ in pairs(headers) do
		local testHeader = M:EnsureTestHeader(anchor)
		M:UpdateTestHeader(testHeader, instanceOptions.Icons)

		headerManager:AnchorHeader(testHeader, anchor, instanceOptions)
		frames:ShowHideFrame(testHeader, anchor, true, instanceOptions)
		anyRealShown = anyRealShown or testHeader:IsVisible()
	end

	if anyRealShown then
		for i = 1, #testPartyFrames do
			testPartyFrames[i]:Hide()
		end
	else
		M:EnsureTestPartyFrames()

		local anchor, testHeader = next(testHeaders)
		for i = 1, #testPartyFrames do
			if testHeader then
				local testPartyFrame = testPartyFrames[i]
				M:UpdateTestHeader(testHeader, instanceOptions.Icons)

				headerManager:AnchorHeader(testHeader, testPartyFrame, instanceOptions)

				testHeader:Show()
				testHeader:SetAlpha(1)
				testPartyFrame:Show()

				anchor, testHeader = next(testHeaders, anchor)
			end
		end
	end
end

local function ShowHealerOverlay()
	testHealerHeader:Show()
	healerCcManager:Show()

	-- pause the healer manager from tracking cc events
	healerCcManager:Pause()

	-- update the size
	M:UpdateTestHeader(testHealerHeader, db.Healer.Icons)

	-- keep track of whether we have already played the test sound so we don't spam it
	if
		capabilities:HasNewFilters() and (not previousSoundEnabled or previousSoundEnabled ~= db.Healer.Sound.Enabled)
	then
		if db.Healer.Sound.Enabled then
			healerCcManager:PlaySound()
		end

		previousSoundEnabled = db.Healer.Sound.Enabled
	end
end

local function ShowPortraitIcons()
	local containers = portraitManager:GetContainers()
	local tex = C_Spell.GetSpellTexture(testSpells[1].SpellId)
	local now = GetTime()

	portraitManager:Pause()

	for _, container in ipairs(containers) do
		container:SetSlotUsed(1)
		container:SetLayer(
			1,
			1,
			tex,
			now,
			15, -- 15 second duration for test
			true, -- alphaBoolean
			false, -- glow
			db.Portrait.ReverseCooldown
		)
		container:FinalizeSlot(1, 1)
	end
end

local function ShowNameplateTestMode()
	nameplateManager:Pause()

	local containers = nameplateManager:GetAllContainers()

	for _, container in ipairs(containers) do
		local now = GetTime()
		local ccOptions = units:IsFriend(container.UnitToken) and db.Nameplates.Friendly.CC or db.Nameplates.Enemy.CC
		local importantOptions = units:IsFriend(container.UnitToken) and db.Nameplates.Friendly.Important
			or db.Nameplates.Enemy.Important
		local ccContainer = container.CcContainer
		local importantContainer = container.ImportantContainer

		if ccContainer and ccOptions then
			for i = 1, #testCcNameplateSpellIds do
				ccContainer:SetSlotUsed(i)

				local spellId = testCcNameplateSpellIds[i]
				local tex = C_Spell.GetSpellTexture(spellId)
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5

				ccContainer:SetLayer(
					i,
					1,
					tex,
					startTime,
					duration,
					true,
					ccOptions.Icons.Glow,
					ccOptions.Icons.ReverseCooldown
				)
				ccContainer:FinalizeSlot(i, 1)
			end

			-- Mark remaining slots as unused
			for i = #testCcNameplateSpellIds + 1, ccContainer.Count do
				ccContainer:SetSlotUnused(i)
			end
		end

		if importantContainer and importantOptions then
			for i = 1, #testImportantNameplateSpellIds do
				importantContainer:SetSlotUsed(i)

				local spellId = testImportantNameplateSpellIds[i]
				local tex = C_Spell.GetSpellTexture(spellId)
				local duration = 15 + (i - 1) * 3
				local startTime = now - (i - 1) * 0.5
				importantContainer:SetLayer(
					i,
					1,
					tex,
					startTime,
					duration,
					true,
					importantOptions.Icons.Glow,
					importantOptions.Icons.ReverseCooldown
				)
				importantContainer:FinalizeSlot(i, 1)
			end

			-- Mark remaining slots as unused
			for i = #testImportantNameplateSpellIds + 1, importantContainer.Count do
				importantContainer:SetSlotUnused(i)
			end
		end
	end
end

function M:Init()
	db = mini:GetSavedVars()

	LCG = LibStub and LibStub("LibCustomGlow-1.0", false)

	local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	hasDanders = IsAddOnLoaded("DandersFrames")

	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	local multipleTestSpells = { kidneyShot, fear, hex }

	testSpells = capabilities:HasNewFilters() and multipleTestSpells or { kidneyShot }

	-- healer overlay
	local healerAnchor = healerCcManager:GetAnchor()
	testHealerHeader = CreateFrame("Frame", addonName .. "TestHealerHeader", healerAnchor)
	testHealerHeader:EnableMouse(false)
	testHealerHeader:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)

	M:UpdateTestHeader(testHealerHeader, db.Healer.Icons)
end

function M:IsEnabled()
	return enabled
end

---@param options InstanceOptions?
function M:Enable(options)
	enabled = true
	instanceOptions = options
end

function M:Disable()
	enabled = false
end

---@param options InstanceOptions?
function M:SetOptions(options)
	instanceOptions = options
end

function M:EnsureTestPartyFrames()
	if not testFramesContainer then
		local c = CreateFrame("Frame", addonName .. "TestContainer")
		c:SetClampedToScreen(true)
		c:EnableMouse(true)
		c:SetMovable(true)
		c:RegisterForDrag("LeftButton")
		c:SetScript("OnDragStart", function(containerSelf)
			containerSelf:StartMoving()
		end)
		c:SetScript("OnDragStop", function(containerSelf)
			containerSelf:StopMovingOrSizing()
		end)
		c:SetPoint("CENTER", UIParent, "CENTER", -450, 0)
		testFramesContainer = c
	end

	local width, height = 144, 72
	local anchors = frames:GetAll(false)
	local anchoredToReal = false
	local padding = 10

	for i = 1, maxTestFrames do
		local frame = testPartyFrames[i]
		if not frame then
			frame = CreateTestFrame(i)
			testPartyFrames[i] = frame
		end

		frame:ClearAllPoints()
		frame:SetSize(width, height)

		local anchor = #anchors > maxTestFrames and anchors[i]

		if
			anchor
			and anchor:GetWidth() > 0
			and anchor:GetHeight() > 0
			and anchor:GetTop() ~= nil
			and anchor:GetLeft() ~= nil
			and not hasDanders
		then
			frame:SetAllPoints(anchors[i])
			anchoredToReal = true
		else
			frame:SetPoint("TOP", testFramesContainer, "TOP", 0, (i - 1) * -frame:GetHeight() - padding)
		end
	end

	if anchoredToReal then
		testFramesContainer:Hide()
	else
		testFramesContainer:SetSize(width + padding * 2, height * maxTestFrames + padding * 2)
		testFramesContainer:Show()
	end
end

---@param frame table
---@param options IconOptions
function M:UpdateTestHeader(frame, options)
	local cols = #testSpells
	local rows = 1
	local size = tonumber(options.Size) or 32
	local padX, padY = 0, 0
	local stepX = size + padX
	local stepY = -(size + padY)
	local maxIcons = math.min(#testSpells, cols * rows)

	frame.Icons = frame.Icons or {}

	for i = 1, maxIcons do
		local btn = frame.Icons[i]
		if not btn then
			btn = CreateFrame("Button", nil, frame, "MiniCCAuraButtonTemplate")
			frame.Icons[i] = btn
		end

		btn:SetSize(size, size)
		btn.Icon:SetAllPoints(btn)

		btn:EnableMouse(false)
		btn.Icon:EnableMouse(false)

		local spell = testSpells[i]
		local texture = C_Spell.GetSpellTexture(spell.SpellId)

		btn.Icon:SetTexture(texture)

		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)

		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", frame, "TOPLEFT", col * stepX, row * stepY)
		btn:Show()

		if options.Glow then
			local color = options.ColorByDispelType
				and {
					spell.DispelColor.r,
					spell.DispelColor.g,
					spell.DispelColor.b,
					spell.DispelColor.a,
				}
			LCG.ProcGlow_Start(btn, { startAnim = false, color = color })
		else
			LCG.ProcGlow_Stop(btn)
		end
	end

	local width = (cols * size) + ((cols - 1) * padX)
	local height = (rows * size) + ((rows - 1) * padY)
	frame:SetSize(width, height)
end

function M:EnsureTestHeader(anchor)
	local header = testHeaders[anchor]
	if not header then
		header = CreateFrame("Frame", nil, UIParent)
		testHeaders[anchor] = header
	end

	if instanceOptions then
		M:UpdateTestHeader(header, instanceOptions.Icons)
	end

	return header
end

function M:Hide()
	HideTestFrames()
	HideHealerOverlay()
	HidePortraitIcons()
	HideAlertsTestMode()
	HideNameplateTestMode()
	HideKickTimer()
end

function M:Show()
	if instanceOptions and instanceOptions.Enabled then
		ShowTestFrames()
	else
		HideTestFrames()
	end

	if db.Healer.Enabled then
		ShowHealerOverlay()
	else
		HideHealerOverlay()
	end

	if db.Portrait.Enabled then
		ShowPortraitIcons()
	else
		HidePortraitIcons()
	end

	if db.Alerts.Enabled then
		ShowAlertsTestMode()
	else
		HideAlertsTestMode()
	end

	local anyNameplateEnabled = db.Nameplates.Friendly.CC.Enabled
		or db.Nameplates.Friendly.Important.Enabled
		or db.Nameplates.Enemy.CC.Enabled
		or db.Nameplates.Enemy.Important.Enabled

	if anyNameplateEnabled then
		ShowNameplateTestMode()
	else
		HideNameplateTestMode()
	end

	if kickTimerManager:IsEnabledForPlayer(db.KickTimer) then
		ShowKickTimer()
	else
		HideKickTimer()
	end
end

---@class TestSpell
---@field SpellId number
---@field DispelColor table
