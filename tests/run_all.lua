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
    "tests/test_rules.lua",
    "tests/test_find_best_candidate.lua",
    "tests/test_predict_pve_12_0_5.lua",
    "tests/test_match_rule.lua",
    "tests/test_find_best_candidate_extended.lua",
    "tests/test_predict_extended.lua",
    "tests/test_evidence_pipeline.lua",
    "tests/test_enemy_matching.lua",
    "tests/test_multicharge.lua",
    "tests/test_simulator_2v2.lua",
    "tests/test_simulator_3v3.lua",
    "tests/test_cross_class_ext.lua",
    "tests/test_phase_shift.lua",
    "tests/test_time_stop.lua",
    "tests/test_local_player_alias.lua",
    "tests/test_dispersion_dp.lua",
    "tests/test_ams_bof_gt_regression.lua",
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

local fw = require("framework")
local allPassed = fw.summary()

if #loadErrors > 0 then
    io.write("\nFile-load errors:\n")
    for _, e in ipairs(loadErrors) do
        io.write("  " .. e .. "\n")
    end
    allPassed = false
end

os.exit(allPassed and 0 or 1)
