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
	frame.portrait = portrait
	_G[spec.Global] = frame
end

env.loadModule("src/Modules/Portrait/Observer.lua")
env.loadModule("src/Modules/Portrait/Display.lua")
env.loadModule("src/Modules/Portrait/Anchors.lua")
env.loadModule("src/Modules/Portrait/Module.lua")
local module = env.addon.Modules.PortraitModule
module:Init()

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

local function displaysFor(unit)
	local container = assert(containerFor(unit), "no portrait container for " .. unit)
	return assert(container.AuraDisplay, "no aura display stack").Displays, container
end

fw.describe("PortraitModule 12.1 - the five-category stack", function()
	fw.it("builds one single-icon display per category on every portrait", function()
		local disarmKey = env.addon.Core.AuraFilters.GroupKey.Disarm
		for _, unit in ipairs({ "player", "target", "focus", "pet" }) do
			local displays = displaysFor(unit)
			assert(#displays == 5, unit .. ": expected 5 displays, got " .. #displays)

			for _, display in ipairs(displays) do
				assert(#display.Groups == 1, "one group per display")
				local group = display.Groups[1]
				-- The disarm layer starts budgeted away: every occupant is assistable in this
				-- env, and the engine skips the layer's spell-ID filter on assistable units.
				local budget = group.Key == disarmKey and 0 or 1
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

fw.describe("PortraitModule 12.1 - frame level stacking", function()
	fw.it("stacks the displays UP from unitFrame+1, kick slot on top", function()
		-- Buttons render at the display's own level, so the lowest display must clear the unit
		-- frame itself: at the unit frame's level its ring art covers every icon, and below it
		-- the portrait texture hides them (the first PTR build's bug). The levels must also be
		-- strictly ascending - same-level siblings draw in an arbitrary order.
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
		-- only its own; the 12.0.7 client renders the masked icon invisible in that state (the
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

		assert(refreshCount("target") == targetBefore + 5, "all five target layers refreshed")
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
