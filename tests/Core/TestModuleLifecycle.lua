-- The module lifecycle object: which of Setup, OnEnable, OnDisable and Apply run for a given
-- refresh. Level-triggered Apply, edge-triggered enable and disable, and Setup exactly once.

local fw = require("Framework")

local addon = { Core = {} }

assert(loadfile("src/Core/Lifecycle/ModuleLifecycle.lua"))("MiniAuras", addon)

local lifecycle = addon.Core.ModuleLifecycle

---Builds a lifecycle over a mutable state table, recording every callback it makes.
local function build(state)
	state.calls = {}
	state.applied = {}

	local function record(name)
		return function(options)
			state.calls[#state.calls + 1] = name
			if options then
				state.applied[#state.applied + 1] = options
			end
		end
	end

	return lifecycle:New({
		GetOptions = function()
			return state.options
		end,
		IsEnabled = function()
			return state.enabled
		end,
		Setup = record("setup"),
		OnEnable = record("enable"),
		OnDisable = record("disable"),
		Apply = record("apply"),
	})
end

fw.describe("ModuleLifecycle", function()
	fw.it("sets up and enables on the first enabled refresh", function()
		local state = { enabled = true, options = {} }
		local module = build(state)

		module:Refresh()

		fw.eq(table.concat(state.calls, ","), "setup,enable,apply")
		fw.eq(module:IsActive(), true)
	end)

	fw.it("does nothing at all while the module has never been enabled", function()
		local state = { enabled = false, options = {} }
		local module = build(state)

		module:Refresh()
		module:Refresh()

		fw.eq(#state.calls, 0)
		fw.eq(module:IsActive(), false)
	end)

	fw.it("applies on every refresh but only crosses each edge once", function()
		local state = { enabled = true, options = {} }
		local module = build(state)

		module:Refresh()
		module:Refresh()
		module:Refresh()

		fw.eq(table.concat(state.calls, ","), "setup,enable,apply,apply,apply")
	end)

	fw.it("disables once, then stays quiet", function()
		local state = { enabled = true, options = {} }
		local module = build(state)

		module:Refresh()
		state.enabled = false
		module:Refresh()
		module:Refresh()

		fw.eq(table.concat(state.calls, ","), "setup,enable,apply,disable")
	end)

	fw.it("sets up once however often the module is switched back on", function()
		local state = { enabled = true, options = {} }
		local module = build(state)

		module:Refresh()
		state.enabled = false
		module:Refresh()
		state.enabled = true
		module:Refresh()

		fw.eq(table.concat(state.calls, ","), "setup,enable,apply,disable,enable,apply")
	end)

	fw.it("hands the current options to Apply", function()
		local first, second = { n = 1 }, { n = 2 }
		local state = { enabled = true, options = first }
		local module = build(state)

		module:Refresh()
		state.options = second
		module:Refresh()

		fw.eq(state.applied[1], first)
		fw.eq(state.applied[2], second)
	end)

	fw.it("skips the refresh entirely when the settings are not readable yet", function()
		local state = { enabled = true, options = nil }
		local module = build(state)

		module:Refresh()

		fw.eq(#state.calls, 0)
		fw.eq(module:IsActive(), false)
	end)

	fw.it("never tears down over settings that went missing", function()
		local state = { enabled = true, options = {} }
		local module = build(state)

		module:Refresh()
		state.options = nil
		state.enabled = false
		module:Refresh()

		fw.eq(table.concat(state.calls, ","), "setup,enable,apply")
		fw.eq(module:IsActive(), true)
	end)

	fw.it("arms a module its settings have running, without enabling it", function()
		local state = { enabled = true, options = {} }
		local module = build(state)

		fw.eq(module:ArmEarly(), true)
		fw.eq(table.concat(state.calls, ","), "setup")
		fw.eq(module:IsActive(), false)

		module:Refresh()
		fw.eq(table.concat(state.calls, ","), "setup,enable,apply")
	end)

	fw.it("arms nothing when the settings have the module off", function()
		local state = { enabled = false, options = {} }
		local module = build(state)

		fw.eq(module:ArmEarly(), false)
		fw.eq(#state.calls, 0)
	end)

	fw.it("lets a caller force the setup a disabled module never ran", function()
		local state = { enabled = false, options = {} }
		local module = build(state)

		module:Refresh()
		module:EnsureSetup()
		module:EnsureSetup()

		fw.eq(table.concat(state.calls, ","), "setup")
		fw.eq(module:IsActive(), false)
	end)

	fw.it("does not set up twice when an enable follows a forced setup", function()
		local state = { enabled = false, options = {} }
		local module = build(state)

		module:EnsureSetup()
		state.enabled = true
		module:Refresh()

		fw.eq(table.concat(state.calls, ","), "setup,enable,apply")
	end)

	fw.it("treats anything other than true as disabled", function()
		local state = { enabled = nil, options = {} }
		local module = build(state)

		module:Refresh()

		fw.eq(#state.calls, 0)
	end)

	fw.it("works with only the callbacks a module actually needs", function()
		local enabled = true
		local module = lifecycle:New({
			IsEnabled = function()
				return enabled
			end,
		})

		module:Refresh()
		fw.eq(module:IsActive(), true)

		enabled = false
		module:Refresh()
		fw.eq(module:IsActive(), false)
	end)
end)
