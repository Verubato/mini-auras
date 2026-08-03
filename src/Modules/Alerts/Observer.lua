---@type string, Addon
local _, addon = ...
local unitWatcher = addon.Core.UnitAuraWatcher

addon.Modules.Alerts = addon.Modules.Alerts or {}

---@class AlertsObserver
local M = {}
addon.Modules.Alerts.Observer = M

-- Legacy path only: on 12.1 every enemy plate gets its own aura container and no watcher exists,
-- which leaves this table empty and every function here a no-op.
---@type table<string, Watcher>
local nameplateWatchers = {}
-- AurasFrames whose RefreshAuras we've already hooked, so important buffs (read from Blizzard's
-- nameplate buff list) refresh when the game updates them. hooksecurefunc can't be undone, so we
-- track hooked frames to avoid stacking duplicate hooks on Blizzard's pooled nameplate frames.
local hookedAuraFrames = {}

---The live watcher set. The render path walks it directly rather than copying.
---@return table<string, Watcher>
function M:GetWatchers()
	return nameplateWatchers
end

---@param unitToken string
---@return Watcher?
function M:Get(unitToken)
	return nameplateWatchers[unitToken]
end

---Replaces the watcher for a token. Only CC and defensives are tracked; important buffs come
---from Blizzard's own nameplate buff list.
---@param unitToken string
---@param onChanged fun()
function M:Create(unitToken, onChanged)
	self:Dispose(unitToken)

	---@type AuraTypeFilter
	local watcherFilter = {
		CC = true,
		Defensives = true,
	}

	local watcher = unitWatcher:New(unitToken, nil, watcherFilter)
	watcher:RegisterCallback(onChanged)
	nameplateWatchers[unitToken] = watcher

	return watcher
end

---@param unitToken string
---@return boolean disposed true when there was one to dispose
function M:Dispose(unitToken)
	local watcher = nameplateWatchers[unitToken]
	if not watcher then
		return false
	end

	watcher:Dispose()
	nameplateWatchers[unitToken] = nil
	return true
end

function M:DisposeAll()
	for unitToken, watcher in pairs(nameplateWatchers) do
		watcher:Dispose()
		nameplateWatchers[unitToken] = nil
	end
end

function M:DisableAll()
	for _, watcher in pairs(nameplateWatchers) do
		watcher:Disable()
	end
end

function M:ClearAllState()
	for _, watcher in pairs(nameplateWatchers) do
		watcher:ClearState(true)
	end
end

---Drops the watchers for tokens that are no longer active.
---@param activeTokens table<string, boolean>
function M:PruneTo(activeTokens)
	for unitToken, watcher in pairs(nameplateWatchers) do
		if not activeTokens[unitToken] then
			watcher:Dispose()
			nameplateWatchers[unitToken] = nil
		end
	end
end

---Hooks a nameplate's RefreshAuras so the important bar (which reads Blizzard's nameplate buff
---lists) refreshes when the game updates them. Watchers don't track buffs, so this is the only
---signal for buff changes. Installed for every enemy nameplate; the hook is a cheap no-op when
---nothing important-related is enabled. Legacy path only.
---@param unitToken string
---@param onRefresh fun()
function M:HookAuraFrame(unitToken, onRefresh)
	local nameplate = C_NamePlate.GetNamePlateForUnit(unitToken)
	local uf = nameplate and nameplate.UnitFrame
	local af = uf and uf.AurasFrame
	if af and af.RefreshAuras and not hookedAuraFrames[af] then
		hookedAuraFrames[af] = true
		hooksecurefunc(af, "RefreshAuras", function(auraFrame)
			if auraFrame.IsForbidden and auraFrame:IsForbidden() then
				return
			end
			onRefresh()
		end)
	end
end
