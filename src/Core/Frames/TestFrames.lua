local addonName, addon = ...
local M = addon.Core.Frames
local fontUtil = addon.Utils.FontUtil
local MAX_TEST_FRAMES = 3
-- What a stand-in falls back to when no real frame has been built for it to copy.
local FRAME_WIDTH, FRAME_HEIGHT = 144, 72
-- A real pet frame is the shorter one in its column.
local PET_HEIGHT_RATIO = 40 / 72
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
-- The measuring walk's own list, so it never shares a table with a walk that is still running.
local measureScratch = {}

---The stand-in's caption in the configured face, keeping the template's size and flags. Applied
---again every time the column is shown, because the frames outlive a font change.
---@param frame table?
local function ApplyLabelFont(frame)
	local text = frame and frame.Text

	if not text then
		return
	end

	fontUtil:Apply(text)
end

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
	ApplyLabelFont(frame)

	frame:Hide()
end

---@return table
local function PlayerColour()
	local _, class = UnitClass("player")

	return RAID_CLASS_COLORS[class] or NORMAL_FONT_COLOR
end

---A frame's size in UIParent's coordinates, so a frame its addon draws at another scale comes back
---as the patch of screen it covers. Nil when the client has not laid the frame out yet.
---@param frame table
---@return number? width
---@return number? height
local function ScreenSize(frame)
	if not frame.GetWidth or not frame.GetEffectiveScale then
		return nil
	end

	local width, height = frame:GetWidth(), frame:GetHeight()
	local scale = frame:GetEffectiveScale()

	-- Comparing a secret number would abort the whole handler.
	if issecretvalue(width) or issecretvalue(height) or issecretvalue(scale) then
		return nil
	end

	if not width or not height or width <= 0 or height <= 0 then
		return nil
	end

	local uiScale = UIParent:GetEffectiveScale()

	if not scale or scale <= 0 or not uiScale or uiScale <= 0 then
		return width, height
	end

	local ratio = scale / uiScale

	return width * ratio, height * ratio
end

---The first frame in the list worth copying. Blizzard's own are held back for a second pass,
---since they are still there, hidden, under a frame addon that replaced them.
---@param anchors table
---@param skipBlizzard boolean
---@return number? width
---@return number? height
local function FirstUsableSize(anchors, skipBlizzard)
	for i = 1, #anchors do
		local anchor = anchors[i]

		if not (skipBlizzard and M:IsFriendlyCuf(anchor)) then
			local width, height = ScreenSize(anchor)

			if width then
				return width, height
			end
		end
	end

	return nil
end

---The size of the first arena frame a lookup turns up, skipping the hidden ones unless the caller
---says a hidden frame will do.
---@param lookup fun(self: table, index: number): table?
---@param mustBeVisible boolean
---@return number? width
---@return number? height
local function FirstArenaSize(lookup, mustBeVisible)
	for index = 1, MAX_TEST_FRAMES do
		local frame = lookup(M, index)

		if frame and (not mustBeVisible or frame:IsVisible()) then
			local width, height = ScreenSize(frame)

			if width then
				return width, height
			end
		end
	end

	return nil
end

---@param height number
---@return number
local function PetHeight(height)
	return math.floor(height * PET_HEIGHT_RATIO + 0.5)
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
	frame:SetSize(FRAME_WIDTH, PetHeight(FRAME_HEIGHT))

	StyleTestFrame(frame, PlayerColour(), "partypet1", "GameFontNormal")

	frame.unit = "partypet1"

	return frame
end

---Sizes and stacks both columns, run afresh every time a column goes up. Measuring any earlier
---would walk the anchors before the frame addons have built theirs.
local function LayoutTestFrames()
	local width, height = M:GetTestFrameSize()
	local petHeight = PetHeight(height)

	for i = 1, MAX_TEST_FRAMES do
		local frame = testPartyFrames[i]

		frame:ClearAllPoints()
		frame:SetSize(width, height)
		frame:SetPoint("TOP", testFramesContainer, "TOP", 0, (i - 1) * -height - FRAME_PADDING)
	end

	testPetFrame:ClearAllPoints()
	testPetFrame:SetSize(width, petHeight)
	testPetFrame:SetPoint("TOP", testFramesContainer, "TOP", 0,
		MAX_TEST_FRAMES * -height - FRAME_PADDING * 2)

	testFramesContainer:SetSize(
		width + FRAME_PADDING * 2,
		height * MAX_TEST_FRAMES + petHeight + FRAME_PADDING * 3
	)

	local arenaWidth, arenaHeight = M:GetTestArenaFrameSize()

	for i = 1, MAX_TEST_FRAMES do
		local frame = testArenaFrames[i]

		frame:ClearAllPoints()
		frame:SetSize(arenaWidth, arenaHeight)
		frame:SetPoint("TOP", testArenaContainer, "TOP", 0, (i - 1) * -arenaHeight - FRAME_PADDING)
	end

	testArenaContainer:SetSize(
		arenaWidth + FRAME_PADDING * 2,
		arenaHeight * MAX_TEST_FRAMES + FRAME_PADDING * 2
	)
end

---The size a party stand-in takes, copied from a real party frame so an icon placed on one lands
---where it will in a group. Hidden frames count, since the stand-ins only come out when nothing
---real is on screen.
---@return number width
---@return number height
function M:GetTestFrameSize()
	local anchors = M:GetAll(false, false, measureScratch)
	local width, height = FirstUsableSize(anchors, true)

	if not width then
		width, height = FirstUsableSize(anchors, false)
	end

	return width or FRAME_WIDTH, height or FRAME_HEIGHT
end

---The size an arena stand-in takes: an enemy frame on screen, then one an addon built and is
---holding hidden, then the party size. Blizzard's own sit at their template size until an arena
---loads, which is nothing like what the player will see.
---@return number width
---@return number height
function M:GetTestArenaFrameSize()
	local width, height = FirstArenaSize(M.GetArenaFrame, true)

	if not width then
		width, height = FirstArenaSize(M.GetAddonArenaFrame, false)
	end

	if not width then
		return M:GetTestFrameSize()
	end

	return width, height
end

function M:CreateTestFrames()
	testFramesContainer = CreateContainer(addonName .. "TestContainer", -CONTAINER_OFFSET_X)
	testArenaContainer = CreateContainer(addonName .. "TestArenaContainer", CONTAINER_OFFSET_X)

	for i = 1, MAX_TEST_FRAMES do
		if not testPartyFrames[i] then
			testPartyFrames[i] = CreateTestFrame(i)
		end

		if not testArenaFrames[i] then
			testArenaFrames[i] = CreateTestArenaFrame(i)
		end
	end

	if not testPetFrame then
		testPetFrame = CreateTestPetFrame()
	end
end

---Re-applies the configured face to every stand-in caption on screen. Driven by the addon-wide
---refresh: these frames outlive a font change, and nothing else touches them once they are up.
function M:RefreshTestFrameFonts()
	if testFramesContainer and testFramesContainer:IsShown() then
		for _, frame in ipairs(testPartyFrames) do
			ApplyLabelFont(frame)
		end

		ApplyLabelFont(testPetFrame)
	end

	if testArenaContainer and testArenaContainer:IsShown() then
		for _, frame in ipairs(testArenaFrames) do
			ApplyLabelFont(frame)
		end
	end
end

function M:GetTestFrameContainer()
	return testFramesContainer
end

function M:GetTestFrames()
	return testPartyFrames
end

---Whether a frame is one of the stand-ins test mode puts up. They are created once and keep their
---entries for the session, so anything counting real frames has to leave them out.
---@param frame table?
---@return boolean
function M:IsTestFrame(frame)
	if not frame then
		return false
	end

	for _, testFrame in ipairs(testPartyFrames) do
		if testFrame == frame then
			return true
		end
	end

	return frame == testPetFrame
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
	if shown then
		LayoutTestFrames()
	end

	for _, frame in ipairs(testPartyFrames) do
		frame:SetShown(shown)
		ApplyLabelFont(frame)
	end

	if testPetFrame then
		testPetFrame:SetShown(shown)
		ApplyLabelFont(testPetFrame)
	end

	if testFramesContainer then
		testFramesContainer:SetShown(shown)
	end
end

---@param shown boolean
function M:SetTestArenaFramesShown(shown)
	if shown then
		LayoutTestFrames()
	end

	for _, frame in ipairs(testArenaFrames) do
		frame:SetShown(shown)
		ApplyLabelFont(frame)
	end

	if testArenaContainer then
		testArenaContainer:SetShown(shown)
	end
end
