-- Cross-module smoke test for the 12.1 container path. Every module that draws auras is loaded
-- into one environment and driven through its whole lifecycle - init, refresh, test mode on and
-- off, disable, re-enable - while three invariants are watched:
--
--   * No legacy aura watcher is ever constructed (module_env's stub errors if one is). This is
--     the guard rail for deleting the legacy path: anything still reaching for it shows up here.
--   * Nothing is reported through mini:Notify. The one warning the container wrapper raises is
--     SetMaxIcons on a group key that does not exist, which otherwise silently switches a whole
--     category off.
--   * Every AuraContainer in existence is one the wrapper owns, proven by the Edit Mode preview
--     hiding all of them. A container built with a raw CreateFrame would keep rendering, which
--     means Blizzard's placeholder auras all over the UI while Edit Mode is open.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()

_G.UnitClassBase = function()
	return "PRIEST"
end

-- Portrait attaches to the Blizzard unit frames; give it something to find.
for _, name in ipairs({ "PlayerFrame", "TargetFrame", "FocusFrame", "PetFrame" }) do
	local frame = acm.NewFrame("Frame", name)
	local portrait = acm.NewFrame("Frame", name .. "Portrait", frame)
	portrait:SetSize(60, 60)
	frame.portrait = portrait
	_G[name] = frame
end

env.addUnitFrame("party1", "CUF_Smoke1")
env.addUnitFrame("party2", "CUF_Smoke2")
env.healers.party2 = true

-- Every module on the container path, in TOC order. Each is loaded, enabled for all contexts and
-- initialised; the event frame each one registers is captured before the next load so the plate
-- events can be driven per module.
local MODULES = {
	{ Name = "CrowdControlModule", Key = "CCModule" },
	{ Name = "FriendlyIndicatorModule", Key = "FriendlyIndicatorModule" },
	{ Name = "HealerCrowdControlModule", Key = "HealerCCModule" },
	{ Name = "PrecogGuesserModule", Key = "PrecogGuesserModule" },
	{ Name = "PortraitModule", Key = "PortraitModule" },
	{ Name = "NameplatesModule", Key = "NameplatesModule" },
	{ Name = "AlertsModule", Key = "AlertsModule" },
}

local modules = {}
for _, spec in ipairs(MODULES) do
	env.setModuleEnabled(spec.Key, true)
	env.loadModule("src/Modules/" .. spec.Name .. ".lua")
	local module = assert(env.addon.Modules[spec.Name], "module " .. spec.Name .. " did not register")
	module:Init()
	modules[#modules + 1] = { Name = spec.Name, Key = spec.Key, Module = module }
end

-- Plate-driven modules need plates; drive both modules' event frames.
local plateFrames = {}
for _, frame in ipairs(acm.frames) do
	if frame._events and frame._events.NAME_PLATE_UNIT_ADDED then
		plateFrames[#plateFrames + 1] = frame
	end
end

local function firePlateEvent(event, token)
	for _, frame in ipairs(plateFrames) do
		frame:TriggerEvent(event, token)
	end
end

local function refreshAll()
	for _, entry in ipairs(modules) do
		entry.Module:Refresh()
	end
end

local function auraContainers()
	local list = {}
	for _, frame in ipairs(acm.frames) do
		if frame._type == "AuraContainer" then
			list[#list + 1] = frame
		end
	end
	return list
end

fw.describe("12.1 smoke - full lifecycle across every container module", function()
	fw.it("initialises and refreshes without reaching for the legacy path", function()
		-- module_env's UnitAuraWatcher stub errors on construction, so getting here at all means
		-- no module built one during Init.
		assert(#auraContainers() > 0, "the modules actually built containers")
		refreshAll()
		refreshAll()
	end)

	fw.it("survives plate churn, test mode and a disable/enable cycle", function()
		env.enemies.nameplate1 = true
		env.addPlate("nameplate1")
		firePlateEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")

		for _, entry in ipairs(modules) do
			entry.Module:StartTesting()
			entry.Module:StopTesting()
		end

		for _, entry in ipairs(modules) do
			env.setModuleEnabled(entry.Key, false)
		end
		refreshAll()

		for _, entry in ipairs(modules) do
			env.setModuleEnabled(entry.Key, true)
		end
		refreshAll()

		firePlateEvent("NAME_PLATE_UNIT_REMOVED", "nameplate1")
		env.plates.nameplate1 = nil
		env.enemies.nameplate1 = nil
	end)

	fw.it("reported no misuse through the whole run", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)

	fw.it("every AuraContainer in the addon is owned by the wrapper", function()
		local displayEvents = assert(acm.lastFrameForEvent("AURA_DATA_PROVIDER_SWITCH"),
			"the wrapper's shared event frame")

		displayEvents:TriggerEvent("AURA_DATA_PROVIDER_SWITCH", false)

		local containers = auraContainers()
		assert(#containers > 0, "containers exist to check")
		for _, container in ipairs(containers) do
			assert(not container:IsShown(),
				"container " .. tostring(container._name) .. " escaped the Edit Mode suppression")
		end

		displayEvents:TriggerEvent("AURA_DATA_PROVIDER_SWITCH", true)
	end)
end)

fw.describe("12.1 smoke - per-module container shape", function()
	fw.it("precognition asks the engine for its two spells by id", function()
		-- The spell-id candidate filter IS the guess on 12.1; without it the display shows
		-- every important buff the player has.
		local precogGroup
		for _, container in ipairs(auraContainers()) do
			if container._groups.precog then
				precogGroup = container._groups.precog
			end
		end

		local auraFilters = env.addon.Core.AuraFilters
		assert(precogGroup, "the precognition display exists")
		assert(precogGroup.filterString == auraFilters.Filter.ImportantOnly,
			"unpartitioned importants, got " .. tostring(precogGroup.filterString))
		local filters = assert(precogGroup.options.candidateFilters, "candidate filters were passed through")
		-- Matched by id rather than by an upper bound on duration, which also let through any
		-- other short important self buff.
		assert(filters.includeSpellIDs, "a spell-id filter")
		assert(filters.includeSpellIDs[377362], "precognition")
		assert(filters.includeSpellIDs[378464], "nullifying shroud")
		assert(filters.maxDuration == nil, "no duration bound left")
	end)

	fw.it("every group on every container uses a filter from the shared set", function()
		-- Filter strings are validated loudly by the client, and the negations that keep the
		-- categories from overlapping only work if every module takes them from one place.
		local auraFilters = env.addon.Core.AuraFilters
		local known = {}
		for _, filterString in pairs(auraFilters.Filter) do
			known[filterString] = true
		end
		-- The friendly indicator filters helpful auras by spell id alone, so its group carries a
		-- bare token by design rather than one of the shared category strings.
		known["HELPFUL"] = true

		for _, container in ipairs(auraContainers()) do
			for key, group in pairs(container._groups) do
				assert(known[group.filterString],
					("group '%s' uses an ad-hoc filter: %s"):format(tostring(key), tostring(group.filterString)))
			end
		end
	end)
end)
