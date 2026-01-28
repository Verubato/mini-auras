---@type string, Addon
local addonName, addon = ...
local mini = addon.Framework
local frames = addon.Frames
local auras = addon.Auras
local scheduler = addon.Scheduler
local capabilities = addon.Capabilities
local eventsFrame
---@type { table: table }
local headers = {}
local testContainer
---@type { table: table }
local testHeaders = {}
local testPartyFrames = {}
local testMode = false
---@type InstanceOptions?
local testInstanceOptions
---@type InstanceOptions
local currentInstanceOptions
local maxTestFrames = 3
local LCG = LibStub and LibStub("LibCustomGlow-1.0", false)
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
local HasDanders = IsAddOnLoaded("DandersFrames")
---@type Db
local db
local testSpells = {
	-- Kidney Shot
	408,
}

local function IsArena()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "arena"
end

local function IsBg()
	local inInstance, instanceType = IsInInstance()
	return inInstance and instanceType == "pvp"
end

local function GetInstanceOptions()
	if IsArena() then
		return db.Arena
	elseif IsBg() then
		return db.BattleGrounds
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

	if not isTest and not options.Enabled then
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

		local xOffset = -450
		local yOffset = 0

		-- it's too complicated to try and anchor over the top of real frame positions
		-- as with various addons the real frames will be hidden and moved to off screen positions
		-- so just use a fixed position
		testContainer:SetPoint("CENTER", UIParent, "CENTER", xOffset, yOffset)
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
			frame:SetPoint("TOP", testContainer, "TOP", 0, (i - 1) * -frame:GetHeight() - padding)
		end
	end

	if anchoredToReal then
		-- we've anchored to real frames, too much work to make it draggable
		testContainer:Hide()
	else
		testContainer:SetSize(width + padding * 2, height * maxTestFrames + padding * 2)
		testContainer:Show()
	end
end

---comment
---@param frame table
---@param options InstanceOptions
local function UpdateTestHeader(frame, options)
	local cols = #testSpells
	local rows = 1
	local size = tonumber(options.Icons.Size) or 32
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
			if options.Icons.Glow then
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
		UpdateTestHeader(header, testInstanceOptions)
	end

	return header
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

	if testContainer then
		testContainer:Hide()
	end
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

		return
	end

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

	if capabilities:SupportsCrowdControlFiltering() then
		testSpells = {
			-- Kidney Shot
			408,
			-- Fear
			5782,
			-- Polymorph
			118,
		}
	end
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

	if testMode then
		TestMode()
	else
		RealMode()
	end
end

---@param options InstanceOptions?
function addon:TestMode(options)
	if testMode and options ~= testInstanceOptions then
		testInstanceOptions = options
	else
		testMode = not testMode
		testInstanceOptions = options
	end

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
---@field Config Config
---@field Refresh fun(self: table)
---@field TestMode fun(self: table, options: InstanceOptions)
---@field TestOptions fun(self: table, options: InstanceOptions)
