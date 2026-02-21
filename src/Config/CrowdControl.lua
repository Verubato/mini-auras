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

---@class CrowdControlConfig
local M = {}

config.CrowdControl = M

---@param parent table
---@param options CrowdControlInstanceOptions
local function BuildAnchorSettings(parent, options)
	local panel = CreateFrame("Frame", nil, parent)

	local growDdlLbl = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	growDdlLbl:SetText(L["Grow"])

	local growDdl, modernDdl = mini:Dropdown({
		Parent = panel,
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
	growDdlLbl:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
	growDdl:SetPoint("TOPLEFT", growDdlLbl, "BOTTOMLEFT", modernDdl and 0 or -16, -8)

	local containerX = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Offset X"],
		GetValue = function()
			return options.Offset.X
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, -250, 250, 0)
			if options.Offset.X ~= newValue then
				options.Offset.X = newValue
				config:Apply()
			end
		end,
	})

	containerX.Slider:SetPoint("TOPLEFT", growDdl, "BOTTOMLEFT", 0, -verticalSpacing * 3)

	local containerY = mini:Slider({
		Parent = panel,
		Min = -250,
		Max = 250,
		Step = 1,
		Width = columnWidth * 2 - horizontalSpacing,
		LabelText = L["Offset Y"],
		GetValue = function()
			return options.Offset.Y
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, -250, 250, 0)
			if options.Offset.Y ~= newValue then
				options.Offset.Y = newValue
				config:Apply()
			end
		end,
	})

	containerY.Slider:SetPoint("LEFT", containerX.Slider, "RIGHT", horizontalSpacing, 0)

	panel:SetHeight(containerX.Slider:GetHeight() + growDdl:GetHeight() + growDdlLbl:GetHeight() + verticalSpacing * 3)

	return panel
end

---@param panel table
---@param options CrowdControlInstanceOptions
local function BuildInstance(panel, options, addTestButton)
	local parent = CreateFrame("Frame", nil, panel)
	local anchorPanel = BuildAnchorSettings(parent, options)

	local excludePlayerChk = mini:Checkbox({
		Parent = parent,
		LabelText = L["Exclude self"],
		Tooltip = L["Exclude yourself from showing CC icons."],
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
		LabelText = L["Glow icons"],
		Tooltip = L["Show a glow around the CC icons."],
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
		LabelText = L["Dispel colours"],
		Tooltip = L["Change the colour of the glow/border based on the type of debuff."],
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

	reverseChk:SetPoint("LEFT", parent, "LEFT", columnWidth * 2, 0)
	reverseChk:SetPoint("TOP", glowChk, "TOP", 0, 0)

	local iconSize = mini:Slider({
		Parent = parent,
		Min = 10,
		Max = 200,
		Width = columnWidth * 2 - horizontalSpacing,
		Step = 1,
		LabelText = L["Icon Size"],
		GetValue = function()
			return options.Icons.Size
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 10, 200, 32)
			if options.Icons.Size ~= newValue then
				options.Icons.Size = newValue
				config:Apply()
			end
		end,
	})

	iconSize.Slider:SetPoint("TOPLEFT", glowChk, "BOTTOMLEFT", 4, -verticalSpacing * 3)

	local maxIcons = mini:Slider({
		Parent = parent,
		Min = 1,
		Max = 10,
		Width = columnWidth * 2 - horizontalSpacing,
		Step = 1,
		LabelText = L["Max Icons"],
		GetValue = function()
			return options.Icons.Count or 5
		end,
		SetValue = function(v)
			local newValue = mini:ClampInt(v, 1, 10, 5)
			if options.Icons.Count ~= newValue then
				options.Icons.Count = newValue
				config:Apply()
			end
		end,
	})

	maxIcons.Slider:SetPoint("LEFT", iconSize.Slider, "RIGHT", horizontalSpacing, 0)

	anchorPanel:SetPoint("TOPLEFT", iconSize.Slider, "BOTTOMLEFT", 0, -verticalSpacing * 2)
	anchorPanel:SetPoint("TOPRIGHT", iconSize.Slider, "BOTTOMRIGHT", 0, -verticalSpacing * 2)

	if addTestButton then
		local testBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		testBtn:SetSize(120, 26)
		testBtn:SetPoint("TOPLEFT", anchorPanel, "BOTTOMLEFT", 0, -verticalSpacing * 2)
		testBtn:SetText(L["Test"])
		testBtn:SetScript("OnClick", function()
			addon:TestWithOptions(options)
		end)
	end

	parent.OnMiniRefresh = function()
		anchorPanel:MiniRefresh()
	end

	return parent
end

---@param panel table
---@param default CrowdControlInstanceOptions
---@param raid CrowdControlInstanceOptions
function M:Build(panel, default, raid)
	local db = mini:GetSavedVars()

	local lines = mini:TextBlock({
		Parent = panel,
		Lines = {
			L["Shows CC icons on party/raid frames."],
		},
	})

	lines:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)

	local enabledDivider = mini:Divider({
		Parent = panel,
		Text = L["Enable in:"],
	})
	enabledDivider:SetPoint("LEFT", panel, "LEFT")
	enabledDivider:SetPoint("RIGHT", panel, "RIGHT")
	enabledDivider:SetPoint("TOP", lines, "BOTTOM", 0, -verticalSpacing)

	local enabledEverywhere = mini:Checkbox({
		Parent = panel,
		LabelText = L["Everywhere"],
		Tooltip = L["Enable this module everywhere."],
		GetValue = function()
			return db.Modules.CCModule.Enabled.Always
		end,
		SetValue = function(value)
			db.Modules.CCModule.Enabled.Always = value
			config:Apply()
		end,
	})

	enabledEverywhere:SetPoint("TOPLEFT", enabledDivider, "BOTTOMLEFT", 0, -verticalSpacing)

	local enabledArena = mini:Checkbox({
		Parent = panel,
		LabelText = L["Arena"],
		Tooltip = L["Enable this module in arena."],
		GetValue = function()
			return db.Modules.CCModule.Enabled.Arena
		end,
		SetValue = function(value)
			db.Modules.CCModule.Enabled.Arena = value
			config:Apply()
		end,
	})

	enabledArena:SetPoint("LEFT", panel, "LEFT", columnWidth, 0)
	enabledArena:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledRaids = mini:Checkbox({
		Parent = panel,
		LabelText = L["BGS & Raids"],
		Tooltip = L["Enable this module in BGs and raids."],
		GetValue = function()
			return db.Modules.CCModule.Enabled.Raids
		end,
		SetValue = function(value)
			db.Modules.CCModule.Enabled.Raids = value
			config:Apply()
		end,
	})

	enabledRaids:SetPoint("LEFT", panel, "LEFT", columnWidth * 2, 0)
	enabledRaids:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local enabledDungeons = mini:Checkbox({
		Parent = panel,
		LabelText = L["Dungeons"],
		Tooltip = L["Enable this module in dungeons and M+."],
		GetValue = function()
			return db.Modules.CCModule.Enabled.Dungeons
		end,
		SetValue = function(value)
			db.Modules.CCModule.Enabled.Dungeons = value
			config:Apply()
		end,
	})

	enabledDungeons:SetPoint("LEFT", panel, "LEFT", columnWidth * 3, 0)
	enabledDungeons:SetPoint("TOP", enabledEverywhere, "TOP", 0, 0)

	local defaultDivider = mini:Divider({
		Parent = panel,
		Text = L["Less than 5 members (arena/dungeons)"],
	})

	defaultDivider:SetPoint("LEFT", panel, "LEFT")
	defaultDivider:SetPoint("RIGHT", panel, "RIGHT")
	defaultDivider:SetPoint("TOP", enabledEverywhere, "BOTTOM", 0, -verticalSpacing * 2)

	local defaultPanel = BuildInstance(panel, default, false)

	defaultPanel:SetPoint("TOPLEFT", defaultDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	defaultPanel:SetPoint("TOPRIGHT", defaultDivider, "BOTTOMRIGHT", 0, -verticalSpacing)
	-- TODO: calculate real child height
	defaultPanel:SetHeight(370)

	local raidDivider = mini:Divider({
		Parent = panel,
		Text = L["Greater than 5 members (raids/bgs)"],
	})

	raidDivider:SetPoint("LEFT", panel, "LEFT")
	raidDivider:SetPoint("RIGHT", panel, "RIGHT")
	raidDivider:SetPoint("TOP", defaultPanel, "BOTTOM")

	local raidPanel = BuildInstance(panel, raid, true)

	raidPanel:SetPoint("TOPLEFT", raidDivider, "BOTTOMLEFT", 0, -verticalSpacing)
	raidPanel:SetPoint("TOPRIGHT", raidDivider, "TOPRIGHT")
	raidPanel:SetHeight(370)

	panel.OnMiniRefresh = function()
		defaultPanel:MiniRefresh()
		raidPanel:MiniRefresh()
	end
end
