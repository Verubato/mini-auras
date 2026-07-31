local addonName, addon = ...
local M = addon.Core.Framework

function M:CanOpenOptionsDuringCombat()
	if LE_EXPANSION_LEVEL_CURRENT == nil or LE_EXPANSION_MIDNIGHT == nil then
		return true
	end

	return LE_EXPANSION_LEVEL_CURRENT < LE_EXPANSION_MIDNIGHT
end

function M:SettingsSize()
	local settingsContainer = SettingsPanel and SettingsPanel.Container

	if settingsContainer then
		return settingsContainer:GetWidth(), settingsContainer:GetHeight()
	end

	if InterfaceOptionsFramePanelContainer then
		return InterfaceOptionsFramePanelContainer:GetWidth(), InterfaceOptionsFramePanelContainer:GetHeight()
	end

	return 600, 600
end

function M:AddCategory(panel)
	if not panel then
		error("AddCategory - panel must not be nil.")
	end

	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
		Settings.RegisterAddOnCategory(category)

		return category
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)

		return panel
	end

	return nil
end

function M:AddSubCategory(parentCategory, panel)
	if not parentCategory then
		error("AddSubCategory - parentCategory must not be nil.")
	end

	if not panel then
		error("AddSubCategory - panel must not be nil.")
	end

	if Settings and Settings.RegisterCanvasLayoutSubcategory then
		Settings.RegisterCanvasLayoutSubcategory(parentCategory, panel, panel.name)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(panel)
	end
end

function M:RegisterSlashCommand(category, panel, commands)
	if not category then
		error("RegisterSlashCommand - category must not be nil.")
	end
	if not panel then
		error("RegisterSlashCommand - panel must not be nil.")
	end

	local upper = string.upper(addonName)

	SlashCmdList[upper] = function()
		M:OpenSettings(category, panel)
	end

	if commands and #commands > 0 then
		local addonUpper = string.upper(addonName)

		for i, command in ipairs(commands) do
			_G["SLASH_" .. addonUpper .. i] = command
		end
	end
end

function M:OpenSettings(category, panel)
	if not category then
		error("OpenSettings - category must not be nil.")
	end

	if not panel then
		error("OpenSettings - panel must not be nil.")
	end

	if Settings and Settings.OpenToCategory then
		if not InCombatLockdown() or M:CanOpenOptionsDuringCombat() then
			Settings.OpenToCategory(category:GetID())
		else
			M:NotifyCombatLockdown()
		end
	elseif InterfaceOptionsFrame_OpenToCategory then
		-- workaround the classic bug where the first call opens the Game interface
		-- and a second call is required
		InterfaceOptionsFrame_OpenToCategory(panel)
		InterfaceOptionsFrame_OpenToCategory(panel)
	end
end

function M:ColumnWidth(columns, padding, spacingColumns)
	local settingsWidth = M.ContentWidth or (select(1, M:SettingsSize()))
	-- add padding to the left and right
	local usableWidth = settingsWidth - (padding * 2)
	local width = math.floor(usableWidth / (columns + spacingColumns))

	return width
end
