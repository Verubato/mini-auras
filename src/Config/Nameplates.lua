---@type string, Addon
local _, addon = ...
local mini = addon.Core.Framework
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
---@param isCombined boolean Whether this is the Combined section
---@param onVisibilityUpdate function? Callback to update visibility when mode changes
---@return table wrapper frame containing divider and settings
local function BuildSpellTypeSettings(parent, dividerText, options, unitOptions, isCombined, onVisibilityUpdate)
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
		-- Always show the checkbox and divider
		if options.Enabled then
			-- TODO: calculate these heights from children controls
			if isCombined then
				container:SetHeight(320)
			else
				container:SetHeight(250)
			end
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
		LabelText = "Enabled",
		Tooltip = "Whether to enable or disable this type.",
		GetValue = function()
			return options.Enabled
		end,
		SetValue = function(value)
			options.Enabled = value

			-- If enabling Combined, disable CC and Important
			if isCombined and value then
				unitOptions.CC.Enabled = false
				unitOptions.Important.Enabled = false
			-- If enabling CC or Important, disable Combined
			elseif not isCombined and value then
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
	end

	local glowChk = mini:Checkbox({
		Parent = container,
		LabelText = "Glow icons",
		Tooltip = "Show a glow around the icons.",
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = container,
		LabelText = "Reverse swipe",
		Tooltip = "Reverses the direction of the cooldown swipe animation.",
		GetValue = function()
			return options.Icons.ReverseCooldown
		end,
		SetValue = function(value)
			options.Icons.ReverseCooldown = value
			config:Apply()
		end,
	})

	reverseChk:SetPoint("LEFT", glowChk, "LEFT", columnWidth, 0)

	local iconSize = mini:Slider({
		Parent = container,
		Min = 10,
		Max = 200,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = "Icon Size",
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

	local growDdlLbl = container:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	growDdlLbl:SetText("Grow")

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
		LabelText = "Offset X",
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
		LabelText = "Offset Y",
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

	if isCombined then
		local maxIcons = mini:Slider({
			Parent = container,
			Min = 1,
			Max = 8,
			Step = 1,
			Width = columnWidth * 2 - horizontalSpacing,
			LabelText = "Max Icons",
			GetValue = function()
				return options.Icons.MaxIcons
			end,
			SetValue = function(v)
				local new = mini:ClampInt(v, 1, 8, 6)

				if new ~= options.Icons.MaxIcons then
					options.Icons.MaxIcons = new
					config:Apply()
				end
			end,
		})

		maxIcons.Slider:SetPoint("TOPLEFT", containerX.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 3)
	end

	return wrapper
end

---@param parent table
---@param options NameplateOptions
function M:Build(parent, options)
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

	-- Enemy sections
	enemyPanels.Combined = BuildSpellTypeSettings(
		parent,
		"Enemy - Combined",
		options.Enemy.Combined,
		options.Enemy,
		true,
		UpdateEnemyPanelVisibility
	)
	enemyPanels.Combined:SetPoint("TOP", parent, "TOP", 0, 0)

	enemyPanels.CC =
		BuildSpellTypeSettings(parent, "Enemy - CC", options.Enemy.CC, options.Enemy, false, UpdateEnemyPanelVisibility)
	enemyPanels.CC:SetPoint("TOP", enemyPanels.Combined, "BOTTOM", 0, -verticalSpacing)

	enemyPanels.Important = BuildSpellTypeSettings(
		parent,
		"Enemy - Important Spells",
		options.Enemy.Important,
		options.Enemy,
		false,
		UpdateEnemyPanelVisibility
	)
	enemyPanels.Important:SetPoint("TOP", enemyPanels.CC, "BOTTOM", 0, -verticalSpacing)

	-- Friendly sections
	friendlyPanels.Combined = BuildSpellTypeSettings(
		parent,
		"Friendly - Combined",
		options.Friendly.Combined,
		options.Friendly,
		true,
		UpdateFriendlyPanelVisibility
	)
	friendlyPanels.Combined:SetPoint("TOP", enemyPanels.Important, "BOTTOM", 0, -verticalSpacing * 2)

	friendlyPanels.CC = BuildSpellTypeSettings(
		parent,
		"Friendly - CC",
		options.Friendly.CC,
		options.Friendly,
		false,
		UpdateFriendlyPanelVisibility
	)
	friendlyPanels.CC:SetPoint("TOP", friendlyPanels.Combined, "BOTTOM", 0, -verticalSpacing)

	friendlyPanels.Important = BuildSpellTypeSettings(
		parent,
		"Friendly - Important Spells",
		options.Friendly.Important,
		options.Friendly,
		false,
		UpdateFriendlyPanelVisibility
	)
	friendlyPanels.Important:SetPoint("TOP", friendlyPanels.CC, "BOTTOM", 0, -verticalSpacing)

	-- Add Refresh method to parent that refreshes all child panels
	parent.MiniRefresh = function()
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
		if friendlyPanels.CC and friendlyPanels.CC:MiniRefresh() then
			friendlyPanels.CC:MiniRefresh()
		end
		if friendlyPanels.Important and friendlyPanels.Important.MiniRefresh then
			friendlyPanels.Important:MiniRefresh()
		end
	end
end
