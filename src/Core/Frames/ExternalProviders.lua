local _, addon = ...
local mini = addon.Framework
local moduleUtil = addon.Utils.ModuleUtil
local M = addon.Core.Frames
local externalProviders = {}

-- The refresh a provider asks for runs on our own next frame, never inside the provider's call
-- stack: the engine refuses the restricted aura-sound registrations to a foreign addon's
-- execution. The frame addon is also still mid-rebuild when it calls, so its frames are only
-- worth reading once it has settled, and a provider that fires per frame gets one pass.
local QueueRefresh = moduleUtil:Coalesced(function()
	addon:Refresh()
end)

---Registers an external frame provider. Providers contribute frames to GetAll.
---Expected shape:
---  Name (string)                          identifier for the provider
---  GetFrames (fun(): table)               returns the provider's current frames
---  RegisterRefreshFrames (fun(cb: fun())) optional; called once with a callback
---                                         the provider invokes when its frames change
---@param provider table
function M:RegisterProvider(provider)
	if type(provider) ~= "table" then return end
	if type(provider.Name) ~= "string" or provider.Name == "" then return end
	if type(provider.GetFrames) ~= "function" then return end

	for _, existing in ipairs(externalProviders) do
		if existing.Name == provider.Name then
			return
		end
	end

	externalProviders[#externalProviders + 1] = provider

	if type(provider.RegisterRefreshFrames) == "function" then
		local ok, err = pcall(provider.RegisterRefreshFrames, QueueRefresh)
		if not ok then
			mini:NotifyWithPrefix("Frame provider '%s' RegisterRefreshFrames failed: %s", provider.Name, tostring(err))
		end
	end
end

---Appends frames contributed by external providers registered via RegisterProvider.
---@param visibleOnly boolean
---@param frames table Frames are appended here.
function M:ExternalFrames(visibleOnly, frames)
	for _, provider in ipairs(externalProviders) do
		local ok, providerFrames = pcall(provider.GetFrames)

		if ok and type(providerFrames) == "table" then
			for _, frame in ipairs(providerFrames) do
				if frame
					and (not frame.IsForbidden or not frame:IsForbidden())
					and (not visibleOnly or (frame.IsVisible and frame:IsVisible()))
				then
					frames[#frames + 1] = frame
				end
			end
		end
	end
end
