---@type string, Addon
local _, addon = ...
local unitWatcher = addon.Core.UnitAuraWatcher
local kickTracker = addon.Core.KickTracker
local units = addon.Utils.Units

addon.Modules.Portrait = addon.Modules.Portrait or {}

---@class PortraitObserver
local M = {}
addon.Modules.Portrait.Observer = M

---@type { string: Watcher }
local watchers = {}
-- Callbacks that re-render each container attached to a unit; populated as portraits are attached.
-- Only target and focus have any, since they are the only portraits whose occupant changes.
---@type table<string, fun()[]>
local unitUpdateFns = {}
-- Important buffs are read from Blizzard's nameplate buff lists, so a change in them only reaches
-- us through the plate's own refresh. One hook per aura frame, kept so plates are not hooked twice.
local hookedAuraFrames = {}
local pendingImportantUnits = {}
local importantUpdateScheduled = false
-- True whenever the module is off or paused: everything below turns into a no-op rather than
-- unhooking, since the hooks are on Blizzard frames we cannot take them back off. Starts true:
-- the module is not enabled until its first Refresh.
local suspended = true

local function FlushImportantUpdates()
	importantUpdateScheduled = false
	for unit in pairs(pendingImportantUnits) do
		pendingImportantUnits[unit] = nil
		M:FireUnitUpdate(unit)
	end
end

-- Debounced: coalesces nameplate RefreshAuras bursts into one portrait update per unit per frame.
local function ScheduleImportantUpdate(unit)
	pendingImportantUnits[unit] = true
	if importantUpdateScheduled then
		return
	end
	importantUpdateScheduled = true
	C_Timer.After(0, FlushImportantUpdates)
end

---@param value boolean
function M:SetSuspended(value)
	suspended = value
end

---Legacy path only: on 12.1 the containers track their own auras.
---@param unit string
---@param events string[]?
---@return Watcher
function M:CreateWatcher(unit, events)
	local watcher = unitWatcher:New(unit, events, nil, nil, Enum.UnitAuraSortDirection.Reverse)
	watchers[unit] = watcher
	return watcher
end

---@param unit string
---@return Watcher?
function M:GetWatcher(unit)
	return watchers[unit]
end

function M:EnableWatchers()
	for _, watcher in pairs(watchers) do
		watcher:Enable()
	end
end

function M:DisableWatchers()
	for _, watcher in pairs(watchers) do
		watcher:Disable()
		watcher:ClearState(true)
	end
end

---@param sortRule number
---@param sortDirection number
function M:SetSort(sortRule, sortDirection)
	for _, watcher in pairs(watchers) do
		watcher:SetSort(sortRule, sortDirection)
	end
end

---@param unit string
---@param callback fun()
function M:RegisterUnitUpdate(unit, callback)
	unitUpdateFns[unit] = unitUpdateFns[unit] or {}
	local fns = unitUpdateFns[unit]
	fns[#fns + 1] = callback
end

---@param unit string
function M:FireUnitUpdate(unit)
	local fns = unitUpdateFns[unit]
	if not fns then
		return
	end

	for _, fn in ipairs(fns) do
		fn()
	end
end

---Hooks a nameplate's aura refresh so important buffs on the target/focus portrait update live.
---Watchers only track CC + defensives, so this is the only buff-change signal on the legacy path.
---@param unitToken string
function M:HookNameplateAuraFrame(unitToken)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.RefreshAuras and not hookedAuraFrames[af] then
		hookedAuraFrames[af] = true
		hooksecurefunc(af, "RefreshAuras", function(auraFrame)
			if suspended then
				return
			end
			if auraFrame.IsForbidden and auraFrame:IsForbidden() then
				return
			end
			local parent = auraFrame:GetParent()
			local u = parent and parent.unit
			if not u then
				return
			end
			if units:SameUnit(u, "target") then
				ScheduleImportantUpdate("target")
			end
			if units:SameUnit(u, "focus") then
				ScheduleImportantUpdate("focus")
			end
		end)
	end
end

---A kick landing on the target or focus has to redraw that portrait; no aura event covers it.
function M:WatchKicks()
	for _, unit in ipairs({ "target", "focus" }) do
		local event = unit == "target" and "PLAYER_TARGET_CHANGED" or "PLAYER_FOCUS_CHANGED"
		kickTracker:Watch(unit, { event })
		kickTracker:Subscribe(unit, function()
			M:FireUnitUpdate(unit)
		end)
	end
end
