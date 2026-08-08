local addonName, addon = ...
local M = addon.Core.Frames
local MAX_TEST_FRAMES = 3
local PET_FRAME_WIDTH, PET_FRAME_HEIGHT = 144, 40
local testPartyFrames = {}
-- Kept out of testPartyFrames on purpose: that list feeds GetAll's party anchors, and the
-- party modules must never attach their displays to a pet frame.
local testPetFrame = nil
local testFramesContainer = nil

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

	-- some modules expect this, e.g. trinket module
	frame.unit = "party" .. i
	frame:Hide()

	return frame
end

---A stand-in for a compact party pet frame, so pet CC has something to anchor its test icons
---to when no real pet frames exist (solo testing).
local function CreateTestPetFrame()
	local frame = CreateFrame("Frame", addonName .. "TestPetFrame", UIParent, "BackdropTemplate")
	frame:SetSize(PET_FRAME_WIDTH, PET_FRAME_HEIGHT)

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

	frame.Text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.Text:SetPoint("CENTER")
	frame.Text:SetText("partypet1")
	frame.Text:SetTextColor(1, 1, 1)

	frame.unit = "partypet1"
	frame:Hide()

	return frame
end

function M:CreateTestFrames()
	testFramesContainer = CreateFrame("Frame", addonName .. "TestContainer")
	testFramesContainer:SetClampedToScreen(true)
	testFramesContainer:EnableMouse(true)
	testFramesContainer:SetMovable(true)
	testFramesContainer:RegisterForDrag("LeftButton")
	testFramesContainer:SetScript("OnDragStart", function(containerSelf)
		containerSelf:StartMoving()
	end)
	testFramesContainer:SetScript("OnDragStop", function(containerSelf)
		containerSelf:StopMovingOrSizing()
	end)
	testFramesContainer:SetPoint("CENTER", UIParent, "CENTER", -450, 0)
	testFramesContainer:Hide()

	local width, height = 144, 72
	local padding = 10

	for i = 1, MAX_TEST_FRAMES do
		local frame = testPartyFrames[i]
		if not frame then
			frame = CreateTestFrame(i)
			testPartyFrames[i] = frame
		end

		frame:ClearAllPoints()
		frame:SetSize(width, height)
		frame:SetPoint("TOP", testFramesContainer, "TOP", 0, (i - 1) * -frame:GetHeight() - padding)
	end

	if not testPetFrame then
		testPetFrame = CreateTestPetFrame()
	end

	testPetFrame:ClearAllPoints()
	testPetFrame:SetPoint("TOP", testFramesContainer, "TOP", 0, MAX_TEST_FRAMES * -height - padding * 2)

	testFramesContainer:SetSize(
		width + padding * 2,
		height * MAX_TEST_FRAMES + PET_FRAME_HEIGHT + padding * 3
	)
end

function M:GetTestFrameContainer()
	return testFramesContainer
end

function M:GetTestFrames()
	return testPartyFrames
end

function M:GetTestPetFrame()
	return testPetFrame
end
