-- PortraitModule, 12.1 container path: the layered single-icon stack over a unit frame portrait.
--
-- A portrait shows ONE icon but cannot ask which aura wins (aura presence is secret), so it gets
-- five single-icon containers stacked by frame level and lets the higher-priority one cover the
-- rest. The levels must be DISTINCT: same-level siblings draw in an arbitrary order, which sank
-- the creation-order variant. Two things about the arrangement have already broken once and are
-- invisible when they do:
--
--   * Frame levels. The first PTR build put the stack BELOW the kick frame, which put it behind
--     TargetFrame's own textures - no errors, just no icons. The order is asserted here.
--   * Going through the wrapper. These used to be raw CreateFrame("AuraContainer") calls, which
--     kept them out of the Edit Mode suppression list and would have shown Blizzard's placeholder
--     auras over every portrait.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()

env.setModuleEnabled("PortraitModule", true)

-- Blizzard unit frames. The portrait is a texture in the client; the mock models it as a child
-- frame so it can carry a parent, a size and a rect.
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
module:Init()
-- Init only builds the lifecycle now; a module sets itself up on the first refresh that
-- finds it enabled, which in the addon is the one PLAYER_ENTERING_WORLD drives.
module:Refresh()

-- The wrapper's shared event frame; created with the first display, so it exists by now.
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

local function displaysFor(unit)
	settleGroups()

	local container = assert(containerFor(unit), "no portrait container for " .. unit)
	return assert(container.AuraDisplay, "no aura display stack").Displays, container
end

-- The player's portrait carries the user's own spell list under the five flagged categories.
local function expectedDisplayCount(unit)
	return unit == "player" and 6 or 5
end

local function portraitOptions()
	return env.db.Modules.PortraitModule
end

fw.describe("PortraitModule 12.1 - the five-category stack", function()
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

fw.describe("PortraitModule 12.1 - the custom spell layer", function()
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

		setCustomSpells()
		assert(group.maxFrameCount == 0, "clearing the list closes the layer again")
	end)

	fw.it("allocates its buttons up front, so a later addition can render", function()
		-- The client builds a group's buttons from the count it was created with; a group born
		-- at zero has none to hand out however high the budget is raised afterwards.
		settleGroups()

		local group = customDisplay("player").Frame._groups[CUSTOM_KEY]

		assert(group.maxFrameCountAtCreation == 1, "created with a budget of one")
		assert(#group.buttons > 0, "and with buttons to show")
	end)
end)

fw.describe("PortraitModule 12.1 - the demoted portrait layer", function()
	fw.it("moves the portrait and its icons a strata below the unit frame", function()
		-- Icons anchored over a portrait have to clear the portrait's own level, which used to
		-- put them above the unit frame's border art too - the icon then drew over the ring
		-- instead of inside it. Dropping the portrait into a frame one strata down takes the
		-- whole level range with it, since strata beats level.
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
		-- Below the portrait's own level the portrait texture hides the icons entirely (the
		-- first PTR build's bug), so the stack still has to sit above it.
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

fw.describe("PortraitModule 12.1 - frame level stacking", function()
	fw.it("stacks the displays UP from the container, kick slot on top", function()
		-- Buttons render at the display's own level, so the lowest display must clear whatever
		-- the portrait draws at, or the portrait hides them (the first PTR build's bug). The
		-- levels must also be strictly ascending - same-level siblings draw in an arbitrary
		-- order.
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

fw.describe("PortraitModule 12.1 - wrapper-managed containers", function()
	fw.it("every portrait container is suppressed by the Edit Mode preview", function()
		-- Only containers built through AuraContainerDisplay are in the suppression list; a
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
		-- Containers watch their unit token, not who currently occupies it; nothing refreshes
		-- them when the target changes unless the module asks. The refresh is the hide/show
		-- bounce (an addon-context UpdateAllAuras only marks flags nothing is armed to consume),
		-- so a bounce shows up as one extra Show call per display.
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
		-- the group would show whatever debuff is newest; the budget is the addon-side gate and
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

fw.describe("PortraitModule 12.1 - enable/disable", function()
	fw.it("disabling parks every display and re-enabling brings them back", function()
		env.setModuleEnabled("PortraitModule", false)
		module:Refresh()

		for _, display in ipairs(displaysFor("target")) do
			assert(not display.Frame:IsEnabled() and not display.Frame:IsShown(), "parked while disabled")
		end

		env.setModuleEnabled("PortraitModule", true)
		module:Refresh()

		for _, display in ipairs(displaysFor("target")) do
			assert(display.Frame:IsEnabled() and display.Frame:IsShown(), "live again")
		end
	end)

	fw.it("no misuse was reported anywhere in the module's lifecycle", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
