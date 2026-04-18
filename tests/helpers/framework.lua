-- Minimal test framework. Run from repo root: lua tests/run_all.lua
-- All test files share this singleton via require() caching.

local M = {}

local _passes    = 0
local _failures  = 0
local _errors    = {}
local _suiteName = nil
local _beforeEach = nil

---Opens a named suite. Resets before_each so each describe block is independent.
function M.describe(name, fn)
	_suiteName  = name
	_beforeEach = nil
	io.write("\n  " .. name .. "\n")
	fn()
	_suiteName  = nil
	_beforeEach = nil
end

---Registers a setup function that runs before every it() in the current describe block.
function M.before_each(fn)
	_beforeEach = fn
end

---Declares a single test case.
function M.it(name, fn)
	local ok, err = pcall(function()
		if _beforeEach then _beforeEach() end
		fn()
	end)
	if ok then
		_passes = _passes + 1
		io.write("    [pass] " .. name .. "\n")
	else
		_failures = _failures + 1
		io.write("    [FAIL] " .. name .. "\n")
		io.write("           " .. tostring(err) .. "\n")
		_errors[#_errors + 1] = string.format("(%s) %s\n           %s",
			_suiteName or "?", name, tostring(err))
	end
end

-- Assertions

function M.eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("[%s] expected %s, got %s",
			label or "eq", tostring(expected), tostring(actual)), 2)
	end
end

function M.neq(actual, unexpected, label)
	if actual == unexpected then
		error(string.format("[%s] expected something other than %s",
			label or "neq", tostring(actual)), 2)
	end
end

function M.is_nil(v, label)
	if v ~= nil then
		error(string.format("[%s] expected nil, got %s", label or "is_nil", tostring(v)), 2)
	end
end

function M.not_nil(v, label)
	if v == nil then
		error(string.format("[%s] expected non-nil", label or "not_nil"), 2)
	end
end

function M.truthy(v, label)
	if not v then
		error(string.format("[%s] expected truthy, got %s", label or "truthy", tostring(v)), 2)
	end
end

function M.falsy(v, label)
	if v then
		error(string.format("[%s] expected falsy, got %s", label or "falsy", tostring(v)), 2)
	end
end

function M.has_key(t, k, label)
	if t[k] == nil then
		error(string.format("[%s] expected key '%s' in table", label or "has_key", tostring(k)), 2)
	end
end

function M.no_key(t, k, label)
	if t[k] ~= nil then
		error(string.format("[%s] expected no key '%s' in table", label or "no_key", tostring(k)), 2)
	end
end

-- Summary

---Prints the pass/fail summary and returns true if all tests passed.
function M.summary()
	io.write(string.format("\n  %d passed, %d failed\n", _passes, _failures))
	if #_errors > 0 then
		io.write("\n  Failures:\n")
		for _, e in ipairs(_errors) do
			io.write("    " .. e .. "\n\n")
		end
	end
	return _failures == 0
end

return M
