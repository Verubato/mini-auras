---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
local L = addon.L
local dropdownWidth = 200
local growOptions = {
	"LEFT",
	"RIGHT",
	"CENTER",
}
local verticalSpacing = mini.VerticalSpacing
local horizontalSpacing = mini.HorizontalSpacing
local columns = 4
local columnWidth = mini:ColumnWidth(columns, 0, 0)
local config = addon.Config

---@class NameplatesConfig
local M = {}

config.Nameplates = M

---@param parent table
---@param dividerText string Text for the divider
---@param options NameplateSpellTypeOptions
---@param unitOptions table The parent unit options (Enemy or Friendly)
---@param sectionType string Type of section: "CC", "Important", or "Combined"
---@param onVisibilityUpdate function? Callback to update visibility when mode changes
---@return table wrapper frame containing divider and settings
local function BuildSpellTypeSettings(parent, dividerText, options, unitOptions, sectionType, onVisibilityUpdate)
	-- Create a wrapper frame that contains the divider and all settings
	local wrapper = CreateFrame("Frame", nil, parent)
	wrapper:SetPoint("LEFT", parent, "LEFT", 0, 0)
	wrapper:SetPoint("RIGHT", parent, "RIGHT", -horizontalSpacing, 0)

	-- Create divider as child of wrapper
	local divider = mini:Divider({
		Parent = wrapper,
		Text = dividerText,
	})

	divider:SetPoint("LEFT", wrapper, "LEFT", 0, 0)
	divider:SetPoint("RIGHT", wrapper, "RIGHT", 0, 0)
	divider:SetPoint("TOP", wrapper, "TOP", 0, 0)

	local container = CreateFrame("Frame", nil, wrapper)

	local function UpdateVisibility()
		-- Only show the settings container if this section is enabled
		if options.Enabled then
			container:SetHeight(280)
			container:Show()
		else
			container:Hide()
			container:SetHeight(1)
		end

		-- Update wrapper height to include divider height + checkbox + container
		-- Divider ~20, checkbox ~20 + spacing
		wrapper:SetHeight(20 + 20 + verticalSpacing * 2 + container:GetHeight())
	end

	local enabled = mini:Checkbox({
		Parent = wrapper,
		LabelText = L["Enabled"],
		Tooltip = L["Whether to enable or disable this type."],
		GetValue = function()
			return options.Enabled
		end,
		SetValue = function(value)
			options.Enabled = value

			-- If enabling Combined, disable CC and Important
			if sectionType == "Combined" and value then
				unitOptions.CC.Enabled = false
				unitOptions.Important.Enabled = false
			-- If enabling CC or Important, disable Combined
			elseif sectionType ~= "Combined" and value then
				unitOptions.Combined.Enabled = false
			end

			UpdateVisibility()

			-- Update panel visibility when mode changes
			if onVisibilityUpdate then
				onVisibilityUpdate()
			end

			-- Refresh the parent to update all checkboxes
			if parent.MiniRefresh then
				parent:MiniRefresh()
			end

			config:Apply()
		end,
	})

	enabled:SetPoint("TOPLEFT", divider, "BOTTOMLEFT", 0, -verticalSpacing)

	container:SetPoint("TOPLEFT", enabled, "BOTTOMLEFT", 0, -verticalSpacing)
	container:SetPoint("RIGHT", wrapper, "RIGHT", 0, 0)

	UpdateVisibility()

	wrapper.UpdateVisibility = UpdateVisibility

	-- Store Refresh function on wrapper to refresh the checkbox state
	wrapper.OnMiniRefresh = function()
		UpdateVisibility()
		container:MiniRefresh()
	end

	local glowChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the icons."],
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

	-- Build tooltip based on section type
	local colorTooltip
	if sectionType == "Combined" then
		colorTooltip = L["Change the colour of the glow/border. CC spells use dispel type colours (e.g., blue for magic), Defensive spells are green, and Important spells are red."]
	elseif sectionType == "CC" then
		colorTooltip = L["Change the colour of the glow/border based on dispel type (e.g., blue for magic, red for physical)."]
	else
		colorTooltip = L["Change the colour of the glow/border. Defensive spells are green and Important spells are red."]
	end

	local dispelColoursChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Spell colours"],
		Tooltip = colorTooltip,
		GetValue = function()
			return options.Icons.ColorByCategory
		end,
		SetValue = function(value)
			options.Icons.ColorByCategory = value
			config:Apply()
		end,
	})

	dispelColoursChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	dispelColoursChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = container,
		LabelText = L["Reverse swipe"],
		Tooltip = L["Reverses the direction of the cooldown swipe animation."],
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply()
		end,
	})

	reverseChk:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local iconSize = mini:Slider({
		Parent = container,
		Min = 10,
		Max = 200,
		Width = columnWidth * 2 - horizontalSpacing,
		Step = 1,
		LabelText = L["Icon Size"],
		GetValue = function()
			return options.Icons.Size
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, 10, 200, 32)

			if new ~= options.Icons.Size then
				options.Icons.Size = new
				config:Apply()
			end
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	-- Add Max Icons slider for all section types
	local maxIconsMax = sectionType == "Combined" and 8 or 5
	local maxIconsDefault = sectionType == "Combined" and 6 or 5

	local maxIcons = mini:Slider({
		Parent = container,
		Min = 1,
		Max = maxIconsMax,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Max Icons"],
		GetValue = function()
			return options.Icons.MaxIcons
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, 1, maxIconsMax, maxIconsDefault)

			if new ~= options.Icons.MaxIcons then
				options.Icons.MaxIcons = new
				config:Apply()
			end
		end,
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

	local growDdlLbl = container:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	growDdlLbl:SetText(L["Grow"])

	local growDdl, modernDdl = mini:Dropdown({
		Parent = container,
		Items = growOptions,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return options.Grow
		end,
		SetValue = function(value)
			if options.Grow ~= value then
				options.Grow = value
				config:Apply()
			end
		end,
	})

	growDdl:SetWidth(dropdownWidth)
	growDdlLbl:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing)
	growDdl:SetPoint("TOPLEFT", growDdlLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local containerX = mini:Slider({
		Parent = container,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Offset X"],
		GetValue = function()
			return options.Offset.X
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, -250, 250, 0)

			if new ~= options.Offset.X then
				options.Offset.X = new
				config:Apply()
			end
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local containerY = mini:Slider({
		Parent = container,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Offset Y"],
		GetValue = function()
			return options.Offset.Y
		end,
		SetValue = function(v)
			local new = mini:ClampInt(v, -250, 250, 0)

			if new ~= options.Offset.Y then
				options.Offset.Y = new
				config:Apply()
			end
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	return wrapper
end

---@param parent table
---@param options NameplateModuleOptions
function M:Build(parent, options)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = parent,
		Lines = {
			L["Shows CC and important spells on nameplates (works with nameplate addons e.g. BBP, Platynator, and Plater)."],
		},
	})

	lines:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = parent,
		Text = L["Enable in:"],
	})
	enabledDivider:SetPoint("LEFT", parent, "LEFT")
	enabledDivider:SetPoint("RIGHT", parent, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = mini:Checkbox({
		Parent = parent,
		LabelText = L["Everywhere"],
		Tooltip = L["Enable this module everywhere."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabledEverywhere:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent = parent,
		LabelText = L["Arena"],
		Tooltip = L["Enable this module in arena."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.Arena
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.Arena = value
			config:Apply()
		end,
	})

	enabledArena:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	enabledArena:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledRaids = mini:Checkbox({
		Parent = parent,
		LabelText = L["BGS & Raids"],
		Tooltip = L["Enable this module in BGs and raids."],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.Raids
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.Raids = value
			config:Apply()
		end,
	})

	enabledRaids:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	enabledRaids:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent = parent,
		LabelText = L["Dungeons"],
		Tooltip = L["Enable this module in Dungeons and M+"],
		GetValue = function()
			return db.Modules.NameplatesModule.Enabled.Dungeons
		end,
		SetValue = function(value)
			db.Modules.NameplatesModule.Enabled.Dungeons = value
			config:Apply()
		end,
	})

	enabledDungeons:SetPoint("LEFT", parent, "LEFT", columnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	-- Store panel references for visibility toggling
	local enemyPanels = {}
	local friendlyPanels = {}

	-- Function to update panel visibility based on mode
	-- This refreshes all panels to show/hide their settings containers
	local function UpdateEnemyPanelVisibility()
		enemyPanels.Combined.UpdateVisibility()
		enemyPanels.CC.UpdateVisibility()
		enemyPanels.Important.UpdateVisibility()
	end

	local function UpdateFriendlyPanelVisibility()
		friendlyPanels.Combined.UpdateVisibility()
		friendlyPanels.CC.UpdateVisibility()
		friendlyPanels.Important.UpdateVisibility()
	end

	-- Enemy Ignore Pets checkbox
	local enemyIgnorePetsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Ignore Enemy Pets"],
		Tooltip = L["Do not show auras on enemy pet nameplates."],
		GetValue = function()
			return options.Enemy.IgnorePets
		end,
		SetValue = function(value)
			options.Enemy.IgnorePets = value
			config:Apply()
		end,
	})
	enemyIgnorePetsChk:SetPoint("TOPLEFT", enabledEverywhere, "BOTTOMLEFT", 0, -verticalSpacing * 2)

	local friendlyIgnorePetsChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Ignore Friendly Pets"],
		Tooltip = L["Do not show auras on friendly pet nameplates."],
		GetValue = function()
			return options.Friendly.IgnorePets
		end,
		SetValue = function(value)
			options.Friendly.IgnorePets = value
			config:Apply()
		end,
	})
	friendlyIgnorePetsChk:SetPoint("TOP", enemyIgnorePetsChk, "TOP", 0, 0)
	friendlyIgnorePetsChk:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)

	-- Enemy sections
	enemyPanels.Combined = BuildSpellTypeSettings(
		parent,
		L["Enemy - Combined"],
		options.Enemy.Combined,
		options.Enemy,
		"Combined",
		UpdateEnemyPanelVisibility
	)
	enemyPanels.Combined:SetPoint("TOP", enemyIgnorePetsChk, "BOTTOM", 0, -verticalSpacing)

	enemyPanels.CC =
		BuildSpellTypeSettings(parent, L["Enemy - CC"], options.Enemy.CC, options.Enemy, "CC", UpdateEnemyPanelVisibility)
	enemyPanels.CC:SetPoint("TOP", enemyPanels.Combined, "BOTTOM", 0, -verticalSpacing)

	enemyPanels.Important = BuildSpellTypeSettings(
		parent,
		L["Enemy - Important Spells"],
		options.Enemy.Important,
		options.Enemy,
		"Important",
		UpdateEnemyPanelVisibility
	)
	enemyPanels.Important:SetPoint("TOP", enemyPanels.CC, "BOTTOM", 0, -verticalSpacing)

	-- Friendly sections
	friendlyPanels.Combined = BuildSpellTypeSettings(
		parent,
		L["Friendly - Combined"],
		options.Friendly.Combined,
		options.Friendly,
		"Combined",
		UpdateFriendlyPanelVisibility
	)
	friendlyPanels.Combined:SetPoint("TOP", enemyPanels.Important, "BOTTOM", 0, -verticalSpacing * 2)

	friendlyPanels.CC = BuildSpellTypeSettings(
		parent,
		L["Friendly - CC"],
		options.Friendly.CC,
		options.Friendly,
		"CC",
		UpdateFriendlyPanelVisibility
	)
	friendlyPanels.CC:SetPoint("TOP", friendlyPanels.Combined, "BOTTOM", 0, -verticalSpacing)

	friendlyPanels.Important = BuildSpellTypeSettings(
		parent,
		L["Friendly - Important Spells"],
		options.Friendly.Important,
		options.Friendly,
		"Important",
		UpdateFriendlyPanelVisibility
	)
	friendlyPanels.Important:SetPoint("TOP", friendlyPanels.CC, "BOTTOM", 0, -verticalSpacing)

	-- Add Refresh method to parent that refreshes all child panels
	parent.OnMiniRefresh = function()
		if enemyPanels.Combined and enemyPanels.Combined.MiniRefresh then
			enemyPanels.Combined:MiniRefresh()
		end
		if enemyPanels.CC and enemyPanels.CC.MiniRefresh then
			enemyPanels.CC:MiniRefresh()
		end
		if enemyPanels.Important and enemyPanels.Important.MiniRefresh then
			enemyPanels.Important:MiniRefresh()
		end
		if friendlyPanels.Combined and friendlyPanels.Combined.MiniRefresh then
			friendlyPanels.Combined:MiniRefresh()
		end
		if friendlyPanels.CC and friendlyPanels.CC.MiniRefresh then
			friendlyPanels.CC:MiniRefresh()
		end
		if friendlyPanels.Important and friendlyPanels.Important.MiniRefresh then
			friendlyPanels.Important:MiniRefresh()
		end
	end
end
