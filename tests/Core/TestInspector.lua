-- Tests for Core/Inspect/Inspector.lua - the spec lookup the kick tracker leans on to guess
-- which ally interrupted. The bug guarded here: on 12.1 a unit the client will not let an addon
-- identify answers GetInspectSpecialization with a SECRET number, and comparing one aborts the
-- whole handler. A mouseover of a stranger is the everyday way to get one.

local fw = require("Framework")
local wow = require("WowApi")
wow.setup()
local acm = require("AuraContainerMock")
acm.setup()

-- Environment: the Inspector captures these at load and at Init.
local inspectSpecs = {}
local hooks = {}

-- RunLoop reschedules itself through C_Timer.After, and the shared mock runs deferred callbacks
-- straight away, so leaving it in place would recurse until the stack ran out.
_G.C_Timer.After = function() end

_G.GetTimePreciseSec = function()
	return _G.GetTime()
end
-- Solo: the run loop's own sweep of the roster finds nothing, so each test drives exactly the
-- one inspect it asks for.
_G.GetNumGroupMembers = function()
	return 0
end
_G.UnitIsFriend = function()
	return true
end
_G.CanInspect = function()
	return true
end
_G.GetInspectSpecialization = function(unit)
	return inspectSpecs[unit]
end
_G.hooksecurefunc = function(name, fn)
	hooks[name] = hooks[name] or {}
	hooks[name][#hooks[name] + 1] = fn
end
_G.NotifyInspect = function(unit)
	for _, hook in ipairs(hooks.NotifyInspect or {}) do
		hook(unit)
	end
end
_G.ClearInspectPlayer = function()
	for _, hook in ipairs(hooks.ClearInspectPlayer or {}) do
		hook()
	end
end

local savedVars = { SpecCache = {} }

local addon = {
	Framework = {
		GetSavedVars = function()
			return savedVars
		end,
	},
	Core = {},
	Modules = {},
	Utils = {},
	Config = {},
}

assert(loadfile("src/Core/Inspect/Inspector.lua"))("MiniAuras", addon)

local inspector = addon.Core.Inspector
inspector:Init()

---Drives one inspect the way the client does: the addon asks, the server answers.
---@param unit string
local function InspectReady(unit)
	_G.NotifyInspect(unit)
	acm.lastFrameForEvent("INSPECT_READY"):TriggerEvent("INSPECT_READY")
end

fw.describe("Inspector - a spec the client keeps secret", function()
	fw.before_each(function()
		wipe(savedVars.SpecCache)
		wipe(inspectSpecs)
	end)

	fw.it("survives a secret spec instead of aborting on the comparison", function()
		local secret = wow.markSecret({})
		inspectSpecs.mouseover = secret

		InspectReady("mouseover")

		assert(inspector:GetUnitSpecId("mouseover") == nil, "and nothing is claimed for the unit")
	end)

	fw.it("never caches one, so a later read cannot hit the same comparison", function()
		inspectSpecs.mouseover = wow.markSecret({})

		InspectReady("mouseover")

		assert(next(savedVars.SpecCache) == nil or savedVars.SpecCache.mouseover == nil
			or savedVars.SpecCache.mouseover.SpecId == nil,
			"a secret spec must never reach the saved cache")
	end)

	fw.it("still takes a readable spec", function()
		inspectSpecs.party1 = 256

		InspectReady("party1")

		assert(inspector:GetUnitSpecId("party1") == 256, "the ordinary path is untouched")
	end)
end)
