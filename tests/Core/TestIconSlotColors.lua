-- Countdown colouring on IconSlotContainer: icons whose duration times the addon itself
-- supplied (test icons, kick timers) tint their countdown text by remaining time, matching
-- the bands the curve-bound 12.1 aura icons use. Durations from anywhere else are opaque,
-- possibly secret, and must never be touched.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()
local db = env.db
local wowEx = env.addon.Utils.WoWEx
local iconSlotContainer = env.addon.Core.IconSlotContainer

local ICON = 134400

local function NewSlotContainer()
	return iconSlotContainer:New(_G.UIParent, 3, 30, 2, "ColourTest")
end

---One iconed slot whose cooldown carries the countdown fontstring the real template would
---have, re-rendered so the colour path can find it.
local function BuildColouredSlot(duration)
	local container = NewSlotContainer()
	container:SetSlot(1, { Texture = ICON, DurationObject = wowEx:CreateDuration(GetTime(), duration) })

	local cd = container.Slots[1].Container.Cooldown
	local text = cd:CreateFontString()
	container:SetSlot(1, { Texture = ICON, DurationObject = wowEx:CreateDuration(GetTime(), duration) })

	return container, text
end

fw.describe("IconSlotContainer - countdown colouring", function()
	fw.before_each(function()
		db.ColorCountdownByTime = true
	end)

	fw.it("tints the countdown by remaining time and resets on clear", function()
		local container, text = BuildColouredSlot(30)
		local colour = text._lastArgs.SetTextColor
		assert(colour and colour[1] == 1 and colour[2] == 0.8 and colour[3] == 0,
			"under a minute reads yellow")

		container:SetSlot(1, { Texture = ICON, DurationObject = wowEx:CreateDuration(GetTime(), 90) })
		colour = text._lastArgs.SetTextColor
		assert(colour[2] == 1 and colour[3] == 1, "over a minute reads white")

		container:SetSlot(1, { Texture = ICON, DurationObject = wowEx:CreateDuration(GetTime(), 3) })
		colour = text._lastArgs.SetTextColor
		assert(colour[1] == 1 and colour[2] == 0 and colour[3] == 0, "the last five seconds read red")

		container:SetSlotUnused(1)
		colour = text._lastArgs.SetTextColor
		assert(colour[1] == 1 and colour[2] == 1 and colour[3] == 1, "clearing restores plain white")
	end)

	fw.it("leaves the text alone when the toggle is off", function()
		db.ColorCountdownByTime = false
		local _, text = BuildColouredSlot(3)
		assert(text._lastArgs.SetTextColor == nil, "no tint without the setting")
	end)

	fw.it("never touches a duration it did not build", function()
		local container = NewSlotContainer()
		local foreign = _G.C_DurationUtil.CreateDuration()
		container:SetSlot(1, { Texture = ICON, DurationObject = foreign })

		local cd = container.Slots[1].Container.Cooldown
		local text = cd:CreateFontString()
		container:SetSlot(1, { Texture = ICON, DurationObject = foreign })

		assert(text._lastArgs.SetTextColor == nil, "an opaque duration stays untinted")
	end)
end)

fw.describe("IconSlotContainer - the global DisableNumbers toggle", function()
	fw.before_each(function()
		db.DisableNumbers = false
	end)

	fw.it("hides a slot's countdown numbers with no per-slot option, but keeps the swipe", function()
		db.DisableNumbers = true

		local container = NewSlotContainer()
		container:SetSlot(1, { Texture = ICON, DurationObject = wowEx:CreateDuration(GetTime(), 30) })

		local cd = container.Slots[1].Container.Cooldown
		assert(cd._lastArgs.SetHideCountdownNumbers[1] == true, "the global hides the numbers")
		assert(cd._lastArgs.SetDrawSwipe[1] == true, "the swipe is a separate switch")
	end)

	fw.it("leaves the numbers shown when the global is off", function()
		local container = NewSlotContainer()
		container:SetSlot(1, { Texture = ICON, DurationObject = wowEx:CreateDuration(GetTime(), 30) })

		local cd = container.Slots[1].Container.Cooldown
		assert(cd._lastArgs.SetHideCountdownNumbers[1] == false, "the default leaves the numbers on")
	end)
end)
