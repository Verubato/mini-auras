-- The countdown text on the raid frame aura icons. The switch only ever takes the numbers off,
-- so a profile that never touched it keeps the countdown it has always drawn.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local IMPORTANT_GROUP_KEY = "helpfulimp"

local env = moduleEnv.build()
local db = env.db

env.setModuleEnabled("ImportantAuras", true)

env.addUnitFrame("party1", "CUF_Numbers")

env.loadModule("src/Modules/ImportantAuras/Display.lua")
env.loadModule("src/Modules/ImportantAuras/Module.lua")

local module = env.addon.Modules.ImportantAurasModule
local options = db.Modules.ImportantAuras.Default

-- The preview sets its stand-ins straight onto the container's slots, the interrupt icon included,
-- so every one of them is read off the options that slot was handed.
local iconSlotContainer = env.addon.Core.IconSlotContainer
local previewSlots = {}
local capturingPreview = false
local realSetSlot = iconSlotContainer.SetSlot

iconSlotContainer.SetSlot = function(self, slotIndex, slotOptions)
	if capturingPreview then
		-- Held as a plain boolean, so a slot the switch never reached still counts as a slot.
		previewSlots[slotIndex] = slotOptions.HideNumbers == true
	end

	return realSetSlot(self, slotIndex, slotOptions)
end

-- The kick icon is a slot on the container rather than a display, so what the switch did to it
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

---Whether party1's icons have dropped their countdown, read off a button the engine built for the
---important group.
---@return boolean
local function NumbersHidden()
	module:Refresh()
	-- The groups are declared by the background walker, a group per turn, so a whole roster
	-- turning up does not build them all in one frame.
	acm.tickAll(40)

	local containers = env.containersForUnit("party1")
	assert(#containers > 0, "no aura container for party1")

	local group = assert(containers[1]._groups[IMPORTANT_GROUP_KEY], "no important group")
	local button = assert(group.buttons[1], "the group built a button")
	local cooldown = assert(button._lastArgs.SetDurationCooldown, "the button was given a cooldown")[1]

	return cooldown._lastArgs.SetHideCountdownNumbers[1]
end

---Lands a kick on party1 and reports whether the icon it rendered dropped its countdown.
---@return boolean
local function KickNumbersHidden()
	kickHideNumbers = "unset"

	module:Refresh()
	env.kicks.party1 = {
		Texture = "tex:kick",
		DurationObject = {},
		StartTime = 0,
		Duration = 3,
	}
	env.fireKick("party1")

	assert(kickHideNumbers ~= "unset", "fixture: firing a kick reached KickSlot:Render")

	return kickHideNumbers
end

---Runs the preview and reports how many stand-in icons it drew and how many of those dropped
---their countdown.
---@return number drawn
---@return number hidden
local function PreviewNumbersHidden()
	previewSlots = {}
	capturingPreview = true

	module:StartTesting()

	capturingPreview = false
	module:StopTesting()

	local drawn = 0
	local hidden = 0

	for _, hideNumbers in pairs(previewSlots) do
		drawn = drawn + 1

		if hideNumbers then
			hidden = hidden + 1
		end
	end

	return drawn, hidden
end

fw.describe("ImportantAuras - the countdown numbers", function()
	fw.before_each(function()
		options.ShowImportant = true
		options.ShowKicks = true
		options.Icons.EnableNumbers = true
		db.DisableNumbers = false
	end)

	fw.it("keeps counting down while the switch is on", function()
		assert(NumbersHidden() == false, "the icons show their countdown")
	end)

	fw.it("drops the countdown once the switch is off", function()
		options.Icons.EnableNumbers = false

		assert(NumbersHidden() == true, "the switch takes the numbers off")
	end)

	fw.it("counts down for a profile saved before the switch existed", function()
		options.Icons.EnableNumbers = nil

		assert(NumbersHidden() == false, "a missing switch reads as on")
	end)

	fw.it("takes them off the interrupt icon too, which is a slot rather than an aura", function()
		assert(KickNumbersHidden() == false, "the interrupt icon counts down with the switch on")

		options.Icons.EnableNumbers = false

		assert(KickNumbersHidden() == true, "and drops the numbers when the aura icons do")
	end)

	fw.it("takes them out of the preview the switch is read against", function()
		local drawn, hidden = PreviewNumbersHidden()

		assert(drawn > 1, "the preview draws the interrupt icon and stand-ins beside it")
		fw.eq(hidden, 0, "the stand-ins count down like the live icons")

		options.Icons.EnableNumbers = false
		drawn, hidden = PreviewNumbersHidden()

		fw.eq(hidden, drawn, "and every one drops its numbers when the live icons do")
	end)

	fw.it("hides them for the global switch even with the row's own left on", function()
		db.DisableNumbers = true

		assert(NumbersHidden() == true, "the global switch reaches the row that asked for numbers")
	end)
end)
