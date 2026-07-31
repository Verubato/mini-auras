-- Entry point for the MiniCC Cooldowns test suite.
-- Run from the repository root:
--
--   lua tests/run_all.lua
--
-- Requirements: Lua 5.1 or later.

package.path = "tests/helpers/?.lua;tests/?.lua;" .. package.path

io.write("MiniCC - Cooldowns unit tests\n")
io.write("======================================\n")

local testFiles = {
    "tests/TestRules.lua",
    "tests/TestFindBestCandidate.lua",
    "tests/TestPredictPve_12_0_5.lua",
    "tests/TestMatchRule.lua",
    "tests/TestFindBestCandidateExtended.lua",
    "tests/TestPredictExtended.lua",
    "tests/TestEvidencePipeline.lua",
    "tests/TestEnemyMatching.lua",
    "tests/TestMulticharge.lua",
    "tests/TestCrossClassExt.lua",
    "tests/TestLocalPlayerAlias.lua",
    "tests/TestDispersionDp.lua",
    "tests/TestFeignDeathAottSotf.lua",
    "tests/TestBurrow.lua",
    "tests/TestEmeraldCommunion.lua",
    "tests/TestAuraWatcher.lua",
    "tests/TestAuraContainerDisplay.lua",
    "tests/TestUtils.lua",
    "tests/TestMigrator.lua",
    "tests/TestKickTracker.lua",
    "tests/TestModuleLifecycle.lua",
    "tests/TestModuleSmoke.lua",
    "tests/TestAlertsBars.lua",
    "tests/TestPortraitDisplay.lua",
    "tests/TestUnitFrameRetarget.lua",
    "tests/TestProfileManager.lua",
}

local loadErrors = {}

for _, path in ipairs(testFiles) do
    io.write("\n[" .. path .. "]\n")
    local fn, err = loadfile(path)
    if fn then
        local ok, runErr = pcall(fn)
        if not ok then
            io.write("  ERROR while running " .. path .. ":\n  " .. tostring(runErr) .. "\n")
            loadErrors[#loadErrors + 1] = path .. ": " .. tostring(runErr)
        end
    else
        io.write("  ERROR loading " .. path .. ":\n  " .. tostring(err) .. "\n")
        loadErrors[#loadErrors + 1] = path .. ": " .. tostring(err)
    end
end

local fw = require("Framework")
local allPassed = fw.summary()

if #loadErrors > 0 then
    io.write("\nFile-load errors:\n")
    for _, e in ipairs(loadErrors) do
        io.write("  " .. e .. "\n")
    end
    allPassed = false
end

os.exit(allPassed and 0 or 1)
