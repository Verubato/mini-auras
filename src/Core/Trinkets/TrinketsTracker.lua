---@type string, Addon
local _, addon = ...

---@class TrinketsTracker : IModule
local M = {}
addon.Core.TrinketsTracker = M

local eventGate = addon.Core.EventGate
local DEFAULT_SPELL_ID = 336126
local defaultIcon
local callbacks = {}
---@type EventGate?
local arenaGate

local function FireCallbacks(unit)
	for _, fn in ipairs(callbacks) do
		fn(unit)
	end
end

---Returns C_PvP arena cooldown duration data for a unit, or nil if not available.
---@param unit string
---@return table?
function M:GetUnitDuration(unit)
	return C_PvP.GetArenaCrowdControlDuration(unit)
end

---@return string
function M:GetDefaultIcon()
	-- Resolved on demand as well as in Init: the config panel builds its tab strip before the
	-- modules initialise, so an early caller would otherwise be stuck with the question mark.
	if not defaultIcon then
		defaultIcon = C_Spell.GetSpellTexture(DEFAULT_SPELL_ID)
	end

	return defaultIcon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

---Registers a callback fired when trinket cooldown data changes.
---@param fn fun(unit: string|nil)  nil means all units should be refreshed
function M:RegisterCallback(fn)
	callbacks[#callbacks + 1] = fn
end

function M:Refresh()
	if not arenaGate then
		return
	end

	-- Trinket cooldown data only exists inside arenas, so all events stay unregistered
	-- everywhere else. Arena transitions always pass a loading screen, which re-runs this
	-- via the addon-wide Refresh.
	local _, instanceType = IsInInstance()
	arenaGate:SetActive(instanceType == "arena")
end

function M:Init()
	defaultIcon = C_Spell.GetSpellTexture(DEFAULT_SPELL_ID)

	-- Events are registered by Refresh, and only inside arenas.
	-- Roster changes are deliberately not handled here: the Trinkets module already runs its own
	-- full refresh on GROUP_ROSTER_UPDATE, which re-reads trinket data anyway, so a tracker-side
	-- fire would only double the work.
	local eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, ...)
		if event == "PVP_MATCH_STATE_CHANGED" then
			local matchState = C_PvP.GetActiveMatchState()
			if matchState == Enum.PvPMatchState.StartUp or matchState == Enum.PvPMatchState.Engaged then
				FireCallbacks(nil)
			end
		elseif event == "ARENA_COOLDOWNS_UPDATE" then
			local unit = ...
			FireCallbacks((unit and unit ~= "") and unit or nil)
		end
	end)

	arenaGate = eventGate:New(eventsFrame, {
		"ARENA_COOLDOWNS_UPDATE",
		"PVP_MATCH_STATE_CHANGED",
	}, {
		-- The gate's own seed fire, standing in for a PLAYER_ENTERING_WORLD nothing here listens for.
		OnActivate = function()
			FireCallbacks(nil)
		end,
	})
end

---@class TrinketsTracker
---@field Init fun(self: TrinketsTracker)
---@field Refresh fun(self: TrinketsTracker)
---@field GetUnitDuration fun(self: TrinketsTracker, unit: string): table?
---@field GetDefaultIcon fun(self: TrinketsTracker): string
---@field RegisterCallback fun(self: TrinketsTracker, fn: fun(unit: string|nil))
