-- The CC display's three colour modes. None must leave the icons as bare art, Dispel keeps the
-- game's palette, and Custom keeps the flat swatch, matching what each drew before the checkbox
-- became a dropdown.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
local acm = require("AuraContainerMock")

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("CrowdControl", true)

local held = env.addUnitFrame("party1", "CUF_CcColorMode")

env.loadModule("src/Modules/CrowdControl/Display.lua")
env.loadModule("src/Modules/CrowdControl/Module.lua")

local module = env.addon.Modules.CrowdControlModule
local auraContainerDisplay = env.addon.Core.AuraContainerDisplay
local iconSlotContainer = env.addon.Core.IconSlotContainer
local options = db.Modules.CrowdControl.Default

-- Every display the module builds, kept as it is made. The entry holds it privately, and the
-- style it was built or restyled to can only be read off the display itself. Installed before
-- Init, which builds the held frame's display immediately.
local builtDisplays = {}
local realNewDisplay = auraContainerDisplay.New

auraContainerDisplay.New = function(self, ...)
	local display = realNewDisplay(self, ...)

	builtDisplays[#builtDisplays + 1] = display

	return display
end

-- Every IconSlotContainer the module builds, kept the same way, so a test-mode preview's slots
-- can be read back without a watchers export.
local builtContainers = {}
local realNewContainer = iconSlotContainer.New

iconSlotContainer.New = function(self, ...)
	local container = realNewContainer(self, ...)

	builtContainers[#builtContainers + 1] = container

	return container
end

-- The kick icon is a slot on the container rather than a display, so its colour can only be read
-- off the options KickSlot was actually handed.
local kickSlot = env.addon.Core.KickSlot
local kickSlotColor
local kickSlotHideNumbers
local realKickSlotRender = kickSlot.Render

kickSlot.Render = function(self, container, kickEntry, slotOptions, previousTimer, onExpired)
	if kickEntry then
		kickSlotColor = slotOptions.Color
		kickSlotHideNumbers = slotOptions.HideNumbers
	end

	return realKickSlotRender(self, container, kickEntry, slotOptions, previousTimer, onExpired)
end

module:Init()

---The display drawn through a unit's container, found by matching the frame each was built on.
---@param unit string
---@return table?
local function DisplayFor(unit)
	local container = env.containersForUnit(unit)[1]

	if not container then
		return nil
	end

	for _, display in ipairs(builtDisplays) do
		if display.Frame == container then
			return display
		end
	end

	return nil
end

fw.describe("CrowdControl - the icon colours mode", function()
	fw.before_each(function()
		options.Icons.ColorMode = "DISPEL"
		module:Refresh()
		acm.tickAll(400)
	end)

	fw.it("draws bare art with no border or glow in None mode", function()
		local display = assert(DisplayFor(held.unit), "fixture: the frame got a display")

		options.Icons.ColorMode = "NONE"
		module:Refresh()

		assert(display.Style.ColorByDispelType == false, "the dispel palette must not apply")
		assert(display.Style.Border == false, "and the ring it would draw must not either")
		assert(display.Style.GlowColorR == nil, "nor any flat tint on the glow")

		-- The claim above is about AuraContainerDisplay's own Style table. What actually keeps the
		-- ring off is BorderWithoutDispelType not reaching the engine while ColorByDispelType is
		-- off, which only the button's resolved dispel state can prove.
		local button = display.Frame:GetAuraGroupFrame("cc", 1)
		local widgets = display.ButtonWidgets[button]
		assert(widgets.DispelBorder == false,
			"BorderWithoutDispelType must not register the ring with the engine in None mode")
	end)

	fw.it("keeps the dispel palette and no flat tint in Dispel mode", function()
		local display = assert(DisplayFor(held.unit), "fixture: the frame got a display")

		options.Icons.ColorMode = "NONE"
		module:Refresh()

		options.Icons.ColorMode = "DISPEL"
		module:Refresh()

		assert(display.Style.ColorByDispelType == true, "the palette must be back on")
		assert(display.Style.Border == false, "the flat ring stays off, the palette draws its own")
		assert(display.Style.GlowColorR == nil, "and no flat tint competes with it")
	end)

	fw.it("keeps the flat swatch and no dispel palette in Custom mode", function()
		local display = assert(DisplayFor(held.unit), "fixture: the frame got a display")

		options.Icons.Color = { R = 0.25, G = 0.5, B = 0.75, A = 1 }
		options.Icons.ColorMode = "CUSTOM"
		module:Refresh()

		assert(display.Style.ColorByDispelType == false, "the palette must not override the swatch")
		assert(display.Style.Border == true, "the flat colour draws its own ring")
		fw.not_nil(display.Style.GlowColorR, "and its own glow tint")
		fw.eq(display.Style.GlowColorR, 0.25, "taken from the swatch")
	end)
end)

fw.describe("CrowdControl - the test-mode preview's corners", function()
	fw.it("keeps the preview icons square in None mode", function()
		-- The reported symptom: glow and dispel colours both off.
		options.Icons.Glow = false
		options.Icons.ColorMode = "NONE"
		module:StartTesting()

		local previewContainer
		for _, container in ipairs(builtContainers) do
			if container.Slots[1] and container.Slots[1].Container then
				previewContainer = container
			end
		end

		module:StopTesting()

		local layer = assert(previewContainer, "fixture: test mode filled a container").Slots[1].Container
		assert(layer.CornersRounded == false, "the None-mode preview should not round its icons")
	end)
end)

---Lands a kick on the held unit and reports the colour KickSlot rendered it with, nil for none.
---@return table? color
local function RenderedKickColor()
	kickSlotColor = "unset"

	env.kicks[held.unit] = {
		Texture = "tex:kick",
		DurationObject = {},
		StartTime = 0,
		Duration = 3,
		Color = { r = 1, g = 0.2, b = 0.2 },
	}
	env.fireKick(held.unit)

	assert(kickSlotColor ~= "unset", "fixture: firing a kick reached KickSlot:Render")

	return kickSlotColor
end

fw.describe("CrowdControl - the kick icon's colour", function()
	fw.before_each(function()
		options.Icons.ColorMode = "DISPEL"
		module:Refresh()
		acm.tickAll(400)
	end)

	fw.it("takes the dispel palette in Dispel mode", function()
		fw.not_nil(RenderedKickColor(), "Dispel mode hands the kick icon the kick's own colour")
	end)

	fw.it("takes no colour in None mode", function()
		options.Icons.ColorMode = "NONE"
		module:Refresh()

		fw.is_nil(RenderedKickColor(), "None mode leaves the kick icon uncoloured")
	end)

	fw.it("takes no colour in Custom mode", function()
		options.Icons.ColorMode = "CUSTOM"
		module:Refresh()

		fw.is_nil(RenderedKickColor(), "Custom mode colours only the aura icons, not the kick")
	end)
end)

fw.describe("CrowdControl - the kick icon's countdown", function()
	fw.before_each(function()
		options.Icons.ColorMode = "DISPEL"
		module:Refresh()
		acm.tickAll(400)
	end)

	fw.it("keeps it, since this module offers no switch to take it off", function()
		fw.not_nil(RenderedKickColor(), "fixture: a kick reached the slot")

		assert(kickSlotHideNumbers == false, "a module with no Show numbers switch reads as on")
	end)
end)
