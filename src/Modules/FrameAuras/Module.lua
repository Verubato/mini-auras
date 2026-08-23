---@type string, Addon
local _, addon = ...

-- Loaded before this file in TOC order.
local partyAuras = addon.Modules.FrameAuras.PartyAuras
local classBuff = addon.Modules.FrameAuras.ClassBuff
local targetAuras = addon.Modules.FrameAuras.TargetAuras

-- Four halves of one page: the buff and debuff rows on the party and raid frames, the missing
-- class buff mark on the same frames, and the rows on the target and focus frames. Each carries
-- its own switch, and each is off until the player asks for it, so nothing here builds anything
-- until then.
--
-- No ModuleLifecycle and no per-context enable table, unlike every other module. Those exist to
-- gate a display on where the player is; these rows stand in for frames the game draws everywhere,
-- so a row that came and went with the zone would read as broken rather than as filtered. The
-- parts run their own enable edges instead, which is also what keeps the cvar writes to the edge.

---@class FrameAurasModule : IModule
local M = {}

addon.Modules.FrameAuras.Module = M
addon.Modules.FrameAurasModule = M

local parts = { partyAuras, classBuff, targetAuras }

---@param value boolean
local function SetTestMode(value)
	for _, part in ipairs(parts) do
		part:SetTestMode(value)
	end

	M:Refresh()
end

function M:StartTesting()
	SetTestMode(true)
end

function M:StopTesting()
	SetTestMode(false)
end

function M:Refresh()
	for _, part in ipairs(parts) do
		part:Refresh()
	end
end

function M:Init()
	M:Refresh()
end

---@class FrameAurasModule
---@field Init fun(self: FrameAurasModule)
---@field Refresh fun(self: FrameAurasModule)
---@field StartTesting fun(self: FrameAurasModule)
---@field StopTesting fun(self: FrameAurasModule)
