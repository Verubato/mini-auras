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

---@class CcConfig
local M = {}

config.CcConfig = M

---@param parent table
---@param options CcInstanceOptions
local function BuildAnchorSettings(parent, options)
	local panel = CreateFrame("Frame", nil, parent)

	local growDdlLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	growDdlLbl:SetText("Grow")

	local growDdl, modernDdl = mini:Dropdown({
		Parent = panel,
		Items = growOptions,
		Width = columnWidth * 2 - horizontalSpacing,
		GetValue = function()
			return options.SimpleMode.Grow
		end,
		SetValue = function(value)
			options.SimpleMode.Enabled = true

			if options.SimpleMode.Grow ~= value then
				options.SimpleMode.Grow = value
				config:Apply()
			end
		end,
	})

	growDdl:SetWidth(dropdownWidth)
	growDdlLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	growDdl:SetPoint("TOPLEFT", growDdlLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local containerX = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset X",
		GetValue = function()
			return options.SimpleMode.Offset.X
		end,
		SetValue = function(v)
			options.SimpleMode.Enabled = true
			options.SimpleMode.Offset.X = mini:ClampInt(v, -250, 250, 0)
			config:Apply()
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local containerY = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = "Offset Y",
		GetValue = function()
			return options.SimpleMode.Offset.Y
		end,
		SetValue = function(v)
			options.SimpleMode.Enabled = true
			options.SimpleMode.Offset.Y = mini:ClampInt(v, -250, 250, 0)
			config:Apply()
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	panel:SetHeight(containerX.Slider:GetHeight() + growDdl:GetHeight() + growDdlLbl:GetHeight() + verticalSpacing * 3)

	return panel
end

---@param panel table
---@param options CcInstanceOptions
local function BuildInstance(panel, options)
	local parent = CreateFrame("Frame", nil, panel)
	local anchorPanel = BuildAnchorSettings(parent, options)

	local excludePlayerChk = mini:Checkbox({
		Parent = parent,
		LabelText = "Exclude self",
		Tooltip = "Exclude yourself from showing CC icons.",
		GetValue = function()
			return options.ExcludePlayer
		end,
		SetValue = function(value)
			options.ExcludePlayer = value
			addon:Refresh()
		end,
	})

	excludePlayerChk:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)

	local glowChk = mini:Checkbox({
		Parent = parent,
		LabelText = "Glow icons",
		Tooltip = "Show a glow around the CC icons.",
		GetValue = function()
			return options.Icons.Glow
		end,
		SetValue = function(value)
			options.Icons.Glow = value
			config:Apply()
		end,
	})

	glowChk:SetPoint("TOPLEFT", excludePlayerChk, "BOTTOMLEFT", 0, -verticalSpacing)

	local dispelColoursChk = mini:Checkbox({
		Parent = parent,
		LabelText = "Dispel colours",
		Tooltip = "Change the colour of the glow based on the type of debuff.",
		GetValue = function()
			return options.Icons.ColorByDispelType
		end,
		SetValue = function(value)
			options.Icons.ColorByDispelType = value
			config:Apply()
		end,
	})

	dispelColoursChk:SetPoint("LEFT", parent, "LEFT", columnWidth, 0)
	dispelColoursChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local reverseChk = mini:Checkbox({
		Parent = parent,
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

	reverseChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local iconSize = mini:Slider({
		Parent = parent,
		Min = 10,
		Max = 200,
		Width = (columnWidth * columns) - horizontalSpacing,
		Step = 1,
		LabelText = "Icon Size",
		GetValue = function()
			return options.Icons.Size
		end,
		SetValue = function(v)
			options.Icons.Size = mini:ClampInt(v, 10, 200, 32)
			config:Apply()
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	anchorPanel:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)
	anchorPanel:SetPoint("TOPRIGHT", iconSize.Slider, "BOTTOMRIGHT", 0, -verticalSpacing * 2)

	local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	testBtn:SetSize(120, 26)
	testBtn:SetPoint("TOPLEFT", anchorPanel, "BOTTOMLEFT", 0, -verticalSpacing * 2)
	testBtn:SetText("Test")
	testBtn:SetScript("OnClick", function()
		addon:TestWithOptions(options)
	end)

	return parent
end

---@param panel table
---@param default CcInstanceOptions
---@param raid CcInstanceOptions
function M:Build(panel, default, raid)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			"Shows CC icons on party/raid frames.",
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = "Enable in:",
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = mini:Checkbox({
		Parent = panel,
		LabelText = "Everywhere",
		Tooltip = "Enable this module everywhere.",
		GetValue = function()
			return db.Modules.CcModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.CcModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabledEverywhere:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent = panel,
		LabelText = "Arena",
		Tooltip = "Enable this module in arena.",
		GetValue = function()
			return db.Modules.CcModule.Enabled.Arena
		end,
		SetValue = function(value)
			db.Modules.CcModule.Enabled.Arena = value
			config:Apply()
		end,
	})

	enabledArena:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	enabledArena:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledRaids = mini:Checkbox({
		Parent = panel,
		LabelText = "BGS & Raids",
		Tooltip = "Enable this module in BGs and raids.",
		GetValue = function()
			return db.Modules.CcModule.Enabled.Raids
		end,
		SetValue = function(value)
			db.Modules.CcModule.Enabled.Raids = value
			config:Apply()
		end,
	})

	enabledRaids:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	enabledRaids:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent = panel,
		LabelText = "Dungeons",
		Tooltip = "Enable this module in dungeons and M+.",
		GetValue = function()
			return db.Modules.CcModule.Enabled.Dungeons
		end,
		SetValue = function(value)
			db.Modules.CcModule.Enabled.Dungeons = value
			config:Apply()
		end,
	})

	enabledDungeons:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local defaultDivider = mini:Divider({
		Parent = panel,
		Text = "Less than 5 members (arena/dungeons)",
	})

	defaultDivider:SetPoint("LEFT", panel, "LEFT")
	defaultDivider:SetPoint("RIGHT", panel, "RIGHT")
	defaultDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing * 2)

	local defaultPanel = BuildInstance(panel, default)

	defaultPanel:SetPoint("TOPLEFT", defaultDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	defaultPanel:SetPoint("TOPRIGHT", defaultDivider, "BOTTOMRIGHT", 0, -verticalSpacing)
	-- TODO: calculate real child height
	defaultPanel:SetHeight(370)

	local raidDivider = mini:Divider({
		Parent = panel,
		Text = "Greater than 5 members (raids/bgs)",
	})

	raidDivider:SetPoint("LEFT", panel, "LEFT")
	raidDivider:SetPoint("RIGHT", panel, "RIGHT")
	raidDivider:SetPoint("TOP", defaultPanel, "BOTTOM")

	local raidPanel = BuildInstance(panel, raid)

	raidPanel:SetPoint("TOPLEFT", raidDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	raidPanel:SetPoint("TOPRIGHT", raidDivider, "TOPRIGHT")
	raidPanel:SetHeight(370)

	panel.MiniRefresh = function()
		defaultPanel:MiniRefresh()
		raidPanel:MiniRefresh()
	end
end
