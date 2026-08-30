-- Core/Display/Pixels.lua, the arithmetic gate every measured icon size passes through. On 12.1 a
-- region answers about its own geometry with secret numbers, and one of those reaching a
-- comparison aborts the whole handler, so a measurement it cannot make has to come back as nil.

local fw = require("Framework")
local moduleEnv = require("ModuleEnv")
local acm = require("AuraContainerMock")
-- For marking a number secret, which is how a region answers inside a nameplate hierarchy.
local wow = require("WowApi")

local env = moduleEnv.build()

env.loadModule("src/Core/Display/Pixels.lua")

local pixels = env.addon.Core.Pixels

-- A screen with a real height, since the mock's UIParent carries none and every measurement would
-- fail on that alone.
local SCREEN_WIDTH = 1920
local SCREEN_HEIGHT = 1080
-- Values the client hands back secret.
local SECRET_NUMBER = wow.markSecret(211)
local SECRET_SCALE = wow.markSecret(0.64)
-- A frame height and the share of it an icon takes, picked so the answer is nowhere near the one
-- pixel a failed measurement would snap to.
local FRAME_HEIGHT = 200
local ICON_SHARE = 30

-- Restored at the end of the file, so a file loaded after this one still finds the sizeless
-- screen its own comments assume.
local realScreenWidth, realScreenHeight = _G.UIParent:GetWidth(), _G.UIParent:GetHeight()

_G.UIParent:SetSize(SCREEN_WIDTH, SCREEN_HEIGHT)

---@return table
local function NewFrame()
	local frame = acm.NewFrame("Frame", "PixelsFrame")

	frame:SetSize(FRAME_HEIGHT, FRAME_HEIGHT)

	return frame
end

fw.describe("Pixels - a value the addon may do arithmetic on", function()
	fw.it("takes a plain number", function()
		assert(pixels:Number(FRAME_HEIGHT) == FRAME_HEIGHT, "an ordinary number passes through")
	end)

	fw.it("refuses a secret number, as it refuses nil and a string", function()
		assert(pixels:Number(SECRET_NUMBER) == nil, "a secret number is not one to compute with")
		assert(pixels:Number(nil) == nil, "nor is nothing at all")
		assert(pixels:Number("211") == nil, "nor a string the client answered with")
	end)
end)

fw.describe("Pixels - measuring a region the client keeps secret", function()
	fw.it("measures an icon off a frame that answers plainly", function()
		local size = pixels:ShareOfHeight(NewFrame(), ICON_SHARE)

		assert(size and size > 1, "a real measurement, got " .. tostring(size))
	end)

	fw.it("measures nothing off a frame whose height is secret", function()
		local frame = NewFrame()

		frame.GetHeight = function()
			return SECRET_NUMBER
		end

		assert(pixels:ShareOfHeight(frame, ICON_SHARE) == nil,
			"a height nobody may read is no size to draw at")
	end)

	fw.it("measures nothing off a frame whose scale is secret", function()
		local frame = NewFrame()

		frame.GetEffectiveScale = function()
			return SECRET_SCALE
		end

		assert(pixels:PerUnit(frame) == nil, "a secret scale leaves nothing to snap against")
		assert(pixels:ShareOfHeight(frame, ICON_SHARE) == nil, "so the icon has no size either")
	end)

	fw.it("falls back to the screen frame when the client's screen size is secret", function()
		local frame = NewFrame()
		local viaScreenFrame = pixels:ShareOfHeight(frame, ICON_SHARE)

		assert(viaScreenFrame, "the screen frame answers before the override, so the two passes differ")

		-- UIParent covers the screen and still answers when the physical height does not.
		_G.GetPhysicalScreenSize = function()
			return SECRET_NUMBER, SECRET_NUMBER
		end

		local size = pixels:ShareOfHeight(frame, ICON_SHARE)

		_G.GetPhysicalScreenSize = nil

		assert(size == viaScreenFrame, "the screen frame answers instead, expected "
			.. tostring(viaScreenFrame) .. " got " .. tostring(size))
	end)
end)

_G.UIParent:SetSize(realScreenWidth, realScreenHeight)
