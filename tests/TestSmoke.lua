-- Loads the whole addon from its TOC into a mocked client and drives it through login.
-- The shared body lives in build/Lua/SmokeTest.lua.
--
-- This runs last in RunAll.lua on purpose: the shared mock replaces the WoW globals wholesale,
-- and the rest of the suite drives its own narrower stubs from tests/Helpers.

local smoke = require("SmokeTest")

smoke.Run("MiniCC")
