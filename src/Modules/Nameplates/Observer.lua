---@type string, Addon
local _, addon = ...
local unitWatcher = addon.Core.UnitAuraWatcher

addon.Modules.Nameplates = addon.Modules.Nameplates or {}

---@class NameplatesObserver
local M = {}
addon.Modules.Nameplates.Observer = M

-- Legacy path only: on 12.1 the aura containers track their own unit and no watcher is built,
-- which leaves every function here operating on an empty table.
---@type table<string, Watcher>
local watchers = {}
-- One hook per Blizzard aura frame, kept so a recycled plate is not hooked twice.
local hookedAuraFrames = {}

---Replaces the watcher for a token. Important buffs are read straight from Blizzard's nameplate
---buff list, so the watcher only tracks CC + defensives. Both are always tracked (rather than
---narrowing to the bars' current ShowCC/ShowDefensives) so a duel faction flip can't leave the
---watcher querying the wrong aura types. Stated explicitly so we don't silently inherit any
---future change to the "all" default (e.g. if it ever started including buffs, which we don't
---want here).
---@param unitToken string
---@param sortRule number
---@param sortDirection number
---@param onChanged fun()
function M:Create(unitToken, sortRule, sortDirection, onChanged)
	if watchers[unitToken] then
		watchers[unitToken]:Dispose()
	end

	local watcher = unitWatcher:New(unitToken, nil, { CC = true, Defensives = true }, sortRule, sortDirection)
	watcher:RegisterCallback(onChanged)
	watchers[unitToken] = watcher

	return watcher
end

---@param unitToken string
---@return Watcher?
function M:Get(unitToken)
	return watchers[unitToken]
end

---@param unitToken string
function M:Dispose(unitToken)
	local watcher = watchers[unitToken]
	if watcher then
		watcher:Dispose()
		watchers[unitToken] = nil
	end
end

function M:EnableAll()
	for _, watcher in pairs(watchers) do
		if watcher then
			watcher:Enable()
		end
	end
end

function M:DisableAll()
	for _, watcher in pairs(watchers) do
		if watcher then
			watcher:Disable()
		end
	end
end

---@param sortRule number
---@param sortDirection number
function M:SetSort(sortRule, sortDirection)
	for _, watcher in pairs(watchers) do
		watcher:SetSort(sortRule, sortDirection)
	end
end

---Repopulates every watcher from live aura data; used after test icons have overwritten the bars.
function M:ForceFullUpdate()
	for _, watcher in pairs(watchers) do
		watcher:ForceFullUpdate()
	end
end

---Legacy path: Blizzard's own aura refresh is the only signal that a plate's important buffs
---changed, since the watcher does not track them.
---@param nameplate table
---@param onRefresh fun(unit: string)
function M:HookAuraFrame(nameplate, onRefresh)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.RefreshAuras and not hookedAuraFrames[af] then
		hookedAuraFrames[af] = true
		hooksecurefunc(af, "RefreshAuras", function(auraFrame)
			if auraFrame.IsForbidden and auraFrame:IsForbidden() then
				return
			end
			local parent = auraFrame:GetParent()
			local unit = parent and parent.unit
			if unit then
				onRefresh(unit)
			end
		end)
	end
end
