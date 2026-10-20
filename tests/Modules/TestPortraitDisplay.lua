-- Portrait module, 12.1 container path: the layered single-icon stack over a unit frame portrait.
--
-- A portrait shows one icon but cannot ask which aura wins, since aura presence is secret, so it
-- gets five single-icon containers stacked by frame level and lets the higher-priority one cover
-- the rest. The levels must be distinct, because same-level siblings draw in an arbitrary order.
-- Two things about the arrangement are invisible when they break:
--
--   * Frame levels. Putting the stack below the kick frame puts it behind TargetFrame's own
--     textures, with no errors and no icons. The order is asserted here.
--   * Going through the wrapper. A raw CreateFrame("AuraContainer") stays out of the Edit Mode
--     suppression list and would show Blizzard's placeholder auras over every portrait.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()

env.setModuleEnabled("Portrait", true)

-- Blizzard unit frames. The portrait is a texture in the client, and the mock models it as a
-- child frame so it can carry a parent, a size and a rect.
local PORTRAIT_SIZE = 60
for _, spec in ipairs({
	{ Global = "PlayerFrame", Unit = "player", Level = 1 },
	{ Global = "TargetFrame", Unit = "target", Level = 500 },
	{ Global = "FocusFrame", Unit = "focus", Level = 500 },
	{ Global = "PetFrame", Unit = "pet", Level = 3 },
}) do
	local frame = acm.NewFrame("Frame", spec.Global)
	frame:SetFrameLevel(spec.Level)
	local portrait = acm.NewFrame("Frame", spec.Global .. "Portrait", frame)
	portrait:SetSize(PORTRAIT_SIZE, PORTRAIT_SIZE)
	-- A single anchor point, which is what the demoted portrait layer needs to reproduce.
	portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -5)
	frame.portrait = portrait
	_G[spec.Global] = frame
end

env.loadModule("src/Modules/Portrait/Observer.lua")
env.loadModule("src/Modules/Portrait/Display.lua")
env.loadModule("src/Modules/Portrait/Anchors.lua")
env.loadModule("src/Modules/Portrait/Module.lua")
local module = env.addon.Modules.PortraitModule

-- The interrupt icon is a slot on the container rather than a display, so what a setting did to it
-- can only be read off the options KickSlot was handed.
local kickSlot = env.addon.Core.KickSlot
local kickHideNumbers
local realKickSlotRender = kickSlot.Render

kickSlot.Render = function(self, container, kickEntry, slotOptions, previousTimer, onExpired)
	if kickEntry then
		kickHideNumbers = slotOptions.HideNumbers
	end

	return realKickSlotRender(self, container, kickEntry, slotOptions, previousTimer, onExpired)
end

module:Init()
-- Init only builds the lifecycle. A module sets itself up on the first refresh that finds it
-- enabled, which in the addon is the one PLAYER_ENTERING_WORLD drives.
module:Refresh()

-- The wrapper's shared event frame, created with the first display, so it exists by now.
local displayEvents = assert(acm.lastFrameForEvent("AURA_DATA_PROVIDER_SWITCH"),
	"the display wrapper listens for the Edit Mode data provider switch")
local unitChangeEvents = assert(acm.lastFrameForEvent("PLAYER_TARGET_CHANGED"),
	"the 12.1 path registers its own target/focus refresh")

local function containerFor(unit)
	for _, container in ipairs(module:GetContainers()) do
		if container.AuraUnit == unit then
			return container
		end
	end
end

-- A portrait's displays are created with none of their groups: the whole stack is built in one
-- pass and each group costs a batch of buttons, so the background walker declares them a group per
-- turn. Reading one back means letting that walk run first.
local function settleGroups()
	acm.tickAll(40)
end

-- A switched-off unit's container leaves the module's list but is kept for when it comes back, so
-- the last one seen stands in for it.
local lastSeen = {}

local function displaysFor(unit)
	settleGroups()

	local container = assert(containerFor(unit), "no portrait container for " .. unit)
	lastSeen[unit] = container
	return assert(container.AuraDisplay, "no aura display stack").Displays, container
end

-- The displays of a unit that may be switched off, from the container last seen while it was on.
local function parkedDisplaysFor(unit)
	settleGroups()

	local container = containerFor(unit) or assert(lastSeen[unit], "no portrait container seen for " .. unit)
	return assert(container.AuraDisplay, "no aura display stack").Displays
end

-- The player's portrait carries the user's own spell list under the five flagged categories.
local function expectedDisplayCount(unit)
	return unit == "player" and 6 or 5
end

local function portraitOptions()
	return env.db.Modules.Portrait
end

fw.describe("Portrait 12.1 - the five-category stack", function()
	fw.it("builds one single-icon display per category on every portrait", function()
		local disarmKey = env.addon.Core.AuraFilters.GroupKey.Disarm
		for _, unit in ipairs({ "player", "target", "focus", "pet" }) do
			local displays = displaysFor(unit)
			local expected = expectedDisplayCount(unit)
			assert(#displays == expected,
				unit .. ": expected " .. expected .. " displays, got " .. #displays)

			for _, display in ipairs(displays) do
				assert(#display.Groups == 1, "one group per display")
				local group = display.Groups[1]
				-- The disarm layer starts budgeted away: every occupant is assistable in this
				-- env, and the engine skips the layer's spell-ID filter on assistable units.
				-- The custom layer starts away too, since nothing has been added to it yet.
				local budget = (group.Key == disarmKey or group.Key == "portraitcustom") and 0 or 1
				assert(group.MaxIcons == budget, "a portrait shows exactly one icon per category")
				assert(display.Frame._groups[group.Key].maxFrameCount == budget, "budget reached the container")
				assert(display.Frame:GetUnit() == unit, "tracking its own unit")
			end
		end
	end)

	fw.it("covers the five partitioned categories exactly once, lowest priority first", function()
		local displays = displaysFor("target")
		local auraFilters = env.addon.Core.AuraFilters
		local expected = {
			{ Key = auraFilters.GroupKey.Important, Filter = auraFilters.Filter.Important },
			{ Key = auraFilters.GroupKey.ExternalDefensive, Filter = auraFilters.Filter.ExternalDefensive },
			{ Key = auraFilters.GroupKey.BigDefensive, Filter = auraFilters.Filter.BigDefensive },
			{ Key = auraFilters.GroupKey.Disarm, Filter = auraFilters.Filter.Disarm },
			{ Key = auraFilters.GroupKey.CrowdControl, Filter = auraFilters.Filter.CrowdControl },
		}

		for index, spec in ipairs(expected) do
			local group = displays[index].Groups[1]
			assert(group.Key == spec.Key,
				("display %d: expected %s, got %s"):format(index, spec.Key, tostring(group.Key)))
			-- The partitioned filters, not the bare ones: a defensive that is also important
			-- must not light up two layers of the same portrait at once.
			assert(group.FilterString == spec.Filter, "the shared partitioned filter for " .. spec.Key)
		end
	end)

	fw.it("takes the newest aura and no border, glow or mouse input", function()
		local displays = displaysFor("player")
		for _, display in ipairs(displays) do
			assert(display.Minimal, "portrait icons carry no dispel border and no glow")
			assert(display.Groups[1].SortDirection == _G.AuraContainerSortDirection.Reverse,
				"newest instance id first, matching the legacy Reverse sort")
			assert(display.Style.ShowTooltips == false,
				"styled at creation, so the buttons never have mouse input over the portrait")
			local widgets = select(2, next(display.ButtonWidgets))
			assert(widgets.Border == nil and widgets.Glow == nil, "no chrome widgets built")
		end
	end)
end)

fw.describe("Portrait 12.1 - the countdown numbers", function()
	---Whether the portrait icons have dropped their countdown, read off a button the engine built
	---for the top layer of the stack.
	---@return boolean
	local function NumbersHidden()
		local displays = displaysFor("target")
		local display = displays[#displays]
		local group = assert(display.Frame._groups[display.Groups[1].Key], "the layer has a group")
		local button = assert(group.buttons[1], "the group built a button")
		local cooldown = assert(button._lastArgs.SetDurationCooldown, "the button was given a cooldown")[1]

		return cooldown._lastArgs.SetHideCountdownNumbers[1]
	end

	---Lands a kick on the target and reports whether the icon it drew dropped its countdown.
	---@return boolean
	local function KickNumbersHidden()
		kickHideNumbers = "unset"

		env.kicks.target = {
			Texture = "tex:kick",
			DurationObject = {},
			StartTime = 0,
			Duration = 3,
		}
		env.fireKick("target")

		assert(kickHideNumbers ~= "unset", "fixture: firing a kick reached KickSlot:Render")

		return kickHideNumbers
	end

	---Whether the stand-in the preview draws over the portrait dropped its countdown.
	---@return boolean
	local function PreviewNumbersHidden()
		module:StartTesting()

		local container = assert(containerFor("target"), "no portrait container for target")
		local layer = assert(container.Slots[1].Container, "the preview filled the portrait's slot")
		local hidden = layer.Cooldown._lastArgs.SetHideCountdownNumbers[1]

		module:StopTesting()

		return hidden
	end

	fw.before_each(function()
		portraitOptions().EnableNumbers = true
		env.db.DisableNumbers = false
		module:Refresh()
	end)

	fw.it("keeps counting down while the switch is on", function()
		assert(NumbersHidden() == false, "the portrait icon shows its countdown")
	end)

	fw.it("counts down for a profile saved before the switch existed", function()
		portraitOptions().EnableNumbers = nil
		module:Refresh()

		assert(NumbersHidden() == false, "a missing switch reads as on")
	end)

	fw.it("drops the countdown once the switch is off", function()
		portraitOptions().EnableNumbers = false
		module:Refresh()

		assert(NumbersHidden() == true, "the switch takes the numbers off")

		portraitOptions().EnableNumbers = true
		module:Refresh()
	end)

	fw.it("takes them off the interrupt icon too, which is a slot rather than an aura", function()
		assert(KickNumbersHidden() == false, "the interrupt icon counts down with the switch on")

		portraitOptions().EnableNumbers = false
		module:Refresh()

		assert(KickNumbersHidden() == true, "and drops the numbers when the portrait icon does")
	end)

	fw.it("takes them out of the preview the switch is read against", function()
		assert(PreviewNumbersHidden() == false, "the stand-in counts down like the live icon")

		portraitOptions().EnableNumbers = false
		module:Refresh()

		assert(PreviewNumbersHidden() == true, "and drops the numbers when the live icon does")

		portraitOptions().EnableNumbers = true
		module:Refresh()
	end)
end)

fw.describe("Portrait 12.1 - the custom spell layer", function()
	local CUSTOM_KEY = "portraitcustom"
	local FEINT = 1966

	local function customDisplay(unit)
		local _, container = displaysFor(unit)
		return container.AuraDisplay.CustomDisplay
	end

	---@param ... number Spell ids to tick; none clears the list.
	local function setCustomSpells(...)
		local ticked = {}

		for _, spellId in ipairs({ ... }) do
			ticked[spellId] = true
		end

		portraitOptions().CustomSpells = ticked
		module:Refresh()
	end

	fw.it("hangs off the player's portrait and nothing else", function()
		-- The engine honours a helpful spell-id map only on a unit you can assist. Only the
		-- player token is always one, and everywhere else the map would be dropped and the
		-- layer would show every buff on the unit.
		assert(customDisplay("player"), "the player's portrait carries the custom layer")

		for _, unit in ipairs({ "target", "focus", "pet" }) do
			assert(customDisplay(unit) == nil, unit .. ": no custom layer")
		end
	end)

	fw.it("sits under every flagged category", function()
		local displays = displaysFor("player")

		assert(displays[1] == customDisplay("player"), "the custom layer is the bottom of the stack")

		for index = 2, #displays do
			assert(displays[index].Frame:GetFrameLevel() > displays[1].Frame:GetFrameLevel(),
				"display " .. index .. " covers the custom layer")
		end
	end)

	fw.it("stays budgeted away while nothing is ticked", function()
		-- Its filter string is a bare HELPFUL: with no spell map behind it and a budget to
		-- spend, the layer would show whichever buff the player last gained.
		setCustomSpells()
		settleGroups()

		local frame = customDisplay("player").Frame
		assert(frame._groups[CUSTOM_KEY].maxFrameCount == 0, "nothing to show, nothing budgeted")
		assert(frame._groups[CUSTOM_KEY].candidateFilters == nil, "and no spell map to match on")
	end)

	fw.it("opens with the spells that are ticked, and closes again when they are cleared", function()
		setCustomSpells(FEINT)
		settleGroups()

		local frame = customDisplay("player").Frame
		local group = frame._groups[CUSTOM_KEY]
		assert(group.maxFrameCount == 1, "one icon once there is something to show")
		assert(group.candidateFilters and group.candidateFilters.includeSpellIDs[FEINT],
			"the tracked id reached the container")

		local matched = 0

		for _ in pairs(group.candidateFilters.includeSpellIDs) do
			matched = matched + 1
		end

		assert(matched == 1, "and nothing else, since the ticked ids are matched exactly")

		setCustomSpells()
		assert(group.maxFrameCount == 0, "clearing the list closes the layer again")
	end)

	fw.it("matches an added id the way it matches a ticked one, and drops it once removed", function()
		-- A made-up id the shipped list has never carried.
		local ADDED = 424242

		setCustomSpells(FEINT)
		portraitOptions().AddedSpells[ADDED] = true
		module:Refresh()
		settleGroups()

		local group = customDisplay("player").Frame._groups[CUSTOM_KEY]
		local ids = group.candidateFilters and group.candidateFilters.includeSpellIDs

		assert(ids and ids[ADDED] == true, "the added id reached the container")
		assert(ids[FEINT] == true, "beside the ticked one")
		assert(group.maxFrameCount == 1, "with the layer open")

		setCustomSpells()
		assert(group.candidateFilters.includeSpellIDs[ADDED] == true, "an added id alone keeps the layer open")
		assert(group.maxFrameCount == 1, "with its budget")

		portraitOptions().AddedSpells[ADDED] = nil
		module:Refresh()

		assert(group.candidateFilters == nil, "removing it takes the map away")
		assert(group.maxFrameCount == 0, "and closes the layer")
	end)

	fw.it("allocates its buttons up front, so a later addition can render", function()
		-- The client builds a group's buttons from the count it was created with. A group born
		-- at zero has none to hand out however high the budget is raised afterwards.
		settleGroups()

		local group = customDisplay("player").Frame._groups[CUSTOM_KEY]

		assert(group.maxFrameCountAtCreation == 1, "created with a budget of one")
		assert(#group.buttons > 0, "and with buttons to show")
	end)
end)

fw.describe("Portrait 12.1 - the demoted portrait layer", function()
	fw.it("moves the portrait and its icons a strata below the unit frame", function()
		-- Icons anchored over a portrait have to clear the portrait's own level, which also puts
		-- them above the unit frame's border art, where the icon draws over the ring instead of
		-- inside it. Dropping the portrait into a frame one strata down takes the whole level
		-- range with it, since strata beats level.
		for _, unit in ipairs({ "player", "target", "focus" }) do
			local _, container = displaysFor(unit)
			local portrait = _G[unit == "player" and "PlayerFrame"
				or unit == "target" and "TargetFrame"
				or "FocusFrame"].portrait

			local layer = portrait:GetParent()
			assert(layer:GetFrameStrata() == "LOW",
				unit .. ": the portrait layer sits one strata below MEDIUM, got " .. layer:GetFrameStrata())
			assert(container.Frame:GetParent() == layer,
				unit .. ": the container lives on the portrait layer")
			assert(container.Frame:GetFrameStrata() == "LOW",
				unit .. ": the container follows the layer's strata")
		end
	end)

	fw.it("leaves the pet portrait in its own frame", function()
		-- The pet frame's portrait mask anchors to the portrait instead of carrying its own size
		-- like every other Blizzard one, and moving the portrait out of PetFrame blacks out the
		-- frame's border art. The pet keeps the inset layout, with the container hanging off the
		-- unit frame itself.
		local _, container = displaysFor("pet")

		assert(_G.PetFrame.portrait:GetParent() == _G.PetFrame, "the pet portrait stays put")
		assert(container.Frame:GetParent() == _G.PetFrame, "the container hangs off the unit frame")
		assert(container.Frame:GetFrameLevel() < _G.PetFrame:GetFrameLevel(),
			"the container sits under the unit frame's own level")
	end)

	fw.it("keeps every icon above the portrait it covers", function()
		-- Below the portrait's own level the portrait texture hides the icons entirely, so the
		-- stack still has to sit above it.
		for _, unit in ipairs({ "player", "target", "focus" }) do
			local displays, container = displaysFor(unit)
			local portraitLevel = container.Frame:GetParent():GetFrameLevel()

			assert(container.Frame:GetFrameLevel() > portraitLevel,
				unit .. ": the container must clear the portrait's level")
			for index, display in ipairs(displays) do
				assert(display.Frame:GetFrameLevel() > portraitLevel,
					unit .. ": display " .. index .. " must clear the portrait's level")
			end
		end
	end)
end)

fw.describe("Portrait 12.1 - frame level stacking", function()
	fw.it("stacks the displays UP from the container, kick slot on top", function()
		-- Buttons render at the display's own level, so the lowest display must clear whatever
		-- the portrait draws at, or the portrait hides them. The levels must also be strictly
		-- ascending, because same-level siblings draw in an arbitrary order.
		for _, unit in ipairs({ "player", "target", "focus", "pet" }) do
			local displays, container = displaysFor(unit)
			local previous = container.Frame:GetFrameLevel() + 1

			for index, display in ipairs(displays) do
				local level = display.Frame:GetFrameLevel()
				assert(level > previous,
					unit .. ": display " .. index .. " must sit above level " .. previous)
				previous = level
			end

			local slot = container.Slots[1].Frame:GetFrameLevel()
			assert(slot > previous,
				unit .. ": the kick slot must cover every aura icon, got " .. slot .. " vs " .. previous)
		end
	end)

	fw.it("keeps the masked kick slot out of the render-layer flattening", function()
		-- The portrait mask lives on the unit frame's subtree, and a flattened slot composites
		-- only its own, which renders the masked icon invisible in that state (the
		-- 5.0.0 blank-portraits bug). The container turns flattening on for every slot, so the
		-- portrait display must explicitly turn it back off.
		for _, unit in ipairs({ "player", "target", "focus", "pet" }) do
			local _, container = displaysFor(unit)
			assert(container.Slots[1].Frame._flattens == false,
				unit .. ": the portrait slot must not flatten its render layers")
		end
	end)

	fw.it("the highest priority category is the highest layer", function()
		local displays = displaysFor("target")
		local ccDisplay = displays[#displays]
		assert(ccDisplay.Groups[1].Key == env.addon.Core.AuraFilters.GroupKey.CrowdControl,
			"crowd control is the top aura layer")
		for index = 1, #displays - 1 do
			assert(displays[index].Frame:GetFrameLevel() < ccDisplay.Frame:GetFrameLevel(),
				"lower categories render beneath it")
		end
	end)
end)

fw.describe("Portrait 12.1 - wrapper-managed containers", function()
	fw.it("every portrait container is suppressed by the Edit Mode preview", function()
		-- Only containers built through AuraContainerDisplay are in the suppression list. A
		-- hand-rolled one would happily paint placeholder auras over the portrait.
		displayEvents:TriggerEvent("AURA_DATA_PROVIDER_SWITCH", false)

		for _, unit in ipairs({ "player", "target", "focus", "pet" }) do
			for _, display in ipairs(displaysFor(unit)) do
				assert(not display.Frame:IsShown(), unit .. ": hidden while the preview runs")
			end
		end

		displayEvents:TriggerEvent("AURA_DATA_PROVIDER_SWITCH", true)
		for _, display in ipairs(displaysFor("player")) do
			assert(display.Frame:IsShown(), "restored when the preview ends")
		end
	end)

	fw.it("a target swap refreshes only that unit's stack", function()
		-- Containers watch their unit token, not who currently occupies it, and nothing refreshes
		-- them when the target changes unless the module asks. The refresh is the hide/show
		-- bounce, because an addon-context UpdateAllAuras only marks flags nothing is armed to
		-- consume, so a bounce shows up as one extra Show call per display.
		local function refreshCount(unit)
			local total = 0
			for _, display in ipairs(displaysFor(unit)) do
				total = total + (display.Frame._calls.Show or 0)
			end
			return total
		end

		local targetBefore, playerBefore = refreshCount("target"), refreshCount("player")
		unitChangeEvents:TriggerEvent("PLAYER_TARGET_CHANGED")

		assert(refreshCount("target") == targetBefore + expectedDisplayCount("target"),
			"all five target layers refreshed")
		assert(refreshCount("player") == playerBefore, "the player's stack is untouched")
	end)

	fw.it("a target swap re-gates the disarm layer on assistability", function()
		-- The disarm layer's spell-ID filter is skipped by the engine on assistable units, where
		-- the group would show whatever debuff is newest. The budget is the addon-side gate and
		-- must follow the occupant's reaction, which only the module can see change.
		local disarmKey = env.addon.Core.AuraFilters.GroupKey.Disarm
		local _, container = displaysFor("target")
		local disarmFrame = container.AuraDisplay.DisarmDisplay.Frame

		env.enemies.target = true
		unitChangeEvents:TriggerEvent("PLAYER_TARGET_CHANGED")
		assert(disarmFrame._groups[disarmKey].maxFrameCount == 1, "an enemy occupant opens the layer")

		env.enemies.target = nil
		unitChangeEvents:TriggerEvent("PLAYER_TARGET_CHANGED")
		assert(disarmFrame._groups[disarmKey].maxFrameCount == 0, "an assistable occupant closes it again")
	end)
end)

fw.describe("Portrait 12.1 - enable/disable", function()
	fw.it("disabling parks every display and re-enabling brings them back", function()
		env.setModuleEnabled("Portrait", false)
		module:Refresh()

		for _, display in ipairs(parkedDisplaysFor("target")) do
			assert(not display.Frame:IsEnabled() and not display.Frame:IsShown(), "parked while disabled")
		end

		env.setModuleEnabled("Portrait", true)
		module:Refresh()

		for _, display in ipairs(displaysFor("target")) do
			assert(display.Frame:IsEnabled() and display.Frame:IsShown(), "live again")
		end
	end)

	fw.it("no misuse was reported anywhere in the module's lifecycle", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)

fw.describe("Portrait 12.1 - per-unit switches", function()
	local OPTION_KEY = { player = "Player", target = "Target", focus = "Focus", pet = "Pet" }
	local UNIT_EVENT = { target = "PLAYER_TARGET_CHANGED", focus = "PLAYER_FOCUS_CHANGED", pet = "UNIT_PET" }
	local UNITS = { "player", "target", "focus", "pet" }

	---@param unit string
	---@param on boolean
	local function setUnit(unit, on)
		portraitOptions().Units[OPTION_KEY[unit]] = on
		module:Refresh()
	end

	---@param unit string
	---@return boolean
	local function live(unit)
		for _, display in ipairs(displaysFor(unit)) do
			if not display.Frame:IsEnabled() or not display.Frame:IsShown() then
				return false
			end
		end

		return true
	end

	---@param unit string
	---@return boolean
	local function parked(unit)
		for _, display in ipairs(parkedDisplaysFor(unit)) do
			if display.Frame:IsEnabled() or display.Frame:IsShown() then
				return false
			end
		end

		return true
	end

	fw.before_each(function()
		portraitOptions().Units = { Player = true, Target = true, Focus = true, Pet = true }
		module:Refresh()

		for _, unit in ipairs(UNITS) do
			displaysFor(unit)
		end
	end)

	fw.it("ships with every unit on", function()
		for _, unit in ipairs(UNITS) do
			assert(env.addon.Config.Defaults.Modules.Portrait.Units[OPTION_KEY[unit]] == true,
				unit .. ": on by default")
			assert(live(unit), unit .. ": showing")
		end
	end)

	fw.it("parks only the unit that is switched off", function()
		for _, off in ipairs(UNITS) do
			setUnit(off, false)

			for _, unit in ipairs(UNITS) do
				if unit == off then
					assert(parked(unit), unit .. ": parked once switched off")
					assert(containerFor(unit) == nil, unit .. ": out of the render set")
				else
					assert(live(unit), unit .. ": untouched by switching " .. off .. " off")
				end
			end

			setUnit(off, true)
		end
	end)

	fw.it("brings a unit back live when it is switched on again", function()
		setUnit("focus", false)
		assert(parked("focus"), "fixture: focus is parked")

		setUnit("focus", true)
		assert(live("focus"), "focus shows again from the ordinary refresh")
	end)

	fw.it("reads a profile with no Units table as every unit on", function()
		local saved = portraitOptions().Units
		portraitOptions().Units = nil
		module:Refresh()

		for _, unit in ipairs(UNITS) do
			assert(live(unit), unit .. ": a missing table reads as on")
		end

		portraitOptions().Units = saved
	end)

	fw.it("unregisters the occupant events of the unit that is off and no other", function()
		for _, off in ipairs({ "target", "focus", "pet" }) do
			setUnit(off, false)

			for unit, event in pairs(UNIT_EVENT) do
				if unit == off then
					assert(not unitChangeEvents._events[event], unit .. ": " .. event .. " still registered")
				else
					assert(unitChangeEvents._events[event], unit .. ": " .. event .. " lost with " .. off)
				end
			end

			setUnit(off, true)
			assert(unitChangeEvents._events[UNIT_EVENT[off]], off .. ": event registered again")
		end
	end)

	fw.it("leaves the other events alone when the player is switched off", function()
		setUnit("player", false)

		for unit, event in pairs(UNIT_EVENT) do
			assert(unitChangeEvents._events[event], unit .. ": " .. event .. " lost with the player")
		end
	end)

	fw.it("stops hearing kicks for the unit that is off and no other", function()
		for _, off in ipairs({ "target", "focus" }) do
			local other = off == "target" and "focus" or "target"

			assert(env.fireKick(off) == 1, off .. ": subscribed while on")

			setUnit(off, false)
			assert(env.fireKick(off) == 0, off .. ": no kick subscription while off")
			assert(env.fireKick(other) == 1, other .. ": still subscribed")

			setUnit(off, true)
			assert(env.fireKick(off) == 1, off .. ": subscribed again")
		end
	end)

	fw.it("subscribes to kicks once however often it is refreshed", function()
		module:Refresh()
		module:Refresh()

		assert(env.fireKick("target") == 1, "one subscription for the target")
	end)

	fw.it("draws no kick icon on a unit that is off", function()
		local display = env.addon.Modules.Portrait.Display
		local _, container = displaysFor("target")

		env.kicks.target = { Texture = "tex:kick", DurationObject = {}, StartTime = 0, Duration = 3 }
		setUnit("target", false)
		kickHideNumbers = "unset"
		display:UpdateKickIcon("target", container)

		assert(kickHideNumbers == "unset", "the kick reached the render path of a switched-off portrait")

		env.kicks.target = nil
	end)

	fw.it("drops the unit's token refresh while it is off", function()
		local display = env.addon.Modules.Portrait.Display
		local refreshes = 0

		setUnit("target", false)

		local stack = parkedDisplaysFor("target")

		for _, d in ipairs(stack) do
			d.RequestRefresh = function()
				refreshes = refreshes + 1
			end
		end

		display:RefreshUnitAuras("target")

		for _, d in ipairs(stack) do
			d.RequestRefresh = nil
		end

		assert(refreshes == 0, "a switched-off stack was asked to re-read its auras")
	end)

	fw.it("keeps the preview off a unit that is switched off", function()
		local filled = {}
		local restore = {}

		for _, unit in ipairs(UNITS) do
			local _, container = displaysFor(unit)
			local original = container.SetSlot

			restore[#restore + 1] = function()
				container.SetSlot = original
			end
			container.SetSlot = function(self, ...)
				filled[unit] = true
				return original(self, ...)
			end
		end

		setUnit("focus", false)
		module:StartTesting()
		module:StopTesting()

		for _, undo in ipairs(restore) do
			undo()
		end

		assert(filled.target and filled.player and filled.pet, "the units that are on get the stand-in")
		assert(not filled.focus, "the unit that is off does not")
	end)
end)

fw.describe("Portrait 12.1 - a unit switched off before it is attached", function()
	fw.it("leaves its Blizzard portrait alone until it is switched on", function()
		local env2 = moduleEnv.build()
		env2.setModuleEnabled("Portrait", true)

		local frame = acm.NewFrame("Frame", "FocusFrame")
		frame:SetFrameLevel(500)
		local portrait = acm.NewFrame("Frame", "FocusFramePortrait", frame)
		portrait:SetSize(PORTRAIT_SIZE, PORTRAIT_SIZE)
		portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -5)
		frame.portrait = portrait
		_G.FocusFrame = frame

		env2.loadModule("src/Modules/Portrait/Observer.lua")
		env2.loadModule("src/Modules/Portrait/Display.lua")
		env2.loadModule("src/Modules/Portrait/Anchors.lua")
		env2.loadModule("src/Modules/Portrait/Module.lua")

		local module2 = env2.addon.Modules.PortraitModule

		env2.db.Modules.Portrait.Units.Focus = false
		module2:Init()
		module2:Refresh()

		assert(portrait:GetParent() == frame, "the portrait was moved although focus is off")
		for _, container in ipairs(module2:GetContainers()) do
			assert(container.AuraUnit ~= "focus", "a focus container was built while it is off")
		end

		env2.db.Modules.Portrait.Units.Focus = true
		module2:Refresh()

		assert(portrait:GetParent() ~= frame, "the portrait was not attached once switched on")

		local found = false
		for _, container in ipairs(module2:GetContainers()) do
			found = found or container.AuraUnit == "focus"
		end

		assert(found, "switching focus on builds its container live")
	end)
end)

fw.describe("Portrait 12.1 - undoing what an attach did to the unit frame", function()
	local UNITS = { "player", "target", "focus", "pet" }
	local FRAMES = { player = "PlayerFrame", target = "TargetFrame", focus = "FocusFrame", pet = "PetFrame" }
	local OPTION_KEY = { player = "Player", target = "Target", focus = "Focus", pet = "Pet" }

	---@param event string
	local function Fire(event)
		for _, frame in ipairs(acm.frames) do
			local listening = frame._events and frame._events[event]
			local handler = frame._scripts and frame._scripts.OnEvent

			if listening and handler then
				handler(frame, event)
			end
		end
	end

	---Fresh unit frames, a Voidform glow, and a pet portrait that has a draw layer to read back.
	---@param withBlizzard boolean? false leaves the target frame out
	---@return table world
	local function buildWorld(withBlizzard)
		local world = { env = moduleEnv.build(), portraits = {}, saved = {} }
		world.env.setModuleEnabled("Portrait", true)

		for _, name in pairs(FRAMES) do
			world.saved[name] = _G[name]
		end
		world.saved.InsanityBarFrame = _G.InsanityBarFrame

		for _, unit in ipairs(UNITS) do
			local frame = acm.NewFrame("Frame", FRAMES[unit])
			frame:SetFrameLevel(unit == "pet" and 3 or 500)
			local portrait = acm.NewFrame("Frame", FRAMES[unit] .. "Portrait", frame)
			portrait:SetSize(PORTRAIT_SIZE, PORTRAIT_SIZE)
			portrait:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -5)
			frame.portrait = portrait
			_G[FRAMES[unit]] = frame
			world.portraits[unit] = portrait
		end

		if withBlizzard == false then
			_G.TargetFrame = nil
		end

		local glow = acm.NewFrame("Frame", "PortraitGlow")
		glow:SetFrameStrata("MEDIUM")
		glow:SetFrameLevel(7)
		_G.InsanityBarFrame = { PortraitGlow = glow }
		world.glow = glow

		world.draw = { "ARTWORK", 2 }
		local pet = world.portraits.pet
		pet.GetDrawLayer = function()
			return world.draw[1], world.draw[2]
		end
		pet.SetDrawLayer = function(_, layer, sub)
			world.draw = { layer, sub }
		end

		return world
	end

	---@param world table
	local function restoreGlobals(world)
		for name, frame in pairs(world.saved) do
			_G[name] = frame
		end
		_G.EllesmereUIUnitFrames_Target = nil
	end

	---Runs a test against a fresh world. Globals the world replaced are put back even when it fails.
	---@param name string
	---@param test fun(world: table)
	---@param withBlizzard boolean?
	local function worldTest(name, test, withBlizzard)
		fw.it(name, function()
			local world = buildWorld(withBlizzard)
			local realInCombat = _G.InCombatLockdown
			local ok, err = pcall(test, world)

			_G.InCombatLockdown = realInCombat
			restoreGlobals(world)

			if not ok then
				error(err, 0)
			end
		end)
	end

	---Runs the body as if the player were fighting. Relies on worldTest to put back the real InCombatLockdown.
	---@param body fun()
	local function inCombat(body)
		_G.InCombatLockdown = function()
			return true
		end
		body()
		_G.InCombatLockdown = function()
			return false
		end
	end

	---@param world table
	local function start(world)
		local env2 = world.env
		env2.loadModule("src/Modules/Portrait/Observer.lua")
		env2.loadModule("src/Modules/Portrait/Display.lua")
		env2.loadModule("src/Modules/Portrait/Anchors.lua")
		env2.loadModule("src/Modules/Portrait/Module.lua")

		world.module = env2.addon.Modules.PortraitModule
		world.module:Init()
	end

	---Everything the attach writes to a portrait and the glow, as one comparable string.
	---@param world table
	---@param unit string
	---@return string
	local function state(world, unit)
		local portrait = world.portraits[unit]
		local point, relativeTo, relativePoint, x, y = portrait:GetPoint(1)
		local parts = {
			tostring(portrait:GetParent()),
			tostring(portrait:GetNumPoints()),
			tostring(point),
			tostring(relativeTo),
			tostring(relativePoint),
			tostring(x),
			tostring(y),
		}

		if unit == "player" then
			parts[#parts + 1] = world.glow:GetFrameStrata() .. "/" .. world.glow:GetFrameLevel()
		elseif unit == "pet" then
			parts[#parts + 1] = world.draw[1] .. "/" .. world.draw[2]
		end

		return table.concat(parts, "|")
	end

	---@param world table
	---@param unit string
	---@return table? container
	local function containerOf(world, unit)
		for _, container in ipairs(world.module:GetContainers()) do
			if container.AuraUnit == unit then
				return container
			end
		end
	end

	---@param world table
	---@param unit string
	---@param on boolean
	local function setUnit(world, unit, on)
		world.env.db.Modules.Portrait.Units[OPTION_KEY[unit]] = on
		world.module:Refresh()
	end

	---@param world table
	---@return table<string, string>
	local function snapshot(world)
		local result = {}

		for _, unit in ipairs(UNITS) do
			result[unit] = state(world, unit)
		end

		return result
	end

	worldTest("puts back every property it changed when the unit is switched off", function(world)
		start(world)

		local before = snapshot(world)
		world.module:Refresh()

		for _, unit in ipairs(UNITS) do
			assert(state(world, unit) ~= before[unit], unit .. ": fixture, the attach changed something")
		end

		for _, off in ipairs(UNITS) do
			local attached = snapshot(world)

			setUnit(world, off, false)

			assert(state(world, off) == before[off], off .. ": not back as it was found")

			for _, unit in ipairs(UNITS) do
				if unit ~= off then
					assert(state(world, unit) == attached[unit], unit .. ": touched by switching " .. off .. " off")
				end
			end

			setUnit(world, off, true)
		end
	end)

	worldTest("reattaches the same frames when the unit is switched back on", function(world)
		start(world)
		world.module:Refresh()

		local attached = state(world, "target")
		local container = assert(containerOf(world, "target"))
		local count = #world.module:GetContainers()

		setUnit(world, "target", false)
		assert(containerOf(world, "target") == nil, "out of the render set while off")

		setUnit(world, "target", true)

		assert(containerOf(world, "target") == container, "the same container comes back, not a second one")
		assert(#world.module:GetContainers() == count, "no extra container was built")
		assert(state(world, "target") == attached, "the portrait is demoted again exactly as before")
	end)

	worldTest("restores every unit when the module is disabled, and attaches again when it is enabled", function(world)
		start(world)

		local before = snapshot(world)
		world.module:Refresh()

		local attached = snapshot(world)

		world.env.setModuleEnabled("Portrait", false)
		world.module:Refresh()

		for _, unit in ipairs(UNITS) do
			assert(state(world, unit) == before[unit], unit .. ": not restored by disabling the module")
		end
		assert(#world.module:GetContainers() == 0, "nothing left in the render set")

		world.env.setModuleEnabled("Portrait", true)
		world.module:Refresh()

		for _, unit in ipairs(UNITS) do
			assert(state(world, unit) == attached[unit], unit .. ": not attached again on enable")
		end
	end)

	worldTest("waits for combat to end before writing to the unit frame", function(world)
		start(world)

		local before = state(world, "player")
		world.module:Refresh()

		local attached = state(world, "player")
		inCombat(function()
			setUnit(world, "player", false)

			assert(containerOf(world, "player") == nil, "the icons go at once")
			assert(state(world, "player") == attached, "the frame is left alone in combat")
			assert(world.env.addon.Framework:HasPendingCombatWork(), "the restore is waiting")
		end)

		Fire("PLAYER_REGEN_ENABLED")

		assert(state(world, "player") == before, "restored once combat ended")
	end)

	worldTest("takes a third-party portrait's container out and back without touching its frame", function(world)
		local frame = acm.NewFrame("Frame", "EllesmereUIUnitFrames_Target")
		local backdrop = acm.NewFrame("Frame", "EllesmereUIUnitFrames_TargetBackdrop", frame)
		backdrop:SetSize(PORTRAIT_SIZE, PORTRAIT_SIZE)
		backdrop:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -5)
		frame.Portrait = { backdrop = backdrop }
		_G.EllesmereUIUnitFrames_Target = frame

		start(world)
		world.module:Refresh()

		local function describe()
			return tostring(backdrop:GetParent()) .. "|" .. tostring(backdrop:GetNumPoints()) .. "|" .. tostring(backdrop:GetFrameLevel())
		end

		local before = describe()
		local container = assert(containerOf(world, "target"), "the third-party portrait got a container")
		assert(describe() == before, "attaching does not touch the host portrait")

		setUnit(world, "target", false)
		assert(containerOf(world, "target") == nil, "its container leaves the render set with the unit")
		assert(describe() == before, "and the host portrait stays as it was")

		setUnit(world, "target", true)
		assert(containerOf(world, "target") == container, "the same container returns")

	end, false)
	worldTest("writes nothing for a unit switched off and on again within one combat", function(world)
		start(world)
		world.module:Refresh()

		local attached = state(world, "player")
		local writes = 0
		local portrait = world.portraits.player
		local setParent = portrait.SetParent
		portrait.SetParent = function(self, ...)
			writes = writes + 1
			return setParent(self, ...)
		end

		inCombat(function()
			setUnit(world, "player", false)
			setUnit(world, "player", true)
		end)
		Fire("PLAYER_REGEN_ENABLED")

		assert(state(world, "player") == attached, "still attached")
		assert(writes == 0, "the portrait was re-parented for nothing")
		assert(containerOf(world, "player"), "its icons are back")
	end)

	worldTest("ends attached after on, off, on in one combat", function(world)
		start(world)

		local before = state(world, "player")
		world.module:Refresh()
		local attached = state(world, "player")

		setUnit(world, "player", false)
		assert(state(world, "player") == before, "fixture: restored out of combat")

		inCombat(function()
			setUnit(world, "player", true)
			setUnit(world, "player", false)
			setUnit(world, "player", true)

			assert(state(world, "player") == before, "the frame is left alone in combat")
		end)
		Fire("PLAYER_REGEN_ENABLED")

		assert(state(world, "player") == attached, "attached once combat ended")
	end)

	worldTest("waits for combat to end before the first attach of a unit switched on in it", function(world)
		world.env.db.Modules.Portrait.Units.Focus = false
		start(world)
		world.module:Refresh()

		local before = state(world, "focus")

		inCombat(function()
			setUnit(world, "focus", true)

			assert(state(world, "focus") == before, "the focus portrait was re-parented in combat")
		end)
		Fire("PLAYER_REGEN_ENABLED")

		assert(state(world, "focus") ~= before, "attached once combat ended")
		assert(containerOf(world, "focus"), "and its icons are in the render set")
	end)

	worldTest("does not attach a unit whose build was waiting on combat when the module is disabled", function(world)
		world.env.db.Modules.Portrait.Units.Focus = false
		start(world)
		world.module:Refresh()

		local before = state(world, "focus")

		inCombat(function()
			setUnit(world, "focus", true)
			world.env.setModuleEnabled("Portrait", false)
			world.module:Refresh()
		end)
		Fire("PLAYER_REGEN_ENABLED")

		assert(state(world, "focus") == before, "the focus portrait was re-parented on a disabled module")
		assert(containerOf(world, "focus") == nil, "and it was put in the render set")
	end)

	worldTest("attaches a unit later when it was switched off while its build waited on combat", function(world)
		world.env.db.Modules.Portrait.Units.Focus = false
		start(world)
		world.module:Refresh()

		local before = state(world, "focus")

		inCombat(function()
			setUnit(world, "focus", true)
			setUnit(world, "focus", false)
		end)
		Fire("PLAYER_REGEN_ENABLED")

		assert(state(world, "focus") == before, "fixture: nothing was built while it was off")

		setUnit(world, "focus", true)

		assert(state(world, "focus") ~= before, "attached when switched on afterwards")
		assert(containerOf(world, "focus"), "and in the render set")
	end)

	worldTest("shows the preview icon on a unit whose build waited on combat during test mode", function(world)
		world.env.db.Modules.Portrait.Units.Focus = false
		start(world)
		world.module:Refresh()
		world.module:StartTesting()

		inCombat(function()
			setUnit(world, "focus", true)
		end)
		Fire("PLAYER_REGEN_ENABLED")

		local container = assert(containerOf(world, "focus"), "attached once combat ended")
		assert(container.Frame.MiniAurasTestLabel, "the preview captioned it")

		world.module:StopTesting()
	end)

	worldTest("clears the preview caption of a unit switched off during test mode", function(world)
		start(world)
		world.module:Refresh()
		world.module:StartTesting()

		local container = assert(containerOf(world, "focus"))
		local label = assert(container.Frame.MiniAurasTestLabel, "fixture: the preview captioned it")
		assert(label:IsShown(), "fixture: and it is on screen")

		setUnit(world, "focus", false)

		assert(not label:IsShown(), "the caption stayed on a switched-off unit")

		world.module:StopTesting()
	end)
end)

fw.describe("Portrait 12.1 - the swipe follows the mask's shape", function()
	local display = env.addon.Modules.Portrait.Display

	---@param mask table
	---@return string
	local function SwipeUnder(mask)
		local layer = { Icon = acm.NewFrame("Frame"), Cooldown = acm.NewFrame("Cooldown") }
		display:ApplyMaskToLayer(layer, mask, 0.1, 0.9)

		return layer.Cooldown._lastArgs.SetSwipeTexture[1]
	end

	fw.it("cuts the swipe to whatever art the mask carries", function()
		local mask = acm.NewFrame("Frame"):CreateMaskTexture()
		mask:SetTexture("tex:diamond_mask")

		assert(SwipeUnder(mask) == "tex:diamond_mask", "a shaped portrait gets a swipe cut to its shape")
	end)

	-- The stock portrait frames build their masks from an atlas, which leaves no texture to read.
	fw.it("keeps the round swipe under a mask with no texture of its own", function()
		local mask = acm.NewFrame("Frame"):CreateMaskTexture()
		mask:SetAtlas("CircleMask")

		assert(SwipeUnder(mask) == "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask",
			"an atlas mask falls back to the round portrait swipe rather than leaving a square one")
	end)
end)
