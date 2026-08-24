-- Shim onto the shared build repository's test framework, so every addon's suite reports the same
-- way. The singleton is shared, so pass and fail counters accumulate across every test file.

return require("TestFramework")
