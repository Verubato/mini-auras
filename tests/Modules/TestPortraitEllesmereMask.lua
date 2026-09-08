-- A detached, shaped portrait clips itself with a MaskTexture its own addon owns and mutates in
-- place on a live shape change. The icon overlay reuses that same object so it clips to the shape.

local fw = require("Framework")
local acm = require("AuraContainerMock")
local moduleEnv = require("ModuleEnv")

local env = moduleEnv.build()

env.setModuleEnabled("Portrait", true)

-- No Blizzard frame in this env. A prior test file's PlayerFrame/TargetFrame/FocusFrame/PetFrame
-- globals outlive it, since nothing clears raw _G assignments between files in the same process.
_G.PlayerFrame = nil
_G.TargetFrame = nil
_G.FocusFrame = nil
_G.PetFrame = nil

-- Any shape but a circle, so a round swipe left behind would show up as one.
local SHAPE_MASK = "tex:diamond_mask"

---@param name string
---@param hasMask boolean
---@return table backdrop
local function newEllesmereFrame(name, hasMask)
	local frame = acm.NewFrame("Frame", name)
	local backdrop = acm.NewFrame("Frame", name .. "Backdrop", frame)
	backdrop:SetSize(60, 60)
	backdrop:SetPoint("TOPLEFT", frame, "TOPLEFT", 5, -5)
	frame.Portrait = { backdrop = backdrop }

	if hasMask then
		backdrop._shapeMask = backdrop:CreateMaskTexture()
		backdrop._shapeMask:SetTexture(SHAPE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	end

	_G[name] = frame
	return backdrop
end

local targetBackdrop = newEllesmereFrame("EllesmereUIUnitFrames_Target", true)
-- An attached portrait, or a detached one shaped "none", leaves no mask to find.
newEllesmereFrame("EllesmereUIUnitFrames_Focus", false)

env.loadModule("src/Modules/Portrait/Observer.lua")
env.loadModule("src/Modules/Portrait/Display.lua")
env.loadModule("src/Modules/Portrait/Anchors.lua")
env.loadModule("src/Modules/Portrait/Module.lua")
local module = env.addon.Modules.PortraitModule

module:Init()
module:Refresh()

local function containerFor(unit)
	for _, container in ipairs(module:GetContainers()) do
		if container.AuraUnit == unit then
			return container
		end
	end
end

fw.describe("Portrait EllesmereUI - detached shaped portrait mask", function()
	fw.it("threads the portrait's own shape mask onto every category display", function()
		local target = assert(containerFor("target"), "no container for target")
		assert(target.AuraDisplay, "target has an aura display stack")
		for _, display in ipairs(target.AuraDisplay.Displays) do
			assert(display.IconMask == targetBackdrop._shapeMask,
				"every category display carries the portrait's own shape mask")
		end
	end)

	fw.it("leaves the display stack unmasked when the portrait has no shape mask", function()
		local focus = assert(containerFor("focus"), "no container for focus")
		for _, display in ipairs(focus.AuraDisplay.Displays) do
			assert(display.IconMask == nil, "no shape mask on the portrait, so none is threaded onto the display")
		end
	end)

	fw.it("clips the kick icon to the same shape mask", function()
		module:StartTesting()

		local targetIcon = containerFor("target").Slots[1].Container.Icon
		local applied = targetIcon._lastArgs.AddMaskTexture
		assert(applied and applied[1] == targetBackdrop._shapeMask,
			"the kick icon picks up the portrait's own shape mask")

		module:StopTesting()
	end)

	fw.it("cuts the kick icon's swipe to the shape as well as its art", function()
		module:StartTesting()

		local cooldown = containerFor("target").Slots[1].Container.Cooldown
		assert(cooldown._lastArgs.SetSwipeTexture[1] == SHAPE_MASK,
			"the kick swipe wears the shape mask rather than a rectangle")

		module:StopTesting()
	end)

	fw.it("cuts an aura icon's swipe to the shape as well as its art", function()
		-- A display is born with none of its groups, so the walker that declares them one per turn
		-- has to run before a button exists to read.
		acm.tickAll(40)

		local target = assert(containerFor("target"), "no container for target")
		local displays = target.AuraDisplay.Displays
		local display = displays[#displays]
		local group = assert(display.Frame._groups[display.Groups[1].Key], "the layer has a group")
		local button = assert(group.buttons[1], "the group built a button")
		local cooldown = assert(button._lastArgs.SetDurationCooldown, "the button was given a cooldown")[1]

		assert(cooldown._lastArgs.SetSwipeTexture[1] == SHAPE_MASK,
			"the aura swipe wears the shape mask rather than Blizzard's round one")
	end)

	fw.it("leaves the kick icon unmasked when the portrait has no shape mask", function()
		module:StartTesting()

		local focusIcon = containerFor("focus").Slots[1].Container.Icon
		assert(focusIcon._lastArgs.AddMaskTexture == nil,
			"no shape mask on the portrait, so the kick icon stays unmasked")

		module:StopTesting()
	end)

	fw.it("no misuse was reported anywhere in the module's lifecycle", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
