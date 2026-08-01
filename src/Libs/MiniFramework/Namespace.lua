local _, addon = ...

-- Version of the vendored MiniFramework snapshot. Bumped by the release process and
-- checked by build\SyncFramework.ps1 to report which addons are out of date.
local VERSION = "1.0.0"

---@class MiniFramework
local M = {
	Version = VERSION,
	VerticalSpacing = 16,
	HorizontalSpacing = 20,
	TextMaxWidth = 600,
	-- Widgets use stock Blizzard art unless an addon opts into the accented restyle with
	-- M:SetCustomStyling(true). Individual widgets can override either way via
	-- options.CustomStyling. Chrome with no Blizzard equivalent - tabs, the standalone
	-- window, the dialog - is always styled.
	CustomStyling = false,
}

addon.Framework = M

-- Localization shim. Addons that ship a locale table assign it to addon.L; everything else
-- gets an identity table so L["Some string"] returns the English key verbatim. Resolution is
-- deferred to access time so the framework can load before or after the addon's locale files.
M.L = setmetatable({}, {
	__index = function(self, key)
		-- `source ~= self` guards the obvious shortcut an addon without locale files reaches
		-- for: addon.L = addon.Framework.L, which would otherwise recurse until the stack blows.
		local source = addon.L

		if source and source ~= self then
			local value = source[key]

			if value ~= nil then
				return value
			end
		end

		return key
	end,
})

-- Internal helpers and palette shared by the GUI widget files. Populated by GUI\Common.lua.
-- Not part of the public API - widgets themselves attach to addon.Framework.
M.GUI = {}
