-- Loads the whole addon from its TOC into a mocked client and drives it through login.
-- The shared body lives in build/Lua/SmokeTest.lua.
--
-- This runs last in RunAll.lua on purpose: the shared mock replaces the WoW globals wholesale,
-- and the rest of the suite drives its own narrower stubs from tests/Helpers.

local fw = require("TestFramework")
local smoke = require("SmokeTest")

---The stand-in frames, which only the whole-addon load builds: they are real widgets with a
---backdrop, so the narrower module harness stubs them rather than creating them.
---@param context table
local function CheckTestFrames(context)
	local frames = context.Addon.Core.Frames
	local testMode = context.Addon.Core.TestModeManager
	local partyFrames = frames:GetTestFrames()
	local arenaFrames = frames:GetTestArenaFrames()

	fw.eq(#partyFrames, 3, "stand-in party frames")
	fw.eq(#arenaFrames, 3, "stand-in arena frames")

	for index, frame in ipairs(arenaFrames) do
		fw.eq(frame.unit, "arena" .. index, "stand-in arena frame unit")
		fw.truthy(not frame:IsShown(), "stand-in arena frames start hidden")
	end

	fw.truthy(not frames:HasVisibleArenaFrames(), "no real arena frames in a mocked client")

	-- Nothing real is on screen here, so test mode has to put both columns up.
	testMode:StartTesting()

	fw.truthy(arenaFrames[1]:IsShown(), "test mode shows the arena stand-ins")
	fw.truthy(partyFrames[1]:IsShown(), "and the party ones")
	fw.truthy(frames:GetTestArenaFrameContainer():IsShown(), "along with their container")

	testMode:StopTesting()

	fw.truthy(not arenaFrames[1]:IsShown(), "stopping puts the arena stand-ins away")
	fw.truthy(not partyFrames[1]:IsShown(), "and the party ones")
	fw.truthy(not frames:GetTestArenaFrameContainer():IsShown(), "container included")
end

smoke.Run("MiniAuras", { extra = CheckTestFrames })
