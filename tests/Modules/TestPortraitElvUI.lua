-- ElvUI draws its portrait border outside the portrait, so the icons cover the whole rect.

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

-- Wider than tall, as ElvUI sizes the portrait width apart from the frame height.
local PORTRAIT_WIDTH = 70
local PORTRAIT_HEIGHT = 60

local frame = acm.NewFrame("Frame", "ElvUF_Target")
local portrait = acm.NewFrame("Frame", "ElvUF_TargetPortrait", frame)
portrait:SetSize(PORTRAIT_WIDTH, PORTRAIT_HEIGHT)
frame.Portrait = portrait
_G.ElvUF_Target = frame

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

fw.describe("Portrait ElvUI - flush with the portrait", function()
	fw.it("anchors the container to the portrait rect with no inset", function()
		local target = assert(containerFor("target"), "no container for target")
		local points = target.Frame._points
		assert(#points == 1 and points[1].point == "ALL" and points[1].relativeTo == portrait,
			"covers the portrait rect exactly")
	end)

	fw.it("sizes every aura icon to the portrait's short side", function()
		local target = assert(containerFor("target"), "no container for target")
		for _, display in ipairs(target.AuraDisplay.Displays) do
			assert(display.PendingSize == PORTRAIT_HEIGHT,
				"icon covers the portrait, got " .. tostring(display.PendingSize))
		end
	end)

	fw.it("no misuse was reported anywhere in the module's lifecycle", function()
		assert(#env.notifications == 0, "unexpected warnings: " .. table.concat(env.notifications, "; "))
	end)
end)
