local addonName, addon = ...
local M = addon.Core.Framework
local loader = CreateFrame("Frame")
local loaded = false
local onLoadCallbacks = {}

local function OnAddonLoaded(_, _, name)
	if name ~= addonName then
		return
	end

	loaded = true
	loader:UnregisterEvent("ADDON_LOADED")

	for _, callback in ipairs(onLoadCallbacks) do
		callback()
	end
end

loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", OnAddonLoaded)

function M:WaitForAddonLoad(callback)
	if not callback then
		error("WaitForAddonLoad - callback must not be nil.")
	end

	onLoadCallbacks[#onLoadCallbacks + 1] = callback

	if loaded then
		callback()
	end
end
