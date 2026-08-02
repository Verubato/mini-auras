-- Module lifecycle tests for the 12.1 container path: Alerts (pooled display pairs, chain
-- ordering), Nameplates (pooled bar displays, release semantics), and HealerCC (AddAuraSound
-- registration idempotency). Drives the REAL modules loaded against module_env.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

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
	for _ in pairs(env.addon.Core.AuraCategoryIds.CC) do
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
		assert(groupCounts[1] == 1 and groupCounts[2] == 3,
			"one 1-group Imp and one 3-group Def (big, external, important)")
		-- Combined mode renders importants inside Def, so only Def is live.
		local def = groupCounts[2] == env.groupCount(containers[1]) and containers[1] or containers[2]
		assert(def._enabled and def:IsShown(), "the defensive container is enabled and shown")
	end)

	fw.it("a non-enemy plate gets nothing", function()
		env.addPlate("nameplate3")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate3")
		assert(#env.containersForUnit("nameplate3") == 0)
	end)

	fw.it("plate removal parks the pair, and the token gets it back on return", function()
		local before = env.containersForUnit("nameplate2")
		assert(#before == 2, "pair still assigned from previous test")

		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "nameplate2")
		for _, container in ipairs(before) do
			assert(not container._enabled and not container:IsShown(), "parked: disabled and hidden")
		end

		-- Pairs are built per token rather than pooled, because the style is baked into each
		-- button at creation and can't be restyled while auras are secret. So another token
		-- gets its own pair...
		env.enemies.nameplate7 = true
		env.addPlate("nameplate7")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate7")
		local other = env.containersForUnit("nameplate7")
		assert(#other == 2, "new token got its own pair")
		assert(other[1] ~= before[1] and other[1] ~= before[2],
			"a different token must not inherit another token's pair")

		-- ...and nameplate2 picks its own back up, which is what bounds frame growth.
		env.addPlate("nameplate2")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate2")
		local returned = env.containersForUnit("nameplate2")
		assert(returned[1] == before[1] and returned[2] == before[2], "the token's own pair is reused")
	end)

	fw.it("chains defensives in numeric token order with importants after all defensives", function()
		-- nameplate7 active from the previous test; add nameplate10 (sorts after 7 numerically,
		-- but between 1 and 7 lexicographically - the regression this locks in).
		env.enemies.nameplate10 = true
		env.addPlate("nameplate10")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate10")

		local function defOf(token)
			for _, container in ipairs(env.containersForUnit(token)) do
				if env.groupCount(container) == 3 then
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

		-- Combined mode draws importants inside each Def container rather than chaining a
		-- separate frame, which is what keeps the row free of reserved-width gaps.
		assert(def7._groups.important.maxFrameCount > 0, "importants ride along on the Def container")
		assert(not impOf("nameplate7"):IsShown(), "the dedicated important container stays parked")
	end)

	fw.it("Grow LEFT flips the chain: right edges pinned, negative spacing steps", function()
		db.Modules.AlertsModule.Grow = "LEFT"
		db.Modules.AlertsModule.IconSpacing = 2
		env.addon.Modules.AlertsModule:Refresh()

		local function defOf(token)
			for _, container in ipairs(env.containersForUnit(token)) do
				if env.groupCount(container) == 3 then
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

	fw.it("alert sounds register per enemy plate and stay warm across despawns", function()
		-- The healer sound tests later assert on the shared counters in absolute terms, so
		-- restore them at the end (net registrations here end at zero anyway).
		local adds0, removes0 = env.auraSoundAdds, env.auraSoundRemoves
		-- Some spells are deliberately silent (SILENT_ALERT_SPELL_IDS in the module): they show
		-- an icon but register no sound, so they do not count towards the expected total.
		local silent = env.addon.Modules.AlertsModule.SilentAlertSpellIds
		local perToken = 0
		for id in pairs(env.addon.Core.AuraCategoryIds.Important) do
			if not silent[id] then
				perToken = perToken + 1
			end
		end
		for id in pairs(env.addon.Core.AuraCategoryIds.Defensive) do
			if not silent[id] then
				perToken = perToken + 1
			end
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

		-- Despawn keeps the token's registrations warm: the set is identical for whichever
		-- enemy the token is recycled to, so removal would be pure API churn.
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "nameplate11")
		assert(net() - baseline == perToken * 4, "despawn keeps registrations warm")

		-- The token recycled to another enemy re-registers nothing.
		local addsBefore = env.auraSoundAdds
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate11")
		assert(env.auraSoundAdds == addsBefore, "warm token re-adds nothing")

		-- The token recycled to a NON-enemy drops its registrations.
		env.enemies.nameplate11 = nil
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate11")
		assert(net() - baseline == perToken * 3, "non-enemy recycle removed the token's registrations")

		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "nameplate11")
		env.plates.nameplate11 = nil

		-- Turning the sounds off clears the remaining registrations, warm ones included.
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

	fw.it("each token keeps its own display, and gets it back when it returns", function()
		-- Displays are built per token now rather than pooled, because every style value is
		-- baked into a button at creation and can't be changed while auras are secret. A
		-- different token therefore gets a different display.
		local parked = env.containersForUnit("np_a")[1]
		env.enemies.np_b = true
		local plate = env.addPlate("np_b")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_b")

		local display = env.containersForUnit("np_b")[1]
		assert(display ~= parked, "a different token must not inherit another token's display")
		assert(display._parent == plate and display._enabled, "configured for its own plate")

		-- np_a coming back reuses what it had; that is what bounds frame growth, since WoW
		-- can never free a frame.
		env.addPlate("np_a")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_a")
		assert(env.containersForUnit("np_a")[1] == parked, "the token's own display is reused")
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

fw.describe("Duel faction flip - poll-based re-registration", function()
	fw.it("alerts: a friendly plate that turns enemy gains displays and sound registrations", function()
		local adds0, removes0 = env.auraSoundAdds, env.auraSoundRemoves
		db.Modules.AlertsModule.Sound.Important.Enabled = true
		db.Modules.AlertsModule.Sound.Defensive.Enabled = true
		env.addon.Modules.AlertsModule:Refresh()
		local function net()
			return env.auraSoundAdds - env.auraSoundRemoves
		end
		local netBefore = net()

		env.addPlate("nameplate20")
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "nameplate20")
		assert(#env.containersForUnit("nameplate20") == 0, "friendly plate starts untracked")

		-- Duel starts: the unit becomes an enemy with no event; only the poll can see it.
		env.enemies.nameplate20 = true
		acm.tickAll(1)
		local containers = env.containersForUnit("nameplate20")
		assert(#containers == 2, "duel opponent gained a Def+Imp pair, got " .. #containers)
		-- Combined mode only enables the Def container; the Imp one is parked until bars split.
		local live = 0
		for _, container in ipairs(containers) do
			if container._enabled then
				live = live + 1
			end
		end
		assert(live >= 1, "at least the defensive container is enabled")
		assert(net() > netBefore, "alert sounds registered for the duel opponent")

		-- Duel ends: the flip back releases the pair and its sound registrations.
		env.enemies.nameplate20 = nil
		acm.tickAll(1)
		for _, container in ipairs(containers) do
			assert(not container._enabled, "duel end released the pair")
		end
		assert(net() == netBefore, "duel end removed the opponent's sound registrations")

		-- Restore the shared sound state and counters for the healer tests below.
		alertsEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "nameplate20")
		env.plates.nameplate20 = nil
		db.Modules.AlertsModule.Sound.Important.Enabled = false
		db.Modules.AlertsModule.Sound.Defensive.Enabled = false
		env.addon.Modules.AlertsModule:Refresh()
		env.auraSoundAdds, env.auraSoundRemoves = adds0, removes0
	end)

	fw.it("nameplates: the same flip rebuilds the bars with the other faction's options", function()
		db.Modules.NameplatesModule.Friendly.Bar1.Enabled = false
		db.Modules.NameplatesModule.Friendly.Bar2.Enabled = false

		local plate = env.addPlate("np_duel")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_duel")
		assert(#env.containersForUnit("np_duel") == 0, "friendly plate starts bare with Friendly bars off")

		env.enemies.np_duel = true
		acm.tickAll(1)
		local containers = env.containersForUnit("np_duel")
		assert(#containers == 1, "enemy Bar1 display acquired on duel start, got " .. #containers)
		assert(containers[1]._parent == plate and containers[1]._enabled, "parented to the plate and enabled")

		env.enemies.np_duel = nil
		acm.tickAll(1)
		assert(not containers[1]._enabled and containers[1]._parent == _G.UIParent, "duel end released the display")

		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "np_duel")
		env.plates.np_duel = nil
	end)

	fw.it("plates inside instances are not polled", function()
		env.inInstance = true
		env.instanceType = "party"
		env.addPlate("np_dungeon")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_dungeon")
		env.enemies.np_dungeon = true
		acm.tickAll(1)
		assert(#env.containersForUnit("np_dungeon") == 0, "no rebuild while instanced")

		env.inInstance = false
		env.instanceType = "none"
		acm.tickAll(1)
		assert(#env.containersForUnit("np_dungeon") == 1, "flip picked up once back in the world")

		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", "np_dungeon")
		env.plates.np_dungeon = nil
		env.enemies.np_dungeon = nil
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

	fw.it("a healer joining registers only that healer", function()
		local addsBefore = env.auraSoundAdds
		local removesBefore = env.auraSoundRemoves
		env.healers.party2 = true
		healerCC:Refresh()
		assert(env.auraSoundAdds == addsBefore + ccSpellCount,
			("only the new healer registers, expected %d adds, got %d")
				:format(addsBefore + ccSpellCount, env.auraSoundAdds))
		assert(env.auraSoundRemoves == removesBefore, "the existing healer's registrations are kept")
	end)

	fw.it("a healer leaving removes only that healer", function()
		local addsBefore = env.auraSoundAdds
		local removesBefore = env.auraSoundRemoves
		env.healers.party2 = nil
		healerCC:Refresh()
		assert(env.auraSoundRemoves == removesBefore + ccSpellCount,
			("only the departed healer unregisters, expected %d removes, got %d")
				:format(removesBefore + ccSpellCount, env.auraSoundRemoves))
		assert(env.auraSoundAdds == addsBefore, "no re-registration of the healers that stayed")

		-- Restore the two-healer set the following test expects.
		env.healers.party2 = true
		healerCC:Refresh()
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

fw.describe("NameplatesModule 12.1 - the pool never leaks", function()
	-- Every path that stops tracking a plate has to hand its displays back. A display that
	-- escapes the pool has no symptom until the pool runs dry and plates start building
	-- containers on demand - and then two plates can end up sharing one, which draws one
	-- enemy's auras on another's nameplate. Total containers created is the observable: a
	-- released display gets reused, a leaked one forces a new one.

	local nameplates = env.addon.Modules.NameplatesModule

	local function addPlate(token, isEnemy)
		env.enemies[token] = isEnemy ~= false or nil
		env.addPlate(token)
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", token)
	end

	local function removePlate(token)
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_REMOVED", token)
		env.plates[token] = nil
		env.enemies[token] = nil
	end

	---Displays actually driving a token. A parked display keeps whatever unit it last tracked
	---until it is acquired again (harmless - a disabled container unregisters its events), so
	---the unit lookup alone would count displays that are back in the pool.
	local function activeDisplays(token)
		local list = {}
		for _, container in ipairs(env.containersForUnit(token)) do
			if container._enabled then
				list[#list + 1] = container
			end
		end
		return list
	end

	fw.it("a repeated ADD for the same token carries its displays over", function()
		-- Re-adds are routine: RebuildContainers replays every live plate through
		-- OnNamePlateAdded whenever the enabled bars change.
		addPlate("np_leak1")
		local display = env.containersForUnit("np_leak1")[1]
		local created = env.auraContainerCount()

		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_leak1")
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_leak1")

		assert(env.auraContainerCount() == created, "re-adds must not build new containers")
		assert(env.containersForUnit("np_leak1")[1] == display, "the same display stayed on the plate")
		assert(display._enabled, "and it is still live")
	end)

	fw.it("toggling a bar releases and re-acquires rather than discarding", function()
		-- Flipping an enabled bar is what drives RebuildContainers, i.e. a re-ADD for every
		-- live plate.
		db.Modules.NameplatesModule.Enemy.Bar2.Enabled = true
		nameplates:Refresh()
		assert(#activeDisplays("np_leak1") == 2, "both bars have a display")
		local created = env.auraContainerCount()

		db.Modules.NameplatesModule.Enemy.Bar2.Enabled = false
		nameplates:Refresh()
		assert(#activeDisplays("np_leak1") == 1, "the disabled bar gave its display back")
		assert(env.auraContainerCount() == created, "released, not discarded")

		db.Modules.NameplatesModule.Enemy.Bar2.Enabled = true
		nameplates:Refresh()
		assert(#activeDisplays("np_leak1") == 2, "and it comes back")
		assert(env.auraContainerCount() == created, "out of the pool, without building anything new")

		db.Modules.NameplatesModule.Enemy.Bar2.Enabled = false
		nameplates:Refresh()
	end)

	fw.it("churn on one token creates containers only once", function()
		-- The per-token cache is what keeps frame growth bounded: a token that spawns and
		-- despawns repeatedly must not build a container each time, because WoW frames can
		-- never be freed.
		removePlate("np_leak1")

		addPlate("np_churn")
		assert(#activeDisplays("np_churn") == 1, "tracked by the one enabled bar")
		removePlate("np_churn")

		local created = env.auraContainerCount()

		for _ = 1, 5 do
			addPlate("np_churn")
			assert(#activeDisplays("np_churn") == 1, "still tracked by the one enabled bar")
			removePlate("np_churn")
		end

		assert(env.auraContainerCount() == created,
			"further cycles must reuse the token's display, got " .. (env.auraContainerCount() - created) .. " extra")
	end)

	fw.it("dragging the icon size restyles instead of building a display per size", function()
		-- Every step of a slider drag reaches Refresh. Keying displays on the configuration meant
		-- a drag left one display per intermediate size on every tracked plate - twenty buttons
		-- apiece - and WoW can never free them.
		addPlate("np_resize")
		local display = activeDisplays("np_resize")[1]
		assert(display, "tracked by the one enabled bar")
		local created = env.auraContainerCount()

		local icons = db.Modules.NameplatesModule.Enemy.Bar1.Icons
		local originalSize = icons.Size

		for size = 30, 40 do
			icons.Size = size
			nameplates:Refresh()
		end

		assert(env.auraContainerCount() == created,
			"a drag must build nothing, got " .. (env.auraContainerCount() - created) .. " extra")
		assert(activeDisplays("np_resize")[1] == display, "the same display throughout")

		local group = select(2, next(display._groups))
		assert(group.layout.elementWidth == 40, "and it ends up at the size dragged to")

		icons.Size = originalSize
		nameplates:Refresh()
		removePlate("np_resize")
	end)

	fw.it("a token that flips faction restyles its display instead of building another", function()
		-- GetUnitOptions returns Friendly or Enemy for the same token, and a duel flips it
		-- mid-session. Building a display per configuration would strand a frame on every flip,
		-- and WoW can never free one - so the one display is restyled in place.
		-- Mirror the enemy bar's configuration so only the size differs.
		local enemyBar = db.Modules.NameplatesModule.Enemy.Bar1
		local friendlyBar = db.Modules.NameplatesModule.Friendly.Bar1
		for key, value in pairs(enemyBar) do
			if key ~= "Icons" then
				friendlyBar[key] = value
			end
		end
		for key, value in pairs(enemyBar.Icons) do
			friendlyBar.Icons[key] = value
		end
		friendlyBar.Enabled = true
		friendlyBar.Icons.Size = 21
		enemyBar.Icons.Size = 44
		nameplates:Refresh()

		addPlate("np_flip", false)
		-- The icon size is baked into the group layout at creation, so that is where it is
		-- observable from the outside.
		local function iconSize(container)
			for _, group in pairs(container._groups) do
				return group.layout and group.layout.elementWidth
			end
		end

		local friendly = activeDisplays("np_flip")[1]
		assert(friendly and iconSize(friendly) == 21, "built at the friendly size")

		local created = env.auraContainerCount()

		-- Duel starts: same token, now an enemy.
		env.enemies.np_flip = true
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_flip")
		local enemy = activeDisplays("np_flip")[1]
		assert(enemy == friendly, "the same display, restyled rather than replaced")
		assert(iconSize(enemy) == 44, "resized to the enemy size")
		assert(env.auraContainerCount() == created, "the flip builds nothing new")

		-- Duel ends: back to friendly, and it restyles back.
		env.enemies.np_flip = nil
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_flip")
		assert(iconSize(activeDisplays("np_flip")[1]) == 21, "restyled back to the friendly size")
		assert(env.auraContainerCount() == created, "flipping back builds nothing new")

		removePlate("np_flip")
		db.Modules.NameplatesModule.Friendly.Bar1.Enabled = false
		nameplates:Refresh()
	end)

	fw.it("a plate that stops qualifying parks its display instead of leaving it live", function()
		-- The module can stop tracking a plate without a removal event: the module is switched
		-- off, or the unit turns out to be a pet with IgnorePets on. Both re-enter through
		-- OnNamePlateAdded, which has to park what the token was already holding.
		addPlate("np_drop")
		local display = activeDisplays("np_drop")[1]
		assert(display and display._enabled, "tracked to begin with")

		local created = env.auraContainerCount()

		env.setModuleEnabled("NameplatesModule", false)
		nameplatesEvents:TriggerEvent("NAME_PLATE_UNIT_ADDED", "np_drop")

		assert(not display._enabled and not display:IsShown(), "parked when it stopped qualifying")
		assert(display._parent == _G.UIParent, "and reparented off the plate")

		-- Re-qualifying reuses the same display rather than building another.
		env.setModuleEnabled("NameplatesModule", true)
		db.Modules.NameplatesModule.Enemy.Bar1.Enabled = true
		addPlate("np_drop")

		assert(activeDisplays("np_drop")[1] == display, "the parked display is picked back up")
		assert(env.auraContainerCount() == created, "and no new container was built")

		removePlate("np_drop")
	end)

	fw.it("nothing in the module's lifecycle was reported as misuse", function()
		-- Catches a group key that exists in one file and not the other: SetMaxIcons only warns,
		-- so a typo would silently switch a whole category off with no other symptom.
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
