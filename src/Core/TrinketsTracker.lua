---@type string, Addon
local _, addon = ...

---@class TrinketsTracker : IModule
local M = {}
addon.Core.TrinketsTracker = M

local DEFAULT_SPELL_ID = 336126
local defaultIcon
local callbacks = {}
local eventsFrame
local eventsRegistered = false

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

---Returns the default trinket icon texture.
---@return string
function M:GetDefaultIcon()
	return defaultIcon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

---Registers a callback fired when trinket cooldown data changes.
---@param fn fun(unit: string|nil)  nil means all units should be refreshed
function M:RegisterCallback(fn)
	callbacks[#callbacks + 1] = fn
end

function M:Refresh()
	if not eventsFrame then
		return
	end

	-- Trinket cooldown data only exists inside arenas, so all events stay unregistered
	-- everywhere else. Arena transitions always pass a loading screen, which re-runs this
	-- via the addon-wide Refresh.
	local _, instanceType = IsInInstance()
	local inArena = instanceType == "arena"

	if inArena == eventsRegistered then
		return
	end
	eventsRegistered = inArena

	if inArena then
		eventsFrame:RegisterEvent("ARENA_COOLDOWNS_UPDATE")
		eventsFrame:RegisterEvent("PVP_MATCH_STATE_CHANGED")
		eventsFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
		-- Replaces the PLAYER_ENTERING_WORLD fire the tracker no longer listens for.
		FireCallbacks(nil)
	else
		eventsFrame:UnregisterAllEvents()
	end
end

function M:Init()
	defaultIcon = C_Spell.GetSpellTexture(DEFAULT_SPELL_ID)

	-- Events are registered by Refresh, and only inside arenas.
	eventsFrame = CreateFrame("Frame")
	eventsFrame:SetScript("OnEvent", function(_, event, ...)
		if event == "PVP_MATCH_STATE_CHANGED" then
			local matchState = C_PvP.GetActiveMatchState()
			if matchState == Enum.PvPMatchState.StartUp or matchState == Enum.PvPMatchState.Engaged then
				FireCallbacks(nil)
			end
		elseif event == "ARENA_COOLDOWNS_UPDATE" then
			local unit = ...
			FireCallbacks((unit and unit ~= "") and unit or nil)
		elseif event == "GROUP_ROSTER_UPDATE" then
			FireCallbacks(nil)
		end
	end)
end

---@class TrinketsTracker
---@field Init fun(self: TrinketsTracker)
---@field Refresh fun(self: TrinketsTracker)
---@field GetUnitDuration fun(self: TrinketsTracker, unit: string): table?
---@field GetDefaultIcon fun(self: TrinketsTracker): string
---@field RegisterCallback fun(self: TrinketsTracker, fn: fun(unit: string|nil))
