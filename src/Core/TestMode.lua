---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local capabilities = addon.Capabilities
local headerManager = addon.HeaderManager
local healerOverlay = addon.HealerOverlay
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
---@type number[]
local testSpells = {}
local hasDanders = false
local testHealerHeader

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
	healerOverlay:Hide()
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

		headerManager:AnchorHeader(testHeader, anchor, instanceOptions)
		headerManager:ShowHideHeader(testHeader, anchor, true, instanceOptions)
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
	healerOverlay:Show()
end

function M:Init()
	db = mini:GetSavedVars()

	LCG = LibStub and LibStub("LibCustomGlow-1.0", false)

	local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	hasDanders = IsAddOnLoaded("DandersFrames")

	local singleTestSpell = 408
	local multipleTestSpells = { singleTestSpell, 5782, 118 }
	testSpells = capabilities:SupportsCrowdControlFiltering() and multipleTestSpells or { singleTestSpell }

	-- healer overlay
	testHealerHeader = CreateFrame("Frame", addonName .. "TestHealerHeader", healerAnchor)
	testHealerHeader:EnableMouse(false)

	local healerAnchor = healerOverlay:GetAnchor()
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
	local anchors = headerManager:GetAnchors(false)
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

		if anchor and anchor:GetWidth() > 0 and anchor:GetHeight() > 0 and not hasDanders then
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

		local texture = C_Spell.GetSpellTexture(testSpells[i])
		btn.Icon:SetTexture(texture)

		local col = (i - 1) % cols
		local row = math.floor((i - 1) / cols)

		btn:ClearAllPoints()
		btn:SetPoint("TOPLEFT", frame, "TOPLEFT", col * stepX, row * stepY)
		btn:Show()
	end

	for i = maxIcons + 1, #frame.Icons do
		frame.Icons[i]:Hide()
	end

	if LCG then
		for _, icon in ipairs(frame.Icons) do
			if options.Glow then
				LCG.ProcGlow_Start(icon, { startAnim = false })
			else
				LCG.ProcGlow_Stop(icon)
			end
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
end
