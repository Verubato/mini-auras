local addonName, addon = ...
local M = addon.Core.Frames
local MAX_TEST_FRAMES = 3
local PET_FRAME_WIDTH, PET_FRAME_HEIGHT = 144, 40
local FRAME_WIDTH, FRAME_HEIGHT = 144, 72
local FRAME_PADDING = 10
-- The two columns sit either side of the middle, party on the left and arena mirrored opposite.
local CONTAINER_OFFSET_X = 450
-- The arena stand-ins are the enemy side, so a hostile red rather than the player's class colour.
local ENEMY_COLOUR = { r = 0.7, g = 0.15, b = 0.15 }
local BACKDROP = {
	bgFile = "Interface\\Buttons\\WHITE8X8",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	edgeSize = 12,
	insets = { left = 2, right = 2, top = 2, bottom = 2 },
}
local testPartyFrames = {}
local testArenaFrames = {}
-- Kept out of testPartyFrames on purpose: that list feeds GetAll's party anchors, and the
-- party modules must never attach their displays to a pet frame.
local testPetFrame = nil
local testFramesContainer = nil
local testArenaContainer = nil

---@param frame table
---@param colour table
---@param label string
---@param font string
local function StyleTestFrame(frame, colour, label, font)
	frame:SetBackdrop(BACKDROP)
	frame:SetBackdropColor(colour.r, colour.g, colour.b, 0.9)
	frame:SetBackdropBorderColor(0, 0, 0, 1)

	frame.Text = frame:CreateFontString(nil, "OVERLAY", font)
	frame.Text:SetPoint("CENTER")
	frame.Text:SetText(label)
	frame.Text:SetTextColor(1, 1, 1)

	frame:Hide()
end

---@return table
local function PlayerColour()
	local _, class = UnitClass("player")

	return RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
end

---A draggable, screen-clamped holder for one column of stand-in frames.
---@param name string
---@param offsetX number
---@return table
local function CreateContainer(name, offsetX)
	local container = CreateFrame("Frame", name)
	container:SetClampedToScreen(true)
	container:EnableMouse(true)
	container:SetMovable(true)
	container:RegisterForDrag("LeftButton")
	container:SetScript("OnDragStart", function(containerSelf)
		containerSelf:StartMoving()
	end)
	container:SetScript("OnDragStop", function(containerSelf)
		containerSelf:StopMovingOrSizing()
	end)
	container:SetPoint("CENTER", UIParent, "CENTER", offsetX, 0)
	container:Hide()

	return container
end

local function CreateTestFrame(i)
	local frame = CreateFrame("Frame", addonName .. "TestFrame" .. i, UIParent, "BackdropTemplate")
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)

	StyleTestFrame(frame, PlayerColour(), ("party%d"):format(i), "GameFontNormalLarge")

	-- some modules expect this, e.g. trinket module
	frame.unit = "party" .. i

	return frame
end

---A stand-in for an arena enemy frame, so a group aimed at those has something to hang off
---while the user is placing it outside an arena.
local function CreateTestArenaFrame(i)
	local frame = CreateFrame("Frame", addonName .. "TestArenaFrame" .. i, UIParent, "BackdropTemplate")
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)

	StyleTestFrame(frame, ENEMY_COLOUR, ("arena%d"):format(i), "GameFontNormalLarge")

	frame.unit = "arena" .. i

	return frame
end

---A stand-in for a compact party pet frame, so pet CC has something to anchor its test icons
---to when no real pet frames exist (solo testing).
local function CreateTestPetFrame()
	local frame = CreateFrame("Frame", addonName .. "TestPetFrame", UIParent, "BackdropTemplate")
	frame:SetSize(PET_FRAME_WIDTH, PET_FRAME_HEIGHT)

	StyleTestFrame(frame, PlayerColour(), "partypet1", "GameFontNormal")

	frame.unit = "partypet1"

	return frame
end

function M:CreateTestFrames()
	testFramesContainer = CreateContainer(addonName .. "TestContainer", -CONTAINER_OFFSET_X)

	for i = 1, MAX_TEST_FRAMES do
		local frame = testPartyFrames[i]
		if not frame then
			frame = CreateTestFrame(i)
			testPartyFrames[i] = frame
		end

		frame:ClearAllPoints()
		frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
		frame:SetPoint("TOP", testFramesContainer, "TOP", 0, (i - 1) * -FRAME_HEIGHT - FRAME_PADDING)
	end

	if not testPetFrame then
		testPetFrame = CreateTestPetFrame()
	end

	testPetFrame:ClearAllPoints()
	testPetFrame:SetPoint("TOP", testFramesContainer, "TOP", 0,
		MAX_TEST_FRAMES * -FRAME_HEIGHT - FRAME_PADDING * 2)

	testFramesContainer:SetSize(
		FRAME_WIDTH + FRAME_PADDING * 2,
		FRAME_HEIGHT * MAX_TEST_FRAMES + PET_FRAME_HEIGHT + FRAME_PADDING * 3
	)

	testArenaContainer = CreateContainer(addonName .. "TestArenaContainer", CONTAINER_OFFSET_X)

	for i = 1, MAX_TEST_FRAMES do
		local frame = testArenaFrames[i]
		if not frame then
			frame = CreateTestArenaFrame(i)
			testArenaFrames[i] = frame
		end

		frame:ClearAllPoints()
		frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
		frame:SetPoint("TOP", testArenaContainer, "TOP", 0, (i - 1) * -FRAME_HEIGHT - FRAME_PADDING)
	end

	testArenaContainer:SetSize(
		FRAME_WIDTH + FRAME_PADDING * 2,
		FRAME_HEIGHT * MAX_TEST_FRAMES + FRAME_PADDING * 2
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

function M:GetTestArenaFrameContainer()
	return testArenaContainer
end

function M:GetTestArenaFrames()
	return testArenaFrames
end

---Puts the whole party stand-in column on screen or takes it away, pet frame included. Both
---test mode and the aura editor's preview drive this, so neither has to know the pieces.
---@param shown boolean
function M:SetTestFramesShown(shown)
	for _, frame in ipairs(testPartyFrames) do
		frame:SetShown(shown)
	end

	if testPetFrame then
		testPetFrame:SetShown(shown)
	end

	if testFramesContainer then
		testFramesContainer:SetShown(shown)
	end
end

---@param shown boolean
function M:SetTestArenaFramesShown(shown)
	for _, frame in ipairs(testArenaFrames) do
		frame:SetShown(shown)
	end

	if testArenaContainer then
		testArenaContainer:SetShown(shown)
	end
end
