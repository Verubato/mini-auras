-- Module lifecycle tests for the 12.1 container path: Alerts (pooled display pairs, chain
-- ordering), Nameplates (pooled bar displays, release semantics), and HealerCC (AddAuraSound
-- registration idempotency). Drives the REAL modules loaded against module_env.

local fw = require("framework")
local acm = require("aura_container_mock")
local moduleEnv = require("module_env")

local env = moduleEnv.build()
local db = env.db

-- Force everything relevant on, world context.
db.Modules.AlertsModule.Enabled.Always = true
db.Modules.AlertsModule.Icons.Enabled = true
db.Modules.AlertsModule.SplitBars = false
db.Modules.NameplatesModule.Enabled.Always = true
db.Modules.NameplatesModule.Enemy.Bar1.Enabled = true
db.Modules.NameplatesModule.Enemy.Bar2.Enabled = false
db.Modules.HealerCCModule.Enabled.Always = true
db.Modules.HealerCCModule.Sound.Enabled = true
db.Modules.HealerCCModule.Icons.Enabled = true

-- Load modules one at a time, capturing each module's event frame before the next load.
env.loadModule("src/Modules/AlertsModule.lua")
env.addon.Modules.AlertsModule:Init()
local alertsEvents = acm.lastFrameForEvent("NAME_PLATE_UNIT_ADDED")
assert(alertsEvents, "alerts event frame")

env.loadModule("src/Modules/NameplatesModule.lua")
env.addon.Modules.NameplatesModule:Init()
local nameplatesEvents = acm.lastFrameForEvent("NAME_PLATE_UNIT_ADDED")
assert(nameplatesEvents and nameplatesEvents ~= alertsEvents, "nameplates event frame")

env.loadModule("src/Modules/HealerCrowdControlModule.lua")

local function countAuraSoundSpells()
	local n = 0
	for _ in pairs(env.addon.Core.AuraSoundData.CC) do
		n = n + 1
	end
	return n
end

fw.describe("AlertsModule 12.1 - display pair lifecycle", function()
	fw.it("an enemy plate gets a Def+Imp container pair tracking its token", function()
		env.enemies.nameplate2 = true
		env.addPlate("nameplate2")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate2")

		local containers = env.containersForUnit("nameplate2")
		assert(#containers == 2, "expected Def+Imp pair, got " .. #containers)
		local groupCounts = { env.groupCount(containers[1]), env.groupCount(containers[2]) }
		table.sort(groupCounts)
		assert(groupCounts[1] == 1 and groupCounts[2] == 2, "one 1-group Imp and one 2-group Def")
		for _, container in ipairs(containers) do
			assert(container._enabled and container:IsShown(), "pair enabled and shown")
		end
	end)

	fw.it("a non-enemy plate gets nothing", function()
		env.addPlate("nameplate3")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate3")
		assert(#env.containersForUnit("nameplate3") == 0)
	end)

	fw.it("plate removal parks the pair and a new token reuses it", function()
		local before = env.containersForUnit("nameplate2")
		assert(#before == 2, "pair still assigned from previous test")

		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "nameplate2")
		for _, container in ipairs(before) do
			assert(not container._enabled and not container:IsShown(), "parked: disabled and hidden")
		end

		env.enemies.nameplate7 = true
		env.addPlate("nameplate7")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate7")
		local reused = env.containersForUnit("nameplate7")
		assert(#reused == 2, "new token got a pair")
		local reusedIdentity = (reused[1] == before[1] or reused[1] == before[2])
		assert(reusedIdentity, "the parked pair was reused, not recreated")
	end)

	fw.it("chains defensives in numeric token order with importants after all defensives", function()
		-- nameplate7 active from the previous test; add nameplate10 (sorts after 7 numerically,
		-- but between 1 and 7 lexicographically - the regression this locks in).
		env.enemies.nameplate10 = true
		env.addPlate("nameplate10")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate10")

		local function defOf(token)
			for _, container in ipairs(env.containersForUnit(token)) do
				if env.groupCount(container) == 2 then
					return container
				end
			end
		end
		local function impOf(token)
			for _, container in ipairs(env.containersForUnit(token)) do
				if env.groupCount(container) == 1 then
					return container
				end
			end
		end

		local def7, def10 = defOf("nameplate7"), defOf("nameplate10")
		local _, relativeTo = def10:GetPoint(1)
		assert(relativeTo == def7, "def(10) chains after def(7): numeric order")

		local imp7 = impOf("nameplate7")
		local _, impRelativeTo = imp7:GetPoint(1)
		assert(impRelativeTo == def10, "combined mode: first important chains after the LAST defensive")
	end)

	fw.it("Grow LEFT flips the chain: right edges pinned, negative spacing steps", function()
		db.Modules.AlertsModule.Grow = "LEFT"
		db.Modules.AlertsModule.IconSpacing = 2
		env.addon.Modules.AlertsModule:Refresh()

		local function defOf(token)
			for _, container in ipairs(env.containersForUnit(token)) do
				if env.groupCount(container) == 2 then
					return container
				end
			end
		end

		-- nameplate2, nameplate7 and nameplate10 are still active from the previous tests;
		-- nameplate2 sorts first, so it is the chain start.
		local def2 = defOf("nameplate2")
		local def7, def10 = defOf("nameplate7"), defOf("nameplate10")
		local point2, _, relativePoint2, x2 = def2:GetPoint(1)
		assert(point2 == "RIGHT" and relativePoint2 == "RIGHT" and x2 == 0,
			"chain start pins its RIGHT edge to the bar frame's RIGHT edge")
		local point10, relativeTo10, relativePoint10, x10 = def10:GetPoint(1)
		assert(point10 == "RIGHT" and relativeTo10 == def7 and relativePoint10 == "LEFT" and x10 == -2,
			"next link hangs off the previous display's LEFT edge with negative spacing")

		-- Back to the default; on 12.1 that behaves as RIGHT (LEFT edges, positive spacing).
		db.Modules.AlertsModule.Grow = "CENTER"
		env.addon.Modules.AlertsModule:Refresh()
		local pointAfter, _, relativePointAfter, xAfter = def10:GetPoint(1)
		assert(pointAfter == "LEFT" and relativePointAfter == "RIGHT" and xAfter == 2,
			"CENTER falls back to RIGHT growth on 12.1")
	end)

	fw.it("alert sounds register per enemy plate and unregister on release/disable", function()
		-- The healer sound tests later assert on the shared counters in absolute terms, so
		-- restore them at the end (net registrations here end at zero anyway).
		local adds0, removes0 = env.auraSoundAdds, env.auraSoundRemoves
		local perToken = 0
		for _ in pairs(env.addon.Core.AuraSoundData.Important) do
			perToken = perToken + 1
		end
		for _ in pairs(env.addon.Core.AuraSoundData.Defensive) do
			perToken = perToken + 1
		end
		assert(perToken > 0, "sound data present")

		local function net()
			return env.auraSoundAdds - env.auraSoundRemoves
		end

		-- nameplate2, nameplate7 and nameplate10 are active from the earlier tests.
		local baseline = net()
		db.Modules.AlertsModule.Sound.Important.Enabled = true
		db.Modules.AlertsModule.Sound.Defensive.Enabled = true
		env.addon.Modules.AlertsModule:Refresh()
		assert(net() - baseline == perToken * 3, "3 active tokens registered, net " .. (net() - baseline))

		-- A new enemy plate registers incrementally.
		env.enemies.nameplate11 = true
		env.addPlate("nameplate11")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate11")
		assert(net() - baseline == perToken * 4, "new plate registered")

		-- Releasing the plate removes exactly its registrations.
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "nameplate11")
		env.plates.nameplate11 = nil
		env.enemies.nameplate11 = nil
		assert(net() - baseline == perToken * 3, "released plate unregistered")

		-- Turning the sounds off clears the remaining registrations.
		db.Modules.AlertsModule.Sound.Important.Enabled = false
		db.Modules.AlertsModule.Sound.Defensive.Enabled = false
		env.addon.Modules.AlertsModule:Refresh()
		assert(net() - baseline == 0, "disable clears every registration")

		env.auraSoundAdds, env.auraSoundRemoves = adds0, removes0
	end)
end)

fw.describe("NameplatesModule 12.1 - pooled bar displays", function()
	fw.it("an enemy plate acquires a display parented to the plate with the right budgets", function()
		env.enemies.np_a = true
		local plate = env.addPlate("np_a")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_a")

		local containers = env.containersForUnit("np_a")
		assert(#containers == 1, "one display for one enabled bar, got " .. #containers)
		local display = containers[1]
		assert(display._parent == plate, "reparented to the plate")
		assert(display._enabled, "enabled")

		local barOptions = db.Modules.NameplatesModule.Enemy.Bar1
		local expected = barOptions.Icons.MaxIcons
		assert(display._groups.cc.maxFrameCount == (barOptions.ShowCC and expected or 0), "cc budget")
		assert(display._groups.important.maxFrameCount == (barOptions.ShowImportant and expected or 0), "important budget")
	end)

	fw.it("plate removal releases the display to the pool (parked on UIParent)", function()
		local display = env.containersForUnit("np_a")[1]
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "np_a")
		assert(not display._enabled and not display:IsShown(), "disabled and hidden")
		assert(display._parent == _G.UIParent, "reparented to UIParent")
	end)

	fw.it("the next plate reuses the released display", function()
		local parked = env.containersForUnit("np_a")[1]
		env.enemies.np_b = true
		local plate = env.addPlate("np_b")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_b")

		local display = env.containersForUnit("np_b")[1]
		assert(display == parked, "released display reused for the new token")
		assert(display._parent == plate and display._enabled, "reconfigured for the new plate")
	end)

	fw.it("an IgnorePets flip releases an already-tracked pet plate's display", function()
		env.enemies.np_pet = true
		env.pets.np_pet = true
		db.Modules.NameplatesModule.Enemy.IgnorePets = false
		env.addPlate("np_pet")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_pet")
		local display = env.containersForUnit("np_pet")[1]
		assert(display and display._enabled, "pet tracked while IgnorePets is off")

		db.Modules.NameplatesModule.Enemy.IgnorePets = true
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_pet")
		assert(not display._enabled and display._parent == _G.UIParent, "flip released the display")
	end)
end)

fw.describe("HealerCrowdControlModule 12.1 - AddAuraSound registration", function()
	local healerCC = env.addon.Modules.HealerCrowdControlModule
	local ccSpellCount = countAuraSoundSpells()

	fw.it("registers one sound per CC spell per healer", function()
		env.healers.party1 = true
		healerCC:Init()
		assert(env.auraSoundAdds == ccSpellCount,
			("expected %d adds, got %d"):format(ccSpellCount, env.auraSoundAdds))
	end)

	fw.it("a refresh with unchanged healers and settings registers nothing new", function()
		local before = env.auraSoundAdds
		healerCC:Refresh()
		assert(env.auraSoundAdds == before, "signature guard must skip re-registration")
		assert(env.auraSoundRemoves == 0, "and must not clear")
	end)

	fw.it("a sound-file change clears and re-registers", function()
		local addsBefore = env.auraSoundAdds
		db.Modules.HealerCCModule.Sound.File = "AirHorn.ogg"
		healerCC:Refresh()
		assert(env.auraSoundRemoves == addsBefore, "every previous registration removed")
		assert(env.auraSoundAdds == addsBefore + ccSpellCount, "full set re-registered")
	end)

	fw.it("a roster change re-registers for the new healer set", function()
		local addsBefore = env.auraSoundAdds
		env.healers.party2 = true
		healerCC:Refresh()
		assert(env.auraSoundAdds == addsBefore + 2 * ccSpellCount, "two healers registered")
	end)

	fw.it("disabling the sound clears everything", function()
		local addsBefore = env.auraSoundAdds
		local removesBefore = env.auraSoundRemoves
		db.Modules.HealerCCModule.Sound.Enabled = false
		healerCC:Refresh()
		assert(env.auraSoundAdds == addsBefore, "no new registrations")
		assert(env.auraSoundRemoves == removesBefore + 2 * ccSpellCount, "all registrations removed")
	end)
end)
