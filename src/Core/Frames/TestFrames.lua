local addonName, addon = ...
local M = addon.Core.Frames
local MAX_TEST_FRAMES = 3
local testPartyFrames = {}
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

	testFramesContainer:SetSize(width + padding * 2, height * MAX_TEST_FRAMES + padding * 2)
end

function M:GetTestFrameContainer()
	return testFramesContainer
end

function M:GetTestFrames()
	return testPartyFrames
end
