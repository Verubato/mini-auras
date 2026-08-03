-- The test framework moved to the shared build repository so every addon's suite reports the
-- same way and a fix lands in all of them at once. This shim keeps the existing require path
-- working: the API is unchanged, and the singleton is shared, so the pass and fail counters
-- still accumulate across every test file in one run.

return require("TestFramework")
