-- TODO: refactor such that each module is responsible for it's own test mode
---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local capabilities = addon.Capabilities
local ccModule = addon.Modules.CcModule
local healerCcModule = addon.Modules.HealerCcModule
local portraitModule = addon.Modules.PortraitModule
local alertsModule = addon.Modules.AlertsModule
local nameplateModule = addon.Modules.NameplatesModule
local kickTimerModule = addon.Modules.KickTimerModule
local trinketsModule = addon.Modules.TrinketsModule
local frames = addon.Core.Frames
local IconSlotContainer = addon.Core.IconSlotContainer
---@type Db
local db
local enabled = false
---@type InstanceOptions|nil
local instanceOptions = nil
---@type table<table, IconSlotContainer>
local testHeaders = {}
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
	-- precog
	377362,
}
local hasDanders = false
local testHealerHeader
local previousSoundEnabled

---@class TestModeManager
local M = {}
addon.Modules.TestModeManager = M

local function HideTestFrames()
	for _, testHeader in pairs(testHeaders) do
		testHeader.Frame:Hide()
	end

	local testPartyFrames = frames:GetTestFrames()
	for _, testPartyFrame in ipairs(testPartyFrames) do
		testPartyFrame:Hide()
	end

	local testFramesContainer = frames:GetTestFrameContainer()
	if testFramesContainer then
		testFramesContainer:Hide()
	end

	ccModule:Resume()
end

local function HideHealerOverlay()
	testHealerHeader.Frame:Hide()
	healerCcModule:Hide()

	-- resume tracking cc events
	healerCcModule:Resume()

	previousSoundEnabled = nil
end

local function HidePortraitIcons()
	local containers = portraitModule:GetContainers()

	for _, container in ipairs(containers) do
		container:ResetAllSlots()
	end

	portraitModule:Refresh()
	portraitModule:Resume()
end

local function HideAlertsTestMode()
	alertsModule:ClearAll()
	alertsModule:Resume()

	local alertAnchor = alertsModule:GetAnchor()
	if not alertAnchor then
		return
	end

	alertAnchor.Frame:EnableMouse(false)
	alertAnchor.Frame:SetMovable(false)
end

local function HideNameplateTestMode()
	nameplateModule:Resume()
end

local function HideKickTimer()
	local container = kickTimerModule:GetContainer()
	kickTimerModule:ClearIcons()
	container:Hide()

	container:SetMovable(false)
	container:EnableMouse(false)
end

local function ShowKickTimer()
	local container = kickTimerModule:GetContainer()
	container:Show()

	container:SetMovable(true)
	container:EnableMouse(true)

	kickTimerModule:ClearIcons()
	-- mage
	kickTimerModule:KickedBySpec(62)
	-- hunter
	kickTimerModule:KickedBySpec(254)
	-- rogue
	kickTimerModule:KickedBySpec(259)
end

local function ShowAlertsTestMode()
	local alertAnchor = alertsModule:GetAnchor()
	if not alertAnchor then
		return
	end

	alertsModule:Pause()

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

local function AnchorTestFrames()
	local width, height = 144, 72
	local anchors = frames:GetAll(false)
	local anchoredToReal = false
	local padding = 10
	local testFrames = frames:GetTestFrames()
	local testFramesContainer = frames:GetTestFrameContainer()

	if not testFramesContainer or not testFrames then
		return
	end

	for i, frame in ipairs(testFrames) do
		frame:ClearAllPoints()
		frame:SetSize(width, height)

		local anchor = #anchors > #testFrames and anchors[i]

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
		testFramesContainer:SetSize(width + padding * 2, height * #testFrames + padding * 2)
		testFramesContainer:Show()
	end
end

---@param container IconSlotContainer
---@param options IconOptions
local function UpdateTestContainer(container, options)
	local size = tonumber(options.Size) or 32
	local now = GetTime()

	container:ResetAllSlots()
	container:SetIconSize(size)
	container:SetCount(#testSpells)

	for i, spell in ipairs(testSpells) do
		local texture = C_Spell.GetSpellTexture(spell.SpellId)
		local duration = 15 + (i - 1) * 3
		local startTime = now - (i - 1) * 0.5

		container:SetSlotUsed(i)
		container:SetLayer(i, 1, texture, startTime, duration, true, options.Glow, options.ReverseCooldown)
		container:FinalizeSlot(i, 1)
	end
end

local function EnsureTestHeader(anchor)
	local header = testHeaders[anchor]
	if not header then
		local count = instanceOptions and instanceOptions.Icons.Count or 3
		local size = instanceOptions and tonumber(instanceOptions.Icons.Size) or 20
		local spacing = 2
		header = IconSlotContainer:New(UIParent, count, size, spacing)
		testHeaders[anchor] = header
	end

	if instanceOptions then
		UpdateTestContainer(header, instanceOptions.Icons)
	end

	return header
end

local function ShowTestFrames()
	if not instanceOptions then
		return
	end

	-- hide real containers
	ccModule:Pause()
	ccModule:Hide()

	-- TODO: refactor this, use real containers and just populate test icons
	local testPartyFrames = frames:GetTestFrames()
	local containers = ccModule:GetContainers()

	-- try to show on real frames first
	local anyRealShown = false
	for anchor, _ in pairs(containers) do
		local testHeader = EnsureTestHeader(anchor)
		UpdateTestContainer(testHeader, instanceOptions.Icons)

		ccModule:AnchorContainer(testHeader, anchor, instanceOptions)
		frames:ShowHideFrame(testHeader.Frame, anchor, true, instanceOptions)
		anyRealShown = anyRealShown or testHeader.Frame:IsVisible()
	end

	if anyRealShown then
		for i = 1, #testPartyFrames do
			testPartyFrames[i]:Hide()
		end
	else
		AnchorTestFrames()

		local anchor, testHeader = next(testHeaders)
		for i = 1, #testPartyFrames do
			if testHeader then
				local testPartyFrame = testPartyFrames[i]
				UpdateTestContainer(testHeader, instanceOptions.Icons)

				ccModule:AnchorContainer(testHeader, testPartyFrame, instanceOptions)

				testHeader.Frame:Show()
				testHeader.Frame:SetAlpha(1)
				testPartyFrame:Show()

				anchor, testHeader = next(testHeaders, anchor)
			end
		end
	end
end

local function ShowHealerOverlay()
	testHealerHeader.Frame:Show()
	healerCcModule:Show()

	-- pause the healer manager from tracking cc events
	healerCcModule:Pause()

	-- update the size
	UpdateTestContainer(testHealerHeader, db.Healer.Icons)

	-- keep track of whether we have already played the test sound so we don't spam it
	if
		capabilities:HasNewFilters() and (not previousSoundEnabled or previousSoundEnabled ~= db.Healer.Sound.Enabled)
	then
		if db.Healer.Sound.Enabled then
			healerCcModule:PlaySound()
		end

		previousSoundEnabled = db.Healer.Sound.Enabled
	end
end

local function ShowPortraitIcons()
	local containers = portraitModule:GetContainers()
	local tex = C_Spell.GetSpellTexture(testSpells[1].SpellId)
	local now = GetTime()

	portraitModule:Pause()

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
	nameplateModule:Pause()

	local containers = nameplateModule:GetAllContainers()

	for _, container in ipairs(containers) do
		local now = GetTime()
		local options = nameplateModule:GetUnitOptions(container.UnitToken)
		local ccOptions = options.CC
		local importantOptions = options.Important
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

function M:Hide()
	HideTestFrames()
	HideHealerOverlay()
	HidePortraitIcons()
	HideAlertsTestMode()
	HideNameplateTestMode()
	HideKickTimer()
	trinketsModule:StopTesting()
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

	if kickTimerModule:IsEnabledForPlayer(db.KickTimer) then
		ShowKickTimer()
	else
		HideKickTimer()
	end

	if db.Trinkets and db.Trinkets.Enabled then
		trinketsModule:StartTesting()
	else
		trinketsModule:StopTesting()
	end
end

function M:Init()
	db = mini:GetSavedVars()

	local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
	hasDanders = IsAddOnLoaded("DandersFrames")

	local kidneyShot = { SpellId = 408, DispelColor = DEBUFF_TYPE_NONE_COLOR }
	local fear = { SpellId = 5782, DispelColor = DEBUFF_TYPE_MAGIC_COLOR }
	local hex = { SpellId = 254412, DispelColor = DEBUFF_TYPE_CURSE_COLOR }
	local multipleTestSpells = { kidneyShot, fear, hex }

	testSpells = capabilities:HasNewFilters() and multipleTestSpells or { kidneyShot }

	-- healer overlay - create IconSlotContainer for test mode
	local healerAnchor = healerCcModule:GetAnchor()
	local count = #testSpells
	local size = tonumber(db.Healer.Icons.Size) or 32
	local spacing = 2
	testHealerHeader = IconSlotContainer:New(healerAnchor, count, size, spacing)
	testHealerHeader.Frame:SetPoint("BOTTOM", healerAnchor, "BOTTOM", 0, 0)

	UpdateTestContainer(testHealerHeader, db.Healer.Icons)
end

---@class TestSpell
---@field SpellId number
---@field DispelColor table
