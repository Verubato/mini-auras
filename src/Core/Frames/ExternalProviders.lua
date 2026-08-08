local _, addon = ...
local mini = addon.Framework
local M = addon.Core.Frames
local externalProviders = {}

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
		local ok, err = pcall(provider.RegisterRefreshFrames, function()
			addon:Refresh()
		end)
		if not ok then
			mini:NotifyWithPrefix("Frame provider '%s' RegisterRefreshFrames failed: %s", provider.Name, tostring(err))
		end
	end
end

---Retrieves frames contributed by external providers registered via RegisterProvider.
---@param visibleOnly boolean
---@return table
function M:ExternalFrames(visibleOnly)
	local frames = {}

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

	return frames
end
