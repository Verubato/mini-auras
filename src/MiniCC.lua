---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local frames = addon.Frames
local auras = addon.Auras
local scheduler = addon.Scheduler
local units = addon.Units
local capabilities = addon.Capabilities
local eventsFrame

---@type { table: Header }
local headers = {}

local healerAnchor
local testHealerHeader
---@type { string: Header }
local healerHeaders = {}

local maxTestFrames = 3
local testFramesContainer
---@type { table: table }
local testHeaders = {}
local testPartyFrames = {}
local testMode = false
-- Kidney Shot
local singleTestSpell = 408
local multipleTestSpells = {
	singleTestSpell,
	-- Fear
	5782,
	-- Polymorph
	118,
}
local testSpells = capabilities:SupportsCrowdControlFiltering() and multipleTestSpells or { singleTestSpell }

---@type InstanceOptions?
local testInstanceOptions
---@type InstanceOptions
local currentInstanceOptions

local LCG = LibStub and LibStub("LibCustomGlow-1.0", false)

local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local HasDanders = IsAddOnLoaded("DandersFrames")

---@type Db
local db

local function GetInstanceOptions()
	local inInstance, instanceType = IsInInstance()
	local isBgOrRaid = inInstance and (instanceType == "pvp" or instanceType == "raid")

	if isBgOrRaid then
		return db.Raid
	end

	return db.Default
end

local function SetCurrentInstance()
	currentInstanceOptions = GetInstanceOptions()
end

local function AppendArray(src, dst)
	for i = 1, #src do
		dst[#dst + 1] = src[i]
	end
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

local function RefreshHealerAnchor()
	local options = db.Healer

	if not healerAnchor then
		healerAnchor = CreateFrame("Frame", addonName .. "HealerContainer")
		healerAnchor:EnableMouse(true)
		healerAnchor:SetMovable(true)
		healerAnchor:RegisterForDrag("LeftButton")
		healerAnchor:SetScript("OnDragStart", function(self)
			self:StartMoving()
		end)
		healerAnchor:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()

			local point, relativeTo, relativePoint, x, y = self:GetPoint()
			db.Healer.Point = point
			db.Healer.RelativePoint = relativePoint
			db.Healer.RelativeTo = (relativeTo and relativeTo:GetName()) or "UIParent"
			db.Healer.Offset.X = x
			db.Healer.Offset.Y = y
		end)

		healerAnchor:SetPoint(
			options.Point,
			_G[options.RelativeTo] or UIParent,
			options.RelativePoint,
			options.Offset.X,
			options.Offset.Y
		)

		testHealerHeader = CreateFrame("Frame", addonName .. "TestHealerHeader", healerAnchor)

		local text = healerAnchor:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
		text:SetPoint("TOP", healerAnchor, "TOP", 0, 6)
		text:SetText("Healer in CC!")
		text:SetTextColor(1, 0.1, 0.1)
		text:SetShadowColor(0, 0, 0, 1)
		text:SetShadowOffset(1, -1)

		healerAnchor.HealerWarning = text

		UpdateTestHeader(testHealerHeader, db.Healer.Icons)

		-- disable mouse so we can drag the healer
		testHealerHeader:EnableMouse(false)
		testHealerHeader:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
	end

	local stringWidth = healerAnchor.HealerWarning:GetStringWidth()
	local stringHeight = healerAnchor.HealerWarning:GetStringHeight()
	local iconSize = db.Healer.Icons.Size

	healerAnchor:SetSize(math.max(iconSize, stringWidth), iconSize + stringHeight)
end

local function GetAnchors(visibleOnly)
	local anchors = {}
	local elvui = frames:ElvUIFrames(visibleOnly)
	local grid2 = frames:Grid2Frames(visibleOnly)
	local danders = frames:DandersFrames(visibleOnly)
	-- get blizzard last, so test mode prioritises addon frames
	local blizzard = frames:BlizzardFrames(visibleOnly)
	local custom = frames:CustomFrames(visibleOnly)

	AppendArray(blizzard, anchors)
	AppendArray(elvui, anchors)
	AppendArray(grid2, anchors)
	AppendArray(danders, anchors)
	AppendArray(custom, anchors)

	return anchors
end

---@param header table
---@param anchor table
---@param options InstanceOptions
local function AnchorHeader(header, anchor, options)
	if not options then
		return
	end

	header:ClearAllPoints()

	if options.SimpleMode.Enabled then
		header:SetPoint("CENTER", anchor, "CENTER", options.SimpleMode.Offset.X, options.SimpleMode.Offset.Y)
	else
		header:SetPoint(
			options.AdvancedMode.Point,
			anchor,
			options.AdvancedMode.RelativePoint,
			options.AdvancedMode.Offset.X,
			options.AdvancedMode.Offset.Y
		)
	end

	-- raise above the anchor
	header:SetFrameLevel(anchor:GetFrameLevel() + 1)
	header:SetFrameStrata("HIGH")
end

---@param header table
---@param anchor table
---@param isTest boolean
---@param options InstanceOptions
local function ShowHideHeader(header, anchor, isTest, options)
	if not isTest and not options.Enabled then
		header:Hide()
		return
	end

	-- header might be a test header, in which case it doesn't have a unit
	local unit = header:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

	-- unit is an empty string for test headers
	if unit and unit ~= "" then
		if IsPet(unit) then
			header:Hide()
			return
		end

		if not isTest and options.ExcludePlayer and UnitIsUnit(unit, "player") then
			header:Hide()
			return
		end
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

---@param anchor table
---@param unit string|nil
local function EnsureHeader(anchor, unit)
	unit = unit or anchor.unit or anchor:GetAttribute("unit")

	if not unit then
		return nil
	end

	local header = headers[anchor]

	if not header then
		header = auras:CreateHeader(unit, currentInstanceOptions.Icons)
		headers[anchor] = header
	else
		auras:UpdateHeader(header, unit, currentInstanceOptions.Icons)
	end

	AnchorHeader(header, anchor, currentInstanceOptions)
	ShowHideHeader(header, anchor, false, currentInstanceOptions)

	return header
end

local function EnsureHeaders()
	local anchors = GetAnchors(true)

	for _, anchor in ipairs(anchors) do
		EnsureHeader(anchor)
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
	if not testFramesContainer then
		testFramesContainer = CreateFrame("Frame", addonName .. "TestContainer")
		testFramesContainer:SetClampedToScreen(true)
		testFramesContainer:EnableMouse(true)
		testFramesContainer:SetMovable(true)
		testFramesContainer:RegisterForDrag("LeftButton")
		testFramesContainer:SetScript("OnDragStart", function(self)
			self:StartMoving()
		end)
		testFramesContainer:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
		end)

		local xOffset = -450
		local yOffset = 0

		testFramesContainer:SetPoint("CENTER", UIParent, "CENTER", xOffset, yOffset)
	end

	local width = 144
	local height = 72
	local anchors = GetAnchors(false)
	local anchoredToReal = false
	local padding = 10

	for i = 1, maxTestFrames do
		local frame = testPartyFrames[i]

		if not frame then
			testPartyFrames[i] = CreateTestFrame(i)
			frame = testPartyFrames[i]
		end

		frame:ClearAllPoints()
		frame:SetSize(width, height)

		local anchor = #anchors > maxTestFrames and anchors[i]

		-- danders squashes the blizzard frames, so don't don't anchor
		if anchor and anchor:GetWidth() > 0 and anchor:GetHeight() > 0 and not HasDanders then
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
function UpdateTestHeader(frame, options)
	local cols = #testSpells
	local rows = 1
	local size = tonumber(options.Size) or 32
	local padX = 0
	local padY = 0
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

	-- Hide any extra buttons we previously created but no longer need
	for i = maxIcons + 1, #frame.Icons do
		frame.Icons[i]:Hide()
	end

	-- glow icons
	if LCG then
		for _, icon in ipairs(frame.Icons) do
			if options.Glow then
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

	if testInstanceOptions then
		UpdateTestHeader(header, testInstanceOptions.Icons)
	end

	return header
end

local function OnHealerCcChanged()
	if testMode then
		return
	end

	if capabilities:SupportsCrowdControlFiltering() then
		-- in this mode the values of IsCcApplied aren't secret
		local isCcd = false
		for _, header in pairs(healerHeaders) do
			isCcd = isCcd or header.IsCcApplied

			if isCcd then
				break
			end
		end

		healerAnchor:SetAlpha(isCcd and 1 or 0)
	else
		-- we can use EvaluateColorValueFromBoolean to collapse a set of secret booleans into a single number of 1 or 0
		local ev = C_CurveUtil.EvaluateColorValueFromBoolean
		local result = 0

		for _, header in pairs(healerHeaders) do
			result = ev(header.IsCcApplied, 1, result)
		end

		healerAnchor:SetAlpha(result)
	end
end

local function UpdateHealerHeaders()
	local options = db.Healer

	-- clear off any existing headers that are no longer healers
	-- TODO: pool these headers instead of hard clearing them and letting them linger
	for unit, header in pairs(healerHeaders) do
		if not units:IsHealer(unit) or not options.Enabled then
			auras:ClearHeader(header)
			headers[unit] = nil
		end
	end

	-- if units:IsHealer("player") then
	-- 	return
	-- end

	if not options.Enabled then
		return
	end

	local healers = units:FindHealers()

	for _, healer in ipairs(healers) do
		local header = healerHeaders[healer]
		if header then
			auras:UpdateHeader(header, healer, options.Icons)
		else
			header = auras:CreateHeader(healer, options.Icons)
			header:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)
			header:RegisterCallback(OnHealerCcChanged)
			header:Show()

			healerHeaders[healer] = header
		end
	end
end

local function RealMode()
	if not currentInstanceOptions then
		return
	end

	for anchor, header in pairs(headers) do
		local unit = header:GetAttribute("unit") or anchor.unit or anchor:GetAttribute("unit")

		if unit then
			-- refresh options
			auras:UpdateHeader(header, unit, currentInstanceOptions.Icons)
		end

		-- refresh anchor
		AnchorHeader(header, anchor, currentInstanceOptions)

		-- refresh visibility
		ShowHideHeader(header, anchor, false, currentInstanceOptions)
	end

	for _, testHeader in pairs(testHeaders) do
		testHeader:Hide()
	end

	for _, testPartyFrame in ipairs(testPartyFrames) do
		testPartyFrame:Hide()
	end

	if testFramesContainer then
		testFramesContainer:Hide()
	end

	if healerAnchor then
		healerAnchor:EnableMouse(false)
		healerAnchor:SetMovable(false)
		healerAnchor:SetAlpha(0)
	end

	if testHealerHeader then
		testHealerHeader:Hide()
	end

	UpdateHealerHeaders()
end

local function TestMode()
	if not testInstanceOptions then
		return
	end

	-- hide the real headers
	for _, header in pairs(headers) do
		header:Hide()
	end

	-- try to show on real frames first
	local anyRealShown = false
	for anchor, _ in pairs(headers) do
		local testHeader = EnsureTestHeader(anchor)

		AnchorHeader(testHeader, anchor, testInstanceOptions)
		ShowHideHeader(testHeader, anchor, true, testInstanceOptions)
		anyRealShown = anyRealShown or testHeader:IsVisible()
	end

	if anyRealShown then
		-- hide our test frames if any real exist
		for i = 1, #testPartyFrames do
			local testPartyFrame = testPartyFrames[i]
			testPartyFrame:Hide()
		end
	else
		-- no real frames, show our test frames
		EnsureTestPartyFrames()

		local anchor, testHeader = next(testHeaders)
		for i = 1, #testPartyFrames do
			if testHeader then
				local testPartyFrame = testPartyFrames[i]

				AnchorHeader(testHeader, testPartyFrame, testInstanceOptions)

				testHeader:Show()
				testHeader:SetAlpha(1)
				testPartyFrame:Show()

				anchor, testHeader = next(testHeaders, anchor)
			end
		end
	end

	-- healer anchor
	UpdateTestHeader(testHealerHeader, db.Healer.Icons)

	healerAnchor:EnableMouse(true)
	healerAnchor:SetMovable(true)
	healerAnchor:SetAlpha(1)

	testHealerHeader:Show()
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
		ShowHideHeader(header, frame, false, currentInstanceOptions)
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

local function OnFrameSortSorted()
	addon:Refresh()
end

local function OnEvent(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		if testMode or testHealerMode then
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
	addon.Frames:Init()

	db = mini:GetSavedVars()

	SetCurrentInstance()
	EnsureHeaders()

	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", OnEvent)
	eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	eventsFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
	eventsFrame:RegisterEvent("PLAYER_REGEN_DISABLED")

	if CompactUnitFrame_SetUnit then
		hooksecurefunc("CompactUnitFrame_SetUnit", OnCufSetUnit)
	end

	if CompactUnitFrame_UpdateVisible then
		hooksecurefunc("CompactUnitFrame_UpdateVisible", OnCufUpdateVisible)
	end

	local fs = FrameSortApi and FrameSortApi.v3

	if fs and fs.Sorting and fs.Sorting.RegisterPostSortCallback then
		fs.Sorting:RegisterPostSortCallback(OnFrameSortSorted)
	end

	RefreshHealerAnchor()
end

function addon:Refresh()
	if InCombatLockdown() then
		scheduler:RunWhenCombatEnds(function()
			addon:Refresh()
		end, "Refresh")
		return
	end

	SetCurrentInstance()
	EnsureHeaders()
	RefreshHealerAnchor()

	if testMode then
		TestMode()
	else
		RealMode()
	end
end

---@param options InstanceOptions?
function addon:ToggleTest(options)
	testMode = not testMode
	testInstanceOptions = options

	addon:Refresh()

	if InCombatLockdown() then
		mini:Notify("Can't test during combat, we'll test once combat drops.")
	end
end

---@param options InstanceOptions?
function addon:TestOptions(options)
	testInstanceOptions = options
	addon:Refresh()
end

mini:WaitForAddonLoad(OnAddonLoaded)

---@class Addon
---@field Framework MiniFramework
---@field Auras AurasModule
---@field Capabilities Capabilities
---@field Frames Frames
---@field Scheduler Scheduler
---@field Units UnitUtil
---@field Config Config
---@field Refresh fun(self: table)
---@field ToggleTest fun(self: table, options: InstanceOptions)
---@field TestOptions fun(self: table, options: InstanceOptions)
---@field TestHealer fun(self: table)
