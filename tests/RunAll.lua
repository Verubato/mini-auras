-- Entry point for the MiniAuras test suite.
-- Run from the repository root:
--
--   lua tests/RunAll.lua
--
-- Requirements: Lua 5.1 or later.

-- The shared harness (test framework, WoW mock, TOC loader) lives in the build submodule, so
-- a fresh clone needs `git submodule update --init` first.
package.path = "build/Lua/?.lua;tests/Helpers/?.lua;tests/?.lua;" .. package.path

-- Required up front, before any test file has put an addon global into _G: the mock snapshots
-- the globals that exist when it loads and treats everything added afterwards as an addon's,
-- clearing it whenever it installs a fresh client.
require("WowMock")

io.write("MiniAuras - unit tests\n")
io.write("======================================\n")

local testFiles = {
    "tests/Core/TestAuraContainerDisplay.lua",
    "tests/Core/TestIconSlotColors.lua",
    "tests/Core/TestIconSlotLayout.lua",
    "tests/Core/TestKickTracker.lua",
    "tests/Core/TestInspector.lua",
    "tests/Core/TestUnitStatePoller.lua",
    "tests/Core/TestModuleLifecycle.lua",
    "tests/Core/TestBarTextures.lua",
    "tests/Core/TestFonts.lua",
    "tests/Core/TestArtTextures.lua",
    "tests/Core/TestBorderTextures.lua",
    "tests/Core/TestIconSlotBorder.lua",
    "tests/Core/TestGlowStyles.lua",
    "tests/Core/TestSounds.lua",
    "tests/Core/TestAuraSounds.lua",
    "tests/Core/TestTtsPacks.lua",
    "tests/Core/TestSpellSearch.lua",
    "tests/Core/TestTestSpells.lua",
    "tests/Core/TestLegacyAddon.lua",
    "tests/Core/TestLocale.lua",
    "tests/Core/TestFrames.lua",
    "tests/Core/TestSweep.lua",
    "tests/Core/TestPool.lua",
    "tests/Core/TestUUFFrames.lua",
    "tests/Core/TestPositionEditor.lua",
    "tests/Core/TestPixels.lua",
    "tests/Core/TestIconSlotAlpha.lua",

    "tests/Utils/TestUtils.lua",

    "tests/Config/TestMigrator.lua",
    "tests/Config/TestProfileManager.lua",

    "tests/Modules/TestEnemyKickTracker.lua",
    "tests/Modules/TestAllyKickTracker.lua",
    "tests/Modules/TestContainerLifecycle.lua",
    "tests/Modules/TestModuleSmoke.lua",
    "tests/Modules/TestAlertsBars.lua",
    "tests/Modules/TestAlertsUnitSource.lua",
    "tests/Modules/TestAlertsCenterGrow.lua",
    "tests/Modules/TestAlertsClassColors.lua",
    "tests/Modules/TestAlertsTtsSpells.lua",
    "tests/Modules/TestAlertsLateMedia.lua",
    "tests/Modules/TestPortraitDisplay.lua",
    "tests/Modules/TestUnitFrameRetarget.lua",
    "tests/Modules/TestUnitFrameWarmup.lua",
    "tests/Modules/TestUnitFrameProfiles.lua",
    "tests/Modules/TestCrowdControlZoneGate.lua",
    "tests/Modules/TestTrinketsAnchors.lua",
    "tests/Modules/TestTestModePreview.lua",
    "tests/Modules/TestImportantAurasTestMode.lua",
    "tests/Modules/TestImportantAurasFilters.lua",
    "tests/Modules/TestImportantAurasZoneGate.lua",
    "tests/Modules/TestPersonalAuras.lua",
    "tests/Modules/TestAuraSoundCombatGate.lua",
    "tests/Modules/TestFrameAuras.lua",

    "tests/Config/TestAlertsPanel.lua",
    "tests/Config/TestPersonalAurasPanel.lua",
    "tests/Config/TestPortraitsPanel.lua",
    "tests/Config/TestTexturePicker.lua",
    "tests/Config/TestFrameAurasPanel.lua",
    "tests/Config/TestImportantAurasPanel.lua",
    "tests/Config/TestMiscellaneousPanel.lua",
    "tests/Config/TestNameplatesPanel.lua",
    "tests/Config/TestPanelRefresh.lua",
    "tests/Config/TestLabelColours.lua",

    -- Whole addon, loaded from the TOC into the shared mocked client. Last, because the shared
    -- mock replaces the WoW globals the narrower helpers above install.
    "tests/TestAddonEvents.lua",
    "tests/TestHousing.lua",
    "tests/TestSmoke.lua",
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
